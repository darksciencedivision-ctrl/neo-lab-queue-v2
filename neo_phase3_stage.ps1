# C:\ai_control\NEO_Stack\neo_phase3_stage.ps1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "[NEO] Phase 3 - Staging (hash-locked proposal request; no models)"

# -------------------------
# Helpers (self-contained)
# -------------------------
function Abort([string]$msg) { throw "[ABORT] $msg" }

function EnsureDir([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Read-FileUtf8Text([string]$Path) {
    try { $bytes = [System.IO.File]::ReadAllBytes($Path) }
    catch { Abort "Failed to read file bytes: $Path | $($_.Exception.Message)" }

    if (-not $bytes -or $bytes.Length -eq 0) { Abort "File is empty: $Path" }

    # Accept BOM if present
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
        return (ConvertFrom-Json -InputObject $raw)  # PS 5.1 safe
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

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tmp, $json, $utf8NoBom)
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
# Settings
# -------------------------
# Baseline TTL (seconds). Default 12h. Set to 0 to disable TTL enforcement.
$BASELINE_TTL_SECONDS = 43200

# -------------------------
# Paths
# -------------------------
$Root         = "C:\ai_control\NEO_Stack"
$ArtifactsDir = Join-Path $Root "artifacts"
$RuntimeDir   = Join-Path $Root "runtime"

$Phase2Path   = Join-Path $RuntimeDir "neo_phase2_state.json"
$Phase3Path   = Join-Path $RuntimeDir "neo_phase3_state.json"

$BaselinePath = Join-Path $ArtifactsDir "baseline_summary.json"

# -------------------------
# Gate 1: Phase 2 must be complete
# -------------------------
if (-not (Test-Path -LiteralPath $Phase2Path)) {
    Abort "Missing Phase 2 state: $Phase2Path (run neo_phase2_orchestrate.ps1 first)"
}

$phase2 = Read-JsonStrict -Path $Phase2Path

Require-Fields -Obj $phase2 -ObjName "Phase2 state" -Fields @(
    "schema_version",
    "phase_2_complete",
    "phase_2_utc",
    "run_id",
    "run_dir",
    "manifest_path",
    "baseline_path",
    "baseline_sha256",
    "baseline_run_id",
    "baseline_p_top"
)

if (-not [bool]$phase2.phase_2_complete) {
    Abort "Phase 2 not complete. phase_2_complete != true in $Phase2Path"
}

$runId        = [string]$phase2.run_id
$runDir       = Normalize-FullPath ([string]$phase2.run_dir)
$manifestPath = Normalize-FullPath ([string]$phase2.manifest_path)

Write-Host "[OK] Phase 2 gate satisfied. run_id=$runId"

# -------------------------
# Gate 2: Run workspace + manifest must exist
# -------------------------
if (-not (Test-Path -LiteralPath $runDir)) {
    Abort "Run directory missing: $runDir"
}
if (-not (Test-Path -LiteralPath $manifestPath)) {
    Abort "Run manifest missing: $manifestPath"
}

$inboxDir = Join-Path $runDir "inbox"
$logsDir  = Join-Path $runDir "logs"

if (-not (Test-Path -LiteralPath $inboxDir)) { Abort "Run inbox missing: $inboxDir" }
if (-not (Test-Path -LiteralPath $logsDir))  { Abort "Run logs missing: $logsDir" }

$manifest = Read-JsonStrict -Path $manifestPath
Require-Fields -Obj $manifest -ObjName "Run manifest" -Fields @(
    "schema_version",
    "run_id",
    "baseline_path",
    "baseline_sha256",
    "baseline_run_id",
    "baseline_p_top"
)

if ([string]$manifest.run_id -ne $runId) {
    Abort "Manifest run_id mismatch. Phase2=$runId Manifest=$($manifest.run_id)"
}

Write-Host "[OK] Workspace + manifest present."

# -------------------------
# Gate 3: Baseline must exist AND hash must match Phase 2 + manifest (TOCTOU closure)
# -------------------------
$phase2Baseline = Normalize-FullPath ([string]$phase2.baseline_path)
$manifestBaseline = Normalize-FullPath ([string]$manifest.baseline_path)
$actualBaseline = Normalize-FullPath $BaselinePath

if ($phase2Baseline -ne $actualBaseline) {
    Abort "Baseline path mismatch (Phase2 vs Actual). Phase2=$phase2Baseline | Actual=$actualBaseline"
}
if ($manifestBaseline -ne $actualBaseline) {
    Abort "Baseline path mismatch (Manifest vs Actual). Manifest=$manifestBaseline | Actual=$actualBaseline"
}
if (-not (Test-Path -LiteralPath $BaselinePath)) {
    Abort "Baseline artifact missing: $BaselinePath"
}

$baselineObj = Read-JsonStrict -Path $BaselinePath
Require-Fields -Obj $baselineObj -ObjName "Baseline artifact" -Fields @(
    "run_id","created_utc","engine","version","p_top","top_event_id","source_file"
)

# Cross-check lineage
if ([string]$baselineObj.run_id -ne [string]$phase2.baseline_run_id) {
    Abort "Baseline run_id mismatch (Baseline vs Phase2). Baseline=$($baselineObj.run_id) Phase2=$($phase2.baseline_run_id)"
}
if ([string]$baselineObj.run_id -ne [string]$manifest.baseline_run_id) {
    Abort "Baseline run_id mismatch (Baseline vs Manifest). Baseline=$($baselineObj.run_id) Manifest=$($manifest.baseline_run_id)"
}

# Compute hash NOW and compare to both anchors
$currentHash = (Get-FileHash -LiteralPath $BaselinePath -Algorithm SHA256).Hash
$phase2Hash  = [string]$phase2.baseline_sha256
$manHash     = [string]$manifest.baseline_sha256

if ($currentHash -ne $phase2Hash) {
    Abort "Baseline hash mismatch vs Phase2! Phase2=$phase2Hash Current=$currentHash (possible tamper/TOCTOU)"
}
if ($currentHash -ne $manHash) {
    Abort "Baseline hash mismatch vs Manifest! Manifest=$manHash Current=$currentHash (possible tamper/TOCTOU)"
}

Write-Host ("[OK] Hash-lock verified. sha256={0}" -f $currentHash)

# -------------------------
# Gate 4: TTL enforcement (optional)
# -------------------------
if ($BASELINE_TTL_SECONDS -gt 0) {
    $created = $null
    try { $created = [DateTime]::Parse([string]$baselineObj.created_utc).ToUniversalTime() }
    catch { Abort "Baseline created_utc is not parseable as DateTime: $($baselineObj.created_utc)" }

    $now = [DateTime]::UtcNow
    $ageSec = ($now - $created).TotalSeconds

    # Future timestamp = suspicious
    if ($ageSec -lt -60) {
        Abort "Baseline timestamp is in the future (clock/ttl attack). created_utc=$($baselineObj.created_utc)"
    }
    if ($ageSec -gt $BASELINE_TTL_SECONDS) {
        Abort ("Baseline expired by TTL. Age={0:N2}h TTL={1:N2}h created_utc={2}" -f ($ageSec/3600), ($BASELINE_TTL_SECONDS/3600), $baselineObj.created_utc)
    }

    Write-Host ("[OK] TTL validated. Baseline age={0:N2}h (TTL={1:N2}h)" -f ($ageSec/3600), ($BASELINE_TTL_SECONDS/3600))
} else {
    Write-Host "[WARN] TTL enforcement disabled (BASELINE_TTL_SECONDS=0)"
}

# -------------------------
# Phase 3 action: Write a proposal request into the run inbox (NO MODELS)
# -------------------------
$proposalRequestPath = Join-Path $inboxDir "proposal_request.json"

# If already present, fail-closed (prevents accidental overwrite / replay)
if (Test-Path -LiteralPath $proposalRequestPath) {
    Abort "proposal_request.json already exists (replay/overwrite blocked): $proposalRequestPath"
}

$proposalRequest = [ordered]@{
    schema_version      = "neo_proposal_request_v1"
    run_id              = $runId
    created_utc         = (Get-Date).ToUniversalTime().ToString("o")

    # Inputs (hash-locked)
    baseline_path       = $BaselinePath
    baseline_sha256     = $currentHash
    baseline_run_id     = [string]$baselineObj.run_id
    baseline_p_top      = [double]$baselineObj.p_top
    top_event_id        = [string]$baselineObj.top_event_id

    # Output expectations (future phase)
    expected_outputs    = @(
        "mantis_proposal.json"
    )

    # Governance note
    notes               = "Phase 3 staged request only. No models executed. Next step: planner consumes this request under governance."
}

Write-JsonAtomic -Path $proposalRequestPath -Obj $proposalRequest -Depth 50

# -------------------------
# Write Phase 3 state (atomic)
# -------------------------
$phase3 = [ordered]@{
    schema_version        = "neo_phase3_state_v1"
    phase_3_complete      = $true
    phase_3_utc           = (Get-Date).ToUniversalTime().ToString("o")

    run_id                = $runId
    run_dir               = $runDir
    manifest_path         = $manifestPath

    proposal_request_path = $proposalRequestPath

    baseline_path         = $BaselinePath
    baseline_sha256       = $currentHash
    baseline_run_id       = [string]$baselineObj.run_id
    baseline_p_top        = [double]$baselineObj.p_top

    # Future phase
    phase_4_complete      = $false
}

Write-JsonAtomic -Path $Phase3Path -Obj $phase3 -Depth 50

# Optional: drop a small phase3 log note into run logs (non-authoritative)
$phase3LogPath = Join-Path $logsDir "phase3_log.json"
$phase3Log = [ordered]@{
    schema_version = "neo_phase3_log_v1"
    utc            = (Get-Date).ToUniversalTime().ToString("o")
    message        = "Phase 3 staged proposal_request.json (no models). Hash-lock + TTL gates passed."
    baseline_sha256 = $currentHash
}
Write-JsonAtomic -Path $phase3LogPath -Obj $phase3Log -Depth 20

Write-Host "[OK] Phase 3 complete (staging only)."
Write-Host ("     Proposal request : {0}" -f $proposalRequestPath)
Write-Host ("     Phase3 state     : {0}" -f $Phase3Path)
Write-Host ("     Phase3 log       : {0}" -f $phase3LogPath)

exit 0
