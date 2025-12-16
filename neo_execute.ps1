Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Fail([string]$msg) { throw "[ABORT] $msg" }
function Info([string]$msg) { Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Ok([string]$msg)   { Write-Host "[OK]   $msg" -ForegroundColor Green }
function Warn([string]$msg) { Write-Host "[WARN] $msg" -ForegroundColor Yellow }

function Ensure-Dir([string]$p) {
  if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}

function Read-Json([string]$path) {
  if (-not (Test-Path $path)) { return $null }
  try { return (Get-Content $path -Raw | ConvertFrom-Json) } catch { return $null }
}

function Write-Json([object]$obj, [string]$path, [int]$depth = 12) {
  ($obj | ConvertTo-Json -Depth $depth) | Set-Content -Encoding UTF8 $path
}

function Sha256([string]$path) {
  if (-not (Test-Path $path)) { return $null }
  return (Get-FileHash -Algorithm SHA256 -Path $path).Hash.ToLowerInvariant()
}

function Find-LatestVerifiedTitanBaseline {
  param([string]$RunsRoot)

  if (-not (Test-Path $RunsRoot)) { return $null }

  $candidates =
    Get-ChildItem $RunsRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^TITAN_R\d+$' } |
    ForEach-Object {
      $out  = Join-Path $_.FullName "out"
      $base = Join-Path $out "baseline_summary.json"
      $sig  = Join-Path $out "baseline_summary.json.sig.json"
      if ((Test-Path $base) -and (Test-Path $sig)) {
        [pscustomobject]@{
          RunId = $_.Name
          OutDir = $out
          Baseline = $base
          Sig = $sig
          LastWriteTime = (Get-Item $sig).LastWriteTime
        }
      }
    } |
    Sort-Object LastWriteTime -Descending

  return ($candidates | Select-Object -First 1)
}

function Find-LatestMantisPlan {
  param([string]$RunsRoot)

  if (-not (Test-Path $RunsRoot)) { return $null }

  $plans =
    Get-ChildItem $RunsRoot -Recurse -File -Filter "mantis_plan.json" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending

  return ($plans | Select-Object -First 1)
}

function Verify-TitanBaselineContract {
  param(
    [string]$TitanRepo,
    [string]$BaselinePath
  )

  $verifyTool = Join-Path $TitanRepo "tools\praxis_artifact_verify.py"
  if (-not (Test-Path $verifyTool))   { Fail "VERIFY tool missing: $verifyTool" }
  if (-not (Test-Path $BaselinePath)) { Fail "Baseline missing: $BaselinePath" }

  Info "Verifying TITAN baseline contract (hash + TTL)..."
  & python $verifyTool --file $BaselinePath
  if ($LASTEXITCODE -ne 0) { Fail "Baseline verification failed (exit code=$LASTEXITCODE)." }

  Ok "Artifact integrity verified."
}

# ---------------------------
# CONFIG
# ---------------------------
$ROOT      = "C:\ai_control"
$NEO_ROOT  = "C:\ai_control\NEO_Stack"
$RUNS_ROOT = Join-Path $ROOT "runs"

$TITAN_REPO = "C:\ai_control\praxis-titan-p6.3"
if (-not (Test-Path $TITAN_REPO)) { Fail "TITAN repo not found: $TITAN_REPO" }

$QUEUE_V2  = Join-Path $NEO_ROOT "queue_v2"
$OUTBOX    = Join-Path $QUEUE_V2 "outbox"
$INBOX     = Join-Path $QUEUE_V2 "inbox"
$PROCESSED = Join-Path $QUEUE_V2 "processed"

Ensure-Dir $OUTBOX
Ensure-Dir $INBOX
Ensure-Dir $PROCESSED

Write-Host ""
Write-Host "=== NEO EXECUTION (PHASE 3) — PROPOSAL ONLY ===" -ForegroundColor White
Write-Host "Governance is enforced by contracts, not agents." -ForegroundColor White
Write-Host ""

# 1) Locate verified TITAN baseline
Info "Locating latest VERIFIED TITAN baseline..."
$titan = Find-LatestVerifiedTitanBaseline -RunsRoot $RUNS_ROOT
if (-not $titan) { Fail "No verified TITAN baseline found under: $RUNS_ROOT (expected TITAN_R*\out\baseline_summary.json + .sig.json)" }

Ok ("Found TITAN baseline: " + $titan.Baseline)
Ok ("Found signature:     " + $titan.Sig)
Ok ("TITAN run_id:        " + $titan.RunId)

# 2) Locate latest MANTIS plan
Info "Locating latest MANTIS plan..."
$mantisPlanFile = Find-LatestMantisPlan -RunsRoot $RUNS_ROOT
if (-not $mantisPlanFile) { Fail "No MANTIS plan found under: $RUNS_ROOT (expected mantis_plan.json)" }

Ok ("Found MANTIS plan:   " + $mantisPlanFile.FullName)

# 3) Verify baseline contract (fail-closed)
Verify-TitanBaselineContract -TitanRepo $TITAN_REPO -BaselinePath $titan.Baseline

# 4) Parse artifacts (fail-closed)
Info "Parsing baseline + plan JSON (fail-closed)..."
$baselineObj = Read-Json $titan.Baseline
if (-not $baselineObj) { Fail ("Baseline JSON invalid: " + $titan.Baseline) }

$planObj = Read-Json $mantisPlanFile.FullName
if (-not $planObj) { Fail ("MANTIS plan JSON invalid: " + $mantisPlanFile.FullName) }

Ok "Baseline JSON parse OK."
Ok "MANTIS plan JSON parse OK."

# 5) Extract canonical fields
$pTop = $null
try { $pTop = [double]$baselineObj.p_top } catch { $pTop = $null }
if ($null -eq $pTop -or $pTop -lt 0 -or $pTop -gt 1) { Fail ("Baseline missing/invalid p_top. Got: " + $pTop) }

$topEventId = $null
try { $topEventId = [string]$baselineObj.top_event_id } catch { $topEventId = $null }

$baselineHash = Sha256 $titan.Baseline
$planHash     = Sha256 $mantisPlanFile.FullName
if (-not $baselineHash) { Fail "Could not hash baseline file." }
if (-not $planHash)     { Fail "Could not hash plan file." }

# 6) Extract a bounded action container (schema-agnostic)
$actions = @()
if ($planObj.PSObject.Properties.Name -contains "actions")      { $actions = $planObj.actions }
elseif ($planObj.PSObject.Properties.Name -contains "plan")     { $actions = $planObj.plan }
elseif ($planObj.PSObject.Properties.Name -contains "steps")    { $actions = $planObj.steps }
else { $actions = @() }

# 7) Emit proposal artifacts
$ts = (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmss_fff")
$proposalId = "NEO_EXEC_PROPOSAL_$ts"

$proposalJsonPath = Join-Path $OUTBOX ("exec_proposal_{0}.json" -f $ts)
$proposalMdPath   = Join-Path $OUTBOX ("exec_proposal_{0}.md"   -f $ts)

$proposal = [ordered]@{
  proposal_id = $proposalId
  created_utc = (Get-Date).ToUniversalTime().ToString("o")
  posture = [ordered]@{
    authority = "HUMAN"
    autonomous_execution = $false
    note = "Governed proposal only. No actions are executed in Phase 3."
  }
  inputs = [ordered]@{
    titan = [ordered]@{
      run_id = $titan.RunId
      baseline_file = $titan.Baseline
      signature_file = $titan.Sig
      sha256 = $baselineHash
      p_top = $pTop
      top_event_id = $topEventId
    }
    mantis = [ordered]@{
      plan_file = $mantisPlanFile.FullName
      sha256 = $planHash
    }
  }
  governed_frame = [ordered]@{
    attack = "If unverified artifacts are consumed, the control-plane becomes an injection surface."
    consequence = "Outputs become non-auditable; planning can be corrupted."
    mitigation = "Fail-closed: verify TITAN baseline signature + TTL; parse MANTIS plan only from disk artifacts."
    verification_test = @(
      "praxis_artifact_verify returns OK on baseline_summary.json",
      "baseline_summary.json contains p_top in [0,1]",
      "mantis_plan.json parses as JSON",
      "exec_proposal JSON and MD are emitted to NEO outbox"
    )
  }
  proposed_actions = $actions
  human_gate = [ordered]@{
    required = $true
    instruction = "Review proposal. If acceptable, explicitly authorize Phase 4 execution (separate script)."
  }
}

Write-Json $proposal $proposalJsonPath 14

$actionsNote = "No explicit action list detected in plan schema. Refer to full plan file."
if ($actions -and ($actions | Measure-Object).Count -gt 0) {
  $actionsNote = "Action container detected (schema-agnostic extract). Review full plan for details."
}

$md = @"
# NEO — Execution Proposal (Phase 3)

Proposal ID: $proposalId

## Contract Inputs
TITAN run_id      : $($titan.RunId)
Baseline file     : $($titan.Baseline)
Baseline SHA256   : $baselineHash
p_top             : $pTop
Top event id      : $topEventId

MANTIS plan file  : $($mantisPlanFile.FullName)
MANTIS plan SHA256: $planHash

## PRAXIS Frame
Attack       : If unverified artifacts are consumed, the control-plane becomes an injection surface.
Consequence  : Outputs become non-auditable; planning can be corrupted.
Mitigation   : Fail-closed verification of TITAN baseline contract + bounded JSON parsing.
Verification : verify tool OK + p_top present + plan parses + proposal emitted.

## Posture
Authority            : HUMAN
Autonomous execution : DISABLED

## Proposed Actions (bounded extract)
$actionsNote

## Human Gate
No execution occurs in Phase 3.
Phase 4 requires explicit authorization in a separate script.
"@

$md | Set-Content -Encoding UTF8 $proposalMdPath

Ok "Phase 3 proposal written:"
Ok ("JSON: " + $proposalJsonPath)
Ok ("MD  : " + $proposalMdPath)

Write-Host ""
Write-Host "=== GOVERNED EXECUTION RESULT (PHASE 3) ===" -ForegroundColor Green
Write-Host "Proposal: PRESENT (outbox)" -ForegroundColor Green
Write-Host "Authority: HUMAN (no autonomous execution)" -ForegroundColor Green
Write-Host ""
Write-Host "[NEXT] Open the proposal:" -ForegroundColor Yellow
Write-Host ("notepad " + $proposalMdPath) -ForegroundColor Yellow
Write-Host ""
