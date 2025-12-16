Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "[NEO] Phase 1 - Wire verification"

# -------------------------
# Helpers
# -------------------------
function Abort([string]$msg) { throw "[ABORT] $msg" }

function EnsureDir([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Read-FileUtf8Text([string]$Path) {
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
    } catch {
        Abort "Failed to read file bytes: $Path | $($_.Exception.Message)"
    }
    if (-not $bytes -or $bytes.Length -eq 0) { Abort "Baseline file is empty: $Path" }
    $utf8 = New-Object System.Text.UTF8Encoding($true) # accept BOM if present
    return $utf8.GetString($bytes)
}

function Preview-Text([string]$s, [int]$n = 200) {
    if ([string]::IsNullOrEmpty($s)) { return "" }
    if ($s.Length -le $n) { return $s }
    return $s.Substring(0, $n)
}

function Get-TrustedTimeOffsetSeconds([string[]]$NtpServers) {
    foreach ($srv in $NtpServers) {
        try {
            $out = & w32tm /stripchart /computer:$srv /dataonly /samples:3 2>$null
            if (-not $out) { continue }

            foreach ($line in $out) {
                if ($line -match "([+-]\d+(?:\.\d+)?)s") { return [double]$Matches[1] }
                if ($line -match "([+-]\d{2}\.\d+)s")   { return [double]$Matches[1] }
            }
        } catch { continue }
    }
    Abort "Could not parse NTP offset from w32tm output. Servers=$($NtpServers -join ',')"
}

function EnforceTrustedTime([double]$MaxSkewSeconds = 5.0) {
    $servers = @("time.nist.gov","time.windows.com","pool.ntp.org")
    $offset = Get-TrustedTimeOffsetSeconds -NtpServers $servers
    $abs = [Math]::Abs($offset)

    if ($abs -gt $MaxSkewSeconds) {
        Abort ("Untrusted system clock. |offset|={0:N3}s exceeds max {1:N3}s" -f $abs, $MaxSkewSeconds)
    }

    Write-Host ("[OK] Trusted time gate passed. NTP offset={0:N3}s" -f $offset)
    return $offset
}

# -------------------------
# Paths
# -------------------------
$Root = "C:\ai_control\NEO_Stack"
$ArtifactsDir = Join-Path $Root "artifacts"
$RuntimeDir   = Join-Path $Root "runtime"

$BaselinePath   = Join-Path $ArtifactsDir "baseline_summary.json"
$PhaseStatePath = Join-Path $RuntimeDir "neo_phase_state.json"

# -------------------------
# Gate 0: folders exist
# -------------------------
EnsureDir $ArtifactsDir
EnsureDir $RuntimeDir

# -------------------------
# Gate 1: trusted time
# -------------------------
$ntpOffset = EnforceTrustedTime -MaxSkewSeconds 5.0

# -------------------------
# Gate 2: baseline exists + JSON parses
# -------------------------
if (-not (Test-Path -LiteralPath $BaselinePath)) {
    Abort "Missing file: $BaselinePath"
}

$raw = Read-FileUtf8Text -Path $BaselinePath

$item = Get-Item -LiteralPath $BaselinePath
$hash = (Get-FileHash -LiteralPath $BaselinePath -Algorithm SHA256).Hash
Write-Host ("[DBG] baseline_summary.json bytes={0} sha256={1}" -f $item.Length, $hash)

try {
    # NOTE: Windows PowerShell 5.1 ConvertFrom-Json has NO -Depth parameter
    $baseline = ConvertFrom-Json -InputObject $raw
} catch {
    $preview = Preview-Text $raw 200
    Abort ("JSON parse failed in {0}. Preview(200)=[{1}] | Error={2}" -f $BaselinePath, $preview, $_.Exception.Message)
}

# -------------------------
# Gate 3: schema sanity
# -------------------------
$required = @("run_id","created_utc","engine","version","p_top","top_event_id","source_file")
foreach ($f in $required) {
    if (-not ($baseline.PSObject.Properties.Name -contains $f)) {
        Abort "Baseline missing required field: $f"
    }
}

try { [void][double]$baseline.p_top } catch { Abort "Baseline field p_top is not numeric: $($baseline.p_top)" }

# -------------------------
# Phase state write (Phase 1 complete)
# -------------------------
$state = [ordered]@{
    schema_version     = "neo_phase_state_v1"
    phase_1_complete   = $true
    phase_1_utc        = (Get-Date).ToUniversalTime().ToString("o")
    ntp_offset_seconds = [double]$ntpOffset
    baseline_path      = $BaselinePath
    baseline_run_id    = [string]$baseline.run_id
    baseline_engine    = [string]$baseline.engine
    baseline_version   = [string]$baseline.version
    baseline_p_top     = [double]$baseline.p_top
    phase_2_complete   = $false
    phase_3_complete   = $false
    phase_4_complete   = $false
}

$tmp = Join-Path $RuntimeDir (".tmp_" + [guid]::NewGuid().ToString("N"))
$json = ($state | ConvertTo-Json -Depth 50)   # ConvertTo-Json DOES support -Depth in PS 5.1
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($tmp, $json, $utf8NoBom)
Move-Item -LiteralPath $tmp -Destination $PhaseStatePath -Force

Write-Host "[OK] Phase 1 complete. State written:"
Write-Host "     $PhaseStatePath"
exit 0

