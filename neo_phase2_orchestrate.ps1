# C:\ai_control\NEO_Stack\neo_phase2_orchestrate.ps1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "[NEO] Phase 2 - Launchpad (governed workspace + phase2 state)"

# -------------------------
# Helpers (self-contained)
# -------------------------
function Abort([string]$msg) {
    throw "[ABORT] $msg"
}

function EnsureDir([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Read-FileUtf8Text([string]$Path) {
    try { $bytes = [System.IO.File]::ReadAllBytes($Path) }
    catch { Abort "Failed to read file bytes: $Path | $($_.Exception.Message)" }

    if (-not $bytes -or $bytes.Length -eq 0) { Abort "File is empty: $Path" }

    # Accept BOM if present; do not require it.
    $utf8 = New-Object System.Text.UTF8Encoding($true)
    return $utf8.GetString($bytes)
}

function Preview-Text([string]$s, [int]$n = 200) {
    if ([string]::IsNullOrEmpty($s)) { return "" }
    if ($s.Length -le $n) { return $s }
    return $s.Substring(0, $n)
}

function Read-JsonStrict([string]$Path) {
    $raw = Read-FileUtf8Text -Path $Path
    try {
        # PS 5.1 compatible (ConvertFrom-Json has no -Depth there)
        return (ConvertFrom-Json -InputObject $raw)
    } catch {
        $p = Preview-Text $raw 200
        Abort ("Invalid JSON in {0}. Preview(200)=[{1}] | Error={2}" -f $Path, $p, $_.Exception.Message)
    }
}

function Write-JsonAtomic([string]$Path, [object]$Obj, [int]$Depth = 50) {
    $dir = Split-Path -Parent $Path
    EnsureDir $dir

    $tmp = Join-Path $dir (".tmp_" + [guid]::NewGuid().ToString("N"))
    $json = ($Obj | ConvertTo-Json -Depth $Depth)

    # UTF-8 no BOM
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tmp, $json, $utf8NoBom)

    # Atomic-ish replace on same volume
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Require-Fields([object]$Obj, [string]$ObjName, [string[]]$Fields) {
    foreach ($f in $Fields) {
        if (-not ($Obj.PSObject.Properties.Name -contains $f)) {
            Abort ("{0} missing required field: {1}" -f $ObjName, $f)
        }
    }
}

function Normalize-FullPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    return [System.IO.Path]::GetFullPath($Path)
}

# -------------------------
# Paths
# -------------------------
$Root        = "C:\ai_control\NEO_Stack"
$ArtifactsDir = Join-Path $Root "artifacts"
$RuntimeDir   = Join-Path $Root "runtime"
$RunsDir      = Join-Path $Root "runs"

$Phase1Path   = Join-Path $RuntimeDir "neo_phase_state.json"
$BaselinePath = Join-Path $ArtifactsDir "baseline_summary.json"

# Phase 2 outputs
$Phase2StatePath = Join-Path $RuntimeDir "neo_phase2_state.json"

EnsureDir $ArtifactsDir
EnsureDir $RuntimeDir
EnsureDir $RunsDir

# -------------------------
# Gate 1: Phase 1 must be complete
# -------------------------
if (-not (Test-Path -LiteralPath $Phase1Path)) {
    Abort "Missing Phase 1 state: $Phase1Path (run neo_stack_wire.ps1 first)"
}

$phase1 = Read-JsonStrict -Path $Phase1Path

Require-Fields -Obj $phase1 -ObjName "Phase1 state" -Fields @(
    "schema_version",
    "phase_1_complete",
    "phase_1_utc",
    "baseline_path",
    "baseline_run_id",
    "baseline_p_top"
)

if (-not [bool]$phase1.phase_1_complete) {
    Abort "Phase 1 not complete. phase_1_complete != true in $Phase1Path"
}

Write-Host "[OK] Phase 1 gate satisfied."

# -------------------------
# Gate 2: Baseline must exist and match Phase 1 recorded baseline_path
# -------------------------
if (-not (Test-Path -LiteralPath $BaselinePath)) {
    Abort "Missing baseline artifact: $BaselinePath"
}

$phase1Baseline = Normalize-FullPath ([string]$phase1.baseline_path)
$actualBaseline = Normalize-FullPath $BaselinePath

if ([string]::IsNullOrWhiteSpace($phase1Baseline)) {
    Abort "Phase 1 baseline_path is empty in $Phase1Path"
}

if ($phase1Baseline -ne $actualBaseline) {
    Abort "Baseline path mismatch. Phase1=$phase1Baseline | Actual=$actualBaseline"
}

$baselineObj = Read-JsonStrict -Path $BaselinePath

Require-Fields -Obj $baselineObj -ObjName "Baseline artifact" -Fields @(
    "run_id",
    "created_utc",
    "engine",
    "version",
    "p_top",
    "top_event_id",
    "source_file"
)

# Cross-check run_id matches Phase 1 record
if ([string]$baselineObj.run_id -ne [string]$phase1.baseline_run_id) {
    Abort "Baseline run_id mismatch vs Phase1. Baseline=$($baselineObj.run_id) Phase1=$($phase1.baseline_run_id)"
}

# Validate p_top numeric
try { [void][double]$baselineObj.p_top }
catch { Abort "Baseline p_top is not numeric: $($baselineObj.p_top)" }

# Hash baseline (content fingerprint)
$baselineHash = (Get-FileHash -LiteralPath $BaselinePath -Algorithm SHA256).Hash

Write-Host ("[OK] Baseline validated. run_id={0} p_top={1} sha256={2}" -f $baselineObj.run_id, $baselineObj.p_top, $baselineHash)

# -------------------------
# Phase 2 action: Create run workspace (single-run; no loop)
# -------------------------
$runStamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmssZ")
$runGuid  = [guid]::NewGuid().ToString("N").Substring(0,8)
$runId    = ("NEO_RUN_{0}_{1}" -f $runStamp, $runGuid)

$RunDir = Join-Path $RunsDir $runId

if (Test-Path -LiteralPath $RunDir) {
    Abort "Run workspace already exists (unexpected collision): $RunDir"
}

EnsureDir $RunDir
EnsureDir (Join-Path $RunDir "inbox")
EnsureDir (Join-Path $RunDir "outbox")
EnsureDir (Join-Path $RunDir "logs")

# Seed a run manifest (audit/debug foundation)
$manifestPath = Join-Path $RunDir "run_manifest.json"
$manifest = [ordered]@{
    schema_version   = "neo_run_manifest_v1"
    run_id           = $runId
    created_utc      = (Get-Date).ToUniversalTime().ToString("o")

    phase1_state     = $Phase1Path
    phase1_utc       = [string]$phase1.phase_1_utc

    baseline_path    = $BaselinePath
    baseline_sha256  = $baselineHash
    baseline_run_id  = [string]$baselineObj.run_id
    baseline_engine  = [string]$baselineObj.engine
    baseline_version = [string]$baselineObj.version
    baseline_p_top   = [double]$baselineObj.p_top
    top_event_id     = [string]$baselineObj.top_event_id
    source_file      = [string]$baselineObj.source_file

    notes            = "Phase 2 created run workspace. No loop. No models. No execution started."
}

Write-JsonAtomic -Path $manifestPath -Obj $manifest -Depth 50

# -------------------------
# Write Phase 2 state (atomic)
# -------------------------
$phase2 = [ordered]@{
    schema_version   = "neo_phase2_state_v1"
    phase_2_complete = $true
    phase_2_utc      = (Get-Date).ToUniversalTime().ToString("o")

    run_id           = $runId
    run_dir          = $RunDir
    manifest_path    = $manifestPath

    baseline_path    = $BaselinePath
    baseline_sha256  = $baselineHash
    baseline_run_id  = [string]$baselineObj.run_id
    baseline_p_top   = [double]$baselineObj.p_top

    # Future phases (explicitly false)
    phase_3_complete = $false
    phase_4_complete = $false
}

Write-JsonAtomic -Path $Phase2StatePath -Obj $phase2 -Depth 50

Write-Host "[OK] Phase 2 complete."
Write-Host ("     Run workspace : {0}" -f $RunDir)
Write-Host ("     Manifest      : {0}" -f $manifestPath)
Write-Host ("     Phase2 state  : {0}" -f $Phase2StatePath)

exit 0
