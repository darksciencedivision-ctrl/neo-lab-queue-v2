# ============================================================
# NEO LOOP - Manifest Driven Deterministic Runtime (queue_v2)
# Windows PowerShell 5.1 - ASCII ONLY
#
# Stop mechanism:
#   Create:  C:\ai_control\NEO_Stack\artifacts\STOP
# ============================================================

param(
    [string]$ManifestPath = "C:\ai_control\NEO_Stack\neo_manifest.json",
    [switch]$Quiet,
    [ValidateSet("INFO","WARN","ERROR")]
    [string]$LogLevel = "INFO"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ------------------------------------------------------------
# Utilities
# ------------------------------------------------------------
function Ensure-Dir {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $utf8)
}

function Write-Log {
    param(
        [string]$LogPath,
        [string]$Level,
        [string]$Message,
        [hashtable]$Data = $null
    )

    $rank = @{ INFO=1; WARN=2; ERROR=3 }
    if (-not $rank.ContainsKey($Level)) { $Level = "INFO" }
    if (-not $rank.ContainsKey($LogLevel)) { $LogLevel = "INFO" }
    if ($rank[$Level] -lt $rank[$LogLevel]) { return }

    $obj = @{
        ts_utc = (Get-Date).ToUniversalTime().ToString("o")
        level  = $Level
        msg    = $Message
    }
    if ($Data) { $obj.data = $Data }

    $line = ($obj | ConvertTo-Json -Depth 12 -Compress)

    if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        Ensure-Dir (Split-Path -Parent $LogPath)
        Add-Content -LiteralPath $LogPath -Value $line
    }

    if (-not $Quiet) { Write-Host $line }
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw ("JSON file not found: " + $Path)
    }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) { throw ("Empty JSON file: " + $Path) }
        return ($raw | ConvertFrom-Json)
    } catch {
        throw ("Invalid JSON in file: " + $Path + " -- " + $_.Exception.Message)
    }
}

function Has-Prop {
    param($Obj, [string]$Name)
    if ($null -eq $Obj) { return $false }
    return ($Obj.PSObject.Properties.Name -contains $Name)
}

function Normalize-Text {
    param([string]$Text)
    if ($null -eq $Text) { $Text = "" }
    return $Text.Trim()
}

# ------------------------------------------------------------
# Routing
# ------------------------------------------------------------
function Decide-Route {
    param([string]$Text, $Routes)

    $t = Normalize-Text $Text
    $route = "chat"
    $conf  = 0.5
    $clean = $t

    # Hard switches (must be alone on their line in neo_chat_sync.ps1)
    if ($t.StartsWith("/chat", [System.StringComparison]::OrdinalIgnoreCase)) {
        $route = "chat"; $conf = 0.95
        $clean = $t.Substring(5).Trim()
        return @{ route=$route; confidence=$conf; text=$clean }
    }
    if ($t.StartsWith("/coder", [System.StringComparison]::OrdinalIgnoreCase)) {
        $route = "coder"; $conf = 0.95
        $clean = $t.Substring(6).Trim()
        return @{ route=$route; confidence=$conf; text=$clean }
    }
    if ($t.StartsWith("/reasoner", [System.StringComparison]::OrdinalIgnoreCase)) {
        $route = "reasoner"; $conf = 0.95
        $clean = $t.Substring(10).Trim()
        return @{ route=$route; confidence=$conf; text=$clean }
    }
    if ($t.StartsWith("/retrieval", [System.StringComparison]::OrdinalIgnoreCase)) {
        $route = "retrieval"; $conf = 0.90
        $clean = $t.Substring(10).Trim()
        return @{ route=$route; confidence=$conf; text=$clean }
    }
    if ($t.StartsWith("/r", [System.StringComparison]::OrdinalIgnoreCase)) {
        $route = "retrieval"; $conf = 0.80
        $clean = $t.Substring(2).Trim()
        return @{ route=$route; confidence=$conf; text=$clean }
    }

    # Rule-based routing (optional)
    if ($null -ne $Routes -and (Has-Prop $Routes "rules")) {
        foreach ($r in $Routes.rules) {
            $match = ""
            $value = ""
            $rte   = ""
            if (Has-Prop $r "match") { $match = [string]$r.match }
            if (Has-Prop $r "value") { $value = [string]$r.value }
            if (Has-Prop $r "route") { $rte   = [string]$r.route }

            if ([string]::IsNullOrWhiteSpace($value)) { continue }
            if ([string]::IsNullOrWhiteSpace($rte)) { continue }

            if ($match -eq "starts_with") {
                if ($t.StartsWith($value, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return @{ route=$rte; confidence=0.70; text=$t }
                }
            } elseif ($match -eq "contains") {
                if ($t.IndexOf($value, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    return @{ route=$rte; confidence=0.70; text=$t }
                }
            }
        }
    }

    return @{ route=$route; confidence=$conf; text=$clean }
}

# ------------------------------------------------------------
# Retrieval (simple Select-String)
# ------------------------------------------------------------
function Invoke-Retrieve {
    param([string]$Query, [string]$KbRoot, [int]$MaxHits = 10)

    $hits = @()
    if ([string]::IsNullOrWhiteSpace($KbRoot)) { return @{ engine="none"; hits=@() } }
    if (-not (Test-Path -LiteralPath $KbRoot)) { return @{ engine="none"; hits=@() } }

    try {
        $results = Select-String -Path (Join-Path $KbRoot "*") -Pattern $Query -SimpleMatch -Recurse -ErrorAction SilentlyContinue
        foreach ($m in $results) {
            $hits += @{ path=[string]$m.Path; line=[int]$m.LineNumber; text=[string]$m.Line }
            if ($hits.Count -ge $MaxHits) { break }
        }
    } catch { }

    return @{ engine="select-string"; hits=$hits }
}

# ------------------------------------------------------------
# Ollama Invocation
# ------------------------------------------------------------
function Invoke-Ollama {
    param([string]$Model, [string]$Prompt)

    if ([string]::IsNullOrWhiteSpace($Model)) { throw "No model selected" }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "ollama"
    $psi.Arguments = ("run " + $Model + " --nowordwrap")
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $null = $p.Start()

    $p.StandardInput.WriteLine($Prompt)
    $p.StandardInput.Close()

    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit()

    if ($p.ExitCode -ne 0) { throw ("ollama failed: " + $err) }
    return $out.Trim()
}

# ------------------------------------------------------------
# Load Manifest + Validate
# ------------------------------------------------------------
$manifest = Read-JsonFile -Path $ManifestPath

foreach ($k in @("stack_id","paths","routes","models")) {
    if (-not (Has-Prop $manifest $k)) {
        throw ("MANIFEST VALIDATION FAILED - missing key: " + $k)
    }
}

$stackId = [string]$manifest.stack_id
$paths   = $manifest.paths
$routes  = $manifest.routes
$models  = $manifest.models

foreach ($k in @("queue_inbox","queue_outbox","queue_processing","queue_processed","queue_deadletter","kb_root","artifacts_root")) {
    if (-not (Has-Prop $paths $k)) { throw ("MANIFEST missing paths." + $k) }
}

$INBOX      = [string]$paths.queue_inbox
$OUTBOX     = [string]$paths.queue_outbox
$PROCESSING = [string]$paths.queue_processing
$PROCESSED  = [string]$paths.queue_processed
$DLQ        = [string]$paths.queue_deadletter
$KBROOT     = [string]$paths.kb_root
$ART        = [string]$paths.artifacts_root

Ensure-Dir $INBOX
Ensure-Dir $OUTBOX
Ensure-Dir $PROCESSING
Ensure-Dir $PROCESSED
Ensure-Dir $DLQ
Ensure-Dir $ART

$STOPFILE = Join-Path $ART "STOP"
$LOGPATH  = Join-Path (Join-Path $ART "logs") "neo_loop.log"

Write-Log -LogPath $LOGPATH -Level "INFO" -Message ("NEO LOOP START (" + $stackId + ")") -Data @{
    inbox=$INBOX; outbox=$OUTBOX; dlq=$DLQ
}

# ------------------------------------------------------------
# Loop
# ------------------------------------------------------------
while ($true) {

    # Clean stop (no Ctrl+C required)
    if (Test-Path -LiteralPath $STOPFILE) {
        Write-Log -LogPath $LOGPATH -Level "WARN" -Message "STOP FILE DETECTED - shutting down"
        break
    }

    $next = Get-ChildItem -LiteralPath $INBOX -Filter "*.json" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime |
        Select-Object -First 1

    if (-not $next) {
        Start-Sleep -Milliseconds 250
        continue
    }

    $inPath   = $next.FullName
    $workPath = Join-Path $PROCESSING $next.Name

    try {
        Move-Item -LiteralPath $inPath -Destination $workPath -Force

        $msg = Read-JsonFile -Path $workPath

        if (-not (Has-Prop $msg "id"))   { throw "Inbound message missing: id" }
        if (-not (Has-Prop $msg "text")) { throw "Inbound message missing: text" }

        $id   = [string]$msg.id
        $role = "user"
        if (Has-Prop $msg "role") { $role = [string]$msg.role }

        $text = [string]$msg.text
        $pick = Decide-Route -Text $text -Routes $routes
        $route     = [string]$pick.route
        $routeConf = [double]$pick.confidence
        $cleanText = [string]$pick.text

        # Model selection priority:
        # 1) routes.model_map[route]
        # 2) models[route].name
        # 3) models.chat.name
        $modelName = $null
        if (Has-Prop $routes "model_map") {
            $mm = $routes.model_map
            if ($null -ne $mm -and ($mm.PSObject.Properties.Name -contains $route)) {
                $modelName = [string]$mm.$route
            }
        }
        if ([string]::IsNullOrWhiteSpace($modelName)) {
            if ($models.PSObject.Properties.Name -contains $route) {
                $mobj = $models.$route
                if (Has-Prop $mobj "name") { $modelName = [string]$mobj.name }
            }
        }
        if ([string]::IsNullOrWhiteSpace($modelName)) {
            if ($models.PSObject.Properties.Name -contains "chat") {
                $mchat = $models.chat
                if (Has-Prop $mchat "name") { $modelName = [string]$mchat.name }
            }
        }
        if ([string]::IsNullOrWhiteSpace($modelName)) { $modelName = "dolphin-llama3:latest" }

        # Retrieval decision
        $useRetrieval = $false
        $maxHits = 10
        if (Has-Prop $manifest "retrieval") {
            $ret = $manifest.retrieval
            if (Has-Prop $ret "use")      { $useRetrieval = [bool]$ret.use }
            if (Has-Prop $ret "max_hits") { $maxHits = [int]$ret.max_hits }
        }
        if ($route -eq "retrieval") { $useRetrieval = $true }

        $retBundle = @{ engine="none"; hits=@() }
        if ($useRetrieval) {
            $retBundle = Invoke-Retrieve -Query $cleanText -KbRoot $KBROOT -MaxHits $maxHits
        }

        # Prompt
        $promptLines = New-Object System.Collections.Generic.List[string]
        $promptLines.Add("ROUTE: " + $route) | Out-Null
        $promptLines.Add("USER(" + $role + "): " + $cleanText) | Out-Null

        if ($retBundle.hits -and $retBundle.hits.Count -gt 0) {
            $promptLines.Add("") | Out-Null
            $promptLines.Add("CONTEXT (search hits):") | Out-Null
            foreach ($h in $retBundle.hits) {
                $promptLines.Add("- " + $h.path + ":" + $h.line + " " + $h.text) | Out-Null
            }
        }

        $promptLines.Add("") | Out-Null
        $promptLines.Add("ASSISTANT:") | Out-Null
        $prompt = ($promptLines -join "`n")

        $assistantText = ""
        $err = $null
        try {
            $assistantText = Invoke-Ollama -Model $modelName -Prompt $prompt
        } catch {
            $err = $_.Exception.Message
            $assistantText = ""
        }

        $reply = @{
            id = ("reply_" + $id)
            in_reply_to = $id
            ts = (Get-Date).ToUniversalTime().ToString("o")
            role = "assistant"
            model = $modelName
            text = $assistantText
            error = ($err -ne $null)
            error_code = ""
            error_detail = $err
            route = $route
            route_confidence = $routeConf
            context = @{
                used_retrieval = $useRetrieval
                retrieval_engine = [string]$retBundle.engine
                hits = $retBundle.hits
            }
        }

        $outName = ("reply_" + $id + ".json")
        $outPath = Join-Path $OUTBOX $outName
        Write-Utf8NoBom -Path $outPath -Text ($reply | ConvertTo-Json -Depth 12)

        Move-Item -LiteralPath $workPath -Destination (Join-Path $PROCESSED $next.Name) -Force

        Write-Log -LogPath $LOGPATH -Level "INFO" -Message "OK" -Data @{
            id=$id; route=$route; retrieval=$useRetrieval; model=$modelName
        }

    } catch {
        Write-Log -LogPath $LOGPATH -Level "ERROR" -Message "MESSAGE_FAILED" -Data @{
            path=$workPath; err=$_.Exception.Message
        }
        try {
            Ensure-Dir $DLQ
            if (Test-Path -LiteralPath $workPath) {
                Move-Item -LiteralPath $workPath -Destination (Join-Path $DLQ $next.Name) -Force
            }
        } catch { }
    }
}

Write-Log -LogPath $LOGPATH -Level "INFO" -Message "NEO LOOP EXITED CLEANLY"
