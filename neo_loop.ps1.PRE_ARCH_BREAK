# ============================================================
# NEO LOOP — QUEUE V2 (ATOMIC FILE IPC) + TRUE STREAMING OUTPUT
# PowerShell: 5.1 + StrictMode safe
#
# Stream behavior:
#   - Sends Ollama /api/chat with stream=true
#   - Reads JSON lines incrementally
#   - Appends chunks to outbox\<id>\response.txt as they arrive
#   - Writes status.json heartbeat + progress counters
# ============================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ROOT = Get-Location

# ---- V2 QUEUE ROOT ----
$Q2_ROOT      = Join-Path $ROOT "queue_v2"
$Q2_INBOX     = Join-Path $Q2_ROOT "inbox"
$Q2_OUTBOX    = Join-Path $Q2_ROOT "outbox"
$Q2_PROCESSED = Join-Path $Q2_ROOT "processed"

# ---- CONFIG/STATE ----
$CONFIG_DIR   = Join-Path $ROOT "config"
$PERSONA_FILE = Join-Path $CONFIG_DIR "persona_lab_assistant.json"
$STATE_FILE   = Join-Path (Join-Path $ROOT "queue") "conversation_state.json"

# ---- OLLAMA ----
$OLLAMA_BASE = "http://127.0.0.1:11434"
$CHAT_URL    = "$OLLAMA_BASE/api/chat"
$TAGS_URL    = "$OLLAMA_BASE/api/tags"

# ---- MODELS ----
$MODEL_CHAT     = "dolphin-llama3:latest"
$MODEL_CODE     = "deepseek-coder-v2:latest"
$MODEL_ANALYSIS = "deepseek-r1:latest"
$MODEL_VISION   = "qwen2.5-vl:7b"

# ---- FEATURES ----
$MEMORY_ENABLED   = $true
$MEMORY_MAX_TURNS = 6

Write-Host "=== NEO LOOP STARTING (QUEUE V2 + TRUE STREAMING) ===" -ForegroundColor Cyan

# ------------------------------------------------------------
# Utilities
# ------------------------------------------------------------
function Ensure-Folders {
    foreach ($p in @($Q2_ROOT, $Q2_INBOX, $Q2_OUTBOX, $Q2_PROCESSED, $CONFIG_DIR)) {
        if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p | Out-Null }
    }
}

function Read-JsonFileOrNull([string]$path) {
    if (-not (Test-Path $path)) { return $null }
    try { return (Get-Content $path -Raw) | ConvertFrom-Json } catch { return $null }
}

function Write-JsonFile([string]$path, $obj) {
    try { $obj | ConvertTo-Json -Depth 24 | Set-Content $path -Encoding UTF8; return $true } catch { return $false }
}

function Now-UtcIso { return ([DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")) }

function Ensure-Outbox([string]$id) {
    $dir = Join-Path $Q2_OUTBOX $id
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    return $dir
}

function Status-Path([string]$id) { return (Join-Path (Ensure-Outbox $id) "status.json") }
function Response-Path([string]$id){ return (Join-Path (Ensure-Outbox $id) "response.txt") }

function Write-Status([string]$id, [string]$state, [string]$phase, [int]$chunks=0, [int]$chars=0) {
    $path = Status-Path $id
    $obj = @{
        id = $id
        state = $state         # queued|running|done|error
        phase = $phase         # reading|routing|streaming|writing|done
        chunks_written = $chunks
        chars_written  = $chars
        ts_utc = (Now-UtcIso)
    }
    Write-JsonFile $path $obj | Out-Null
}

function Clear-Response([string]$id) {
    $path = Response-Path $id
    Set-Content -Path $path -Value "" -Encoding UTF8
}

function Append-Response([string]$id, [string]$text) {
    $path = Response-Path $id
    Add-Content -Path $path -Value $text -Encoding UTF8
}

# ------------------------------------------------------------
# Ollama model list
# ------------------------------------------------------------
function Get-OllamaModelNames {
    try {
        $r = Invoke-RestMethod -Uri $TAGS_URL -Method GET -TimeoutSec 10
        return @($r.models | ForEach-Object { $_.name })
    } catch { return @() }
}
function Has-Model($name, $all) { return ($all -contains $name) }

# ------------------------------------------------------------
# Memory (still uses queue\memory_*.json)
# ------------------------------------------------------------
$MEM_DIR = Join-Path $ROOT "queue"

function Memory-Path($intent) { Join-Path $MEM_DIR ("memory_{0}.json" -f $intent) }

function Load-Memory($intent) {
    $path = Memory-Path $intent
    if (-not (Test-Path $path)) { return @() }
    try { $o = (Get-Content $path -Raw) | ConvertFrom-Json; return @($o.messages) } catch { return @() }
}

function Save-Memory($intent, $messages) {
    $max = $MEMORY_MAX_TURNS * 2
    $arr = @($messages)
    if ($arr.Count -gt $max) { $arr = $arr[-$max..-1] }
    @{ messages = $arr } | ConvertTo-Json -Depth 10 | Set-Content (Memory-Path $intent) -Encoding UTF8
}

function Clear-Memory($which) {
    if ($which -eq "all") {
        foreach ($p in @("chat","code","analysis","vision")) {
            $mp = Memory-Path $p
            if (Test-Path $mp) { Remove-Item $mp -Force -ErrorAction SilentlyContinue }
        }
        return
    }
    if (@("chat","code","analysis","vision") -contains $which) {
        $mp = Memory-Path $which
        if (Test-Path $mp) { Remove-Item $mp -Force -ErrorAction SilentlyContinue }
    }
}

# ------------------------------------------------------------
# Intent router
# ------------------------------------------------------------
function Classify($t) {
    $l = $t.ToLower()
    if ($l.StartsWith("/vision"))   { return "vision" }
    if ($l.StartsWith("/code"))     { return "code" }
    if ($l.StartsWith("/analysis")) { return "analysis" }
    return "chat"
}

# ------------------------------------------------------------
# State migration (StrictMode-safe)
# ------------------------------------------------------------
function Ensure-StateObject($stateObj) {
    if (-not $stateObj) { $stateObj = [pscustomobject]@{} }
    if (-not ($stateObj.PSObject.Properties.Name -contains "assistant_mode")) { $stateObj | Add-Member -NotePropertyName "assistant_mode" -NotePropertyValue "lab" }
    if (-not ($stateObj.PSObject.Properties.Name -contains "report_mode"))    { $stateObj | Add-Member -NotePropertyName "report_mode" -NotePropertyValue "off" }
    if (-not ($stateObj.PSObject.Properties.Name -contains "current_objective")) { $stateObj | Add-Member -NotePropertyName "current_objective" -NotePropertyValue "Unset" }
    if (-not ($stateObj.PSObject.Properties.Name -contains "current_context"))   { $stateObj | Add-Member -NotePropertyName "current_context" -NotePropertyValue "Unset" }
    if (-not ($stateObj.PSObject.Properties.Name -contains "current_workspace")) { $stateObj | Add-Member -NotePropertyName "current_workspace" -NotePropertyValue ([string]$ROOT) }

    if (-not ($stateObj.PSObject.Properties.Name -contains "interaction")) { $stateObj | Add-Member -NotePropertyName "interaction" -NotePropertyValue ([pscustomobject]@{}) }
    if (-not ($stateObj.interaction.PSObject.Properties.Name -contains "verbosity"))   { $stateObj.interaction | Add-Member -NotePropertyName "verbosity" -NotePropertyValue "normal" }
    if (-not ($stateObj.interaction.PSObject.Properties.Name -contains "tone"))        { $stateObj.interaction | Add-Member -NotePropertyName "tone" -NotePropertyValue "technical" }
    if (-not ($stateObj.interaction.PSObject.Properties.Name -contains "output_mode")) { $stateObj.interaction | Add-Member -NotePropertyName "output_mode" -NotePropertyValue "copy_paste" }

    if (-not ($stateObj.PSObject.Properties.Name -contains "last_updated_utc")) { $stateObj | Add-Member -NotePropertyName "last_updated_utc" -NotePropertyValue (Now-UtcIso) }
    return $stateObj
}

# ------------------------------------------------------------
# Contracts
# ------------------------------------------------------------
function Build-LabContract($personaObj, $stateObj) {
@"
You are NEO-LAB: a commercial-grade engineering lab assistant operating inside a deterministic local control plane.
You do not have autonomy. You respond only to user requests.

Operating contract:
- Start each response with: Objective: ...
- Use: What's happening, Recommended plan, Steps, Verification, If stuck.
- Prefer copy/paste blocks when asked.
- Do not claim emotions or independent intent.
- User is root authority.

State: Mode=$($stateObj.assistant_mode) ReportMode=$($stateObj.report_mode)
Objective=$($stateObj.current_objective)
Context=$($stateObj.current_context)
"@.Trim()
}

function Build-ReportContract($personaObj, $stateObj) {
    (Build-LabContract $personaObj $stateObj) + "`n`n" + @"
REPORT WRITER MODE:
- Produce ONE single complete response only. Do not ask questions.
- Use headings; multi-page depth if needed.

Required sections:
1) Executive Summary
2) Scope & Assumptions
3) Core Analysis
4) Methods / Models / Math (if applicable)
5) Implementation (commands/code) (if applicable)
6) Risks, Limitations, Verification Checklist
7) References / Source Guidance (if applicable)
"@.Trim()
}

function Is-ReportRequest($msg, $stateObj) {
    $l = $msg.ToLower()
    if ($l.StartsWith("/report")) { return $true }
    if ($l.Contains("[neo_output_mode:report]")) { return $true }
    if ([string]$stateObj.report_mode -eq "on") { return $true }
    return $false
}

# ------------------------------------------------------------
# Commands (minimal)
# ------------------------------------------------------------
function Parse-Command($t) {
    $line = $t.Trim()
    if (-not $line.StartsWith("/")) { return $null }
    $space = $line.IndexOf(" ")
    if ($space -gt 0) { return @{ cmd=$line.Substring(0,$space).ToLower(); arg=$line.Substring($space+1).Trim() } }
    return @{ cmd=$line.ToLower(); arg="" }
}

function Apply-Command($cmdObj, $stateObj) {
    $stateObj = Ensure-StateObject $stateObj
    $cmd = [string]$cmdObj.cmd
    $arg = [string]$cmdObj.arg

    if ($cmd -eq "/reportmode") {
        $v = $arg.ToLower()
        if (-not $v) { $v = "status" }
        if ($v -eq "status") { return @{ response=("Objective: Report mode status`nReportMode is: {0}" -f $stateObj.report_mode); state=$stateObj } }
        if (@("on","off") -notcontains $v) { return @{ response="Objective: Set report mode`nUse: /reportmode on | off | status"; state=$stateObj } }
        $stateObj.report_mode = $v
        $stateObj.last_updated_utc = Now-UtcIso
        return @{ response=("Objective: Set report mode`nReportMode set to: {0}" -f $v); state=$stateObj }
    }

    if ($cmd -eq "/memclear") {
        $which = $arg.ToLower()
        if (-not $which) { $which = "all" }
        Clear-Memory $which
        return @{ response=("Objective: Clear memory`nCleared memory: {0}" -f $which); state=$stateObj }
    }

    if ($cmd -eq "/status") {
        return @{ response=("Objective: Status`nMode={0}`nReportMode={1}`nObjective={2}`nContext={3}" -f $stateObj.assistant_mode, $stateObj.report_mode, $stateObj.current_objective, $stateObj.current_context); state=$stateObj }
    }

    if ($cmd -eq "/objective") {
        if (-not $arg) { return @{ response=("Objective: Show objective`n{0}" -f $stateObj.current_objective); state=$stateObj } }
        $stateObj.current_objective = $arg
        $stateObj.last_updated_utc = Now-UtcIso
        return @{ response=("Objective: Set objective`n{0}" -f $arg); state=$stateObj }
    }

    if ($cmd -eq "/context") {
        if (-not $arg) { return @{ response=("Objective: Show context`n{0}" -f $stateObj.current_context); state=$stateObj } }
        $stateObj.current_context = $arg
        $stateObj.last_updated_utc = Now-UtcIso
        return @{ response=("Objective: Set context`n{0}" -f $arg); state=$stateObj }
    }

    return @{ response="Objective: Command help`nSupported: /status /objective /context /reportmode /memclear"; state=$stateObj }
}

# ------------------------------------------------------------
# Atomic inbox: get oldest message file
# ------------------------------------------------------------
function Get-NextInboxFile {
    $files = @(Get-ChildItem -Path $Q2_INBOX -Filter "*.json" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
    if ($files.Count -eq 0) { return $null }
    return $files[0]
}

# ------------------------------------------------------------
# STREAMING CHAT (Ollama stream=true)
# ------------------------------------------------------------
function Invoke-ChatStreamToFile([string]$id, [string]$model, $messages) {
    # Initialize output
    Clear-Response $id

    $chunks = 0
    $chars  = 0

    $payload = @{
        model    = $model
        stream   = $true
        messages = $messages
    } | ConvertTo-Json -Depth 12

    $req = [System.Net.HttpWebRequest]::Create($CHAT_URL)
    $req.Method = "POST"
    $req.ContentType = "application/json"
    $req.Timeout = 900000
    $req.ReadWriteTimeout = 900000

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $req.ContentLength = $bytes.Length

    $rs = $req.GetRequestStream()
    $rs.Write($bytes, 0, $bytes.Length)
    $rs.Close()

    $resp = $null
    try { $resp = $req.GetResponse() } catch { return "" }

    $stream = $resp.GetResponseStream()
    $reader = New-Object System.IO.StreamReader($stream)

    $final = New-Object System.Text.StringBuilder

    while (-not $reader.EndOfStream) {
        $line = $reader.ReadLine()
        if (-not $line) { continue }

        $obj = $null
        try { $obj = $line | ConvertFrom-Json } catch { $obj = $null }

        if ($obj -and ($obj.PSObject.Properties.Name -contains "message")) {
            $m = $obj.message
            if ($m -and ($m.PSObject.Properties.Name -contains "content")) {
                $delta = [string]$m.content
                if ($delta) {
                    [void]$final.Append($delta)
                    Append-Response $id $delta
                    $chunks += 1
                    $chars  += $delta.Length
                    if (($chunks % 10) -eq 0) {
                        Write-Status $id "running" "streaming" $chunks $chars
                    }
                }
            }
        }

        if ($obj -and ($obj.PSObject.Properties.Name -contains "done") -and ($obj.done -eq $true)) {
            break
        }
    }

    $reader.Close()
    $stream.Close()
    $resp.Close()

    Write-Status $id "running" "writing" $chunks $chars
    return $final.ToString()
}

# ------------------------------------------------------------
# MAIN LOOP
# ------------------------------------------------------------
Ensure-Folders

while ($true) {
    Write-Host ("NEO heartbeat @ {0}" -f (Get-Date)) -ForegroundColor DarkGreen

    $infile = Get-NextInboxFile
    if (-not $infile) { Start-Sleep -Milliseconds 120; continue }

    $msgObj = Read-JsonFileOrNull $infile.FullName
    if (-not $msgObj) {
        Move-Item -Path $infile.FullName -Destination (Join-Path $Q2_PROCESSED $infile.Name) -Force
        continue
    }

    $id = ""
    if ($msgObj.PSObject.Properties.Name -contains "id") { $id = [string]$msgObj.id }
    if (-not $id) { $id = ("msg_{0}" -f (Get-Date -Format "yyyyMMdd_HHmmss_fff")) }

    $payload = ""
    if ($msgObj.PSObject.Properties.Name -contains "payload") { $payload = [string]$msgObj.payload }

    Write-Status $id "running" "reading" 0 0

    $personaObj = Read-JsonFileOrNull $PERSONA_FILE
    $stateObj   = Ensure-StateObject (Read-JsonFileOrNull $STATE_FILE)

    $cmdObj = Parse-Command $payload
    if ($cmdObj) {
        Write-Status $id "running" "command" 0 0
        $r = Apply-Command $cmdObj $stateObj
        Write-JsonFile $STATE_FILE $r.state | Out-Null
        Clear-Response $id
        Append-Response $id $r.response
        Write-Status $id "done" "done" 1 $r.response.Length
        Move-Item -Path $infile.FullName -Destination (Join-Path $Q2_PROCESSED $infile.Name) -Force
        continue
    }

    $ALL = Get-OllamaModelNames

    $intent = Classify $payload
    $model = $MODEL_CHAT
    if ($intent -eq "code"     -and (Has-Model $MODEL_CODE     $ALL)) { $model = $MODEL_CODE }
    if ($intent -eq "analysis" -and (Has-Model $MODEL_ANALYSIS $ALL)) { $model = $MODEL_ANALYSIS }
    if ($intent -eq "vision"   -and (Has-Model $MODEL_VISION   $ALL)) { $model = $MODEL_VISION }

    $reportRequested = Is-ReportRequest $payload $stateObj

    Write-Host ("ROUTE: {0} → {1} (Report={2}) id={3}" -f $intent, $model, $reportRequested, $id) -ForegroundColor Cyan

    $systemContract = Build-LabContract $personaObj $stateObj
    if ($reportRequested) { $systemContract = Build-ReportContract $personaObj $stateObj }

    $messages = @(@{ role="system"; content=$systemContract })

    foreach ($m in @(Load-Memory $intent)) {
        if ($m.PSObject.Properties.Name -contains "images") {
            $messages += @{ role=$m.role; content=$m.content; images=$m.images }
        } else {
            $messages += @{ role=$m.role; content=$m.content }
        }
    }

    $userContent = $payload
    if ($payload.ToLower().StartsWith("/report")) {
        $userContent = $payload.Substring(7).Trim()
        if (-not $userContent) { $userContent = "Write a report on the requested topic." }
    }

    $messages += @{ role="user"; content=$userContent }

    Write-Status $id "running" "streaming" 0 0
    $finalText = Invoke-ChatStreamToFile $id $model $messages

    # Fallback if streaming failed
    if (-not $finalText) {
        Write-Status $id "running" "fallback" 0 0
        $fallbackMsgs = @(
            @{ role="system"; content=$systemContract },
            @{ role="user"; content=$userContent }
        )
        $finalText = Invoke-ChatStreamToFile $id $MODEL_CHAT $fallbackMsgs
    }

    if (-not $finalText) {
        $finalText = "Objective: Respond`nNo response from model. Check Ollama and retry."
        Clear-Response $id
        Append-Response $id $finalText
    }

    if ($MEMORY_ENABLED) {
        $mem = @(Load-Memory $intent)
        $mem += @{ role="user"; content=$payload }
        $mem += @{ role="assistant"; content=$finalText }
        Save-Memory $intent $mem
    }

    Write-Status $id "done" "done" 9999 $finalText.Length
    Move-Item -Path $infile.FullName -Destination (Join-Path $Q2_PROCESSED $infile.Name) -Force
    Start-Sleep -Milliseconds 60
}

