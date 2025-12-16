Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Fail([string]$m){ throw "[ABORT] $m" }
function Info([string]$m){ Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Ok([string]$m){ Write-Host "[OK]   $m" -ForegroundColor Green }
function Warn([string]$m){ Write-Host "[WARN] $m" -ForegroundColor Yellow }

function Read-Json([string]$p){
  if(-not (Test-Path $p)){ return $null }
  try { Get-Content $p -Raw | ConvertFrom-Json } catch { return $null }
}

# -------------------------
# PHASE 4 — EXPLICIT AUTHORIZATION
# -------------------------
$NEO_ROOT   = "C:\ai_control\NEO_Stack"
$OUTBOX     = Join-Path $NEO_ROOT "queue_v2\outbox"
$PROPOSAL   = Get-ChildItem $OUTBOX -Filter "exec_proposal_*.json" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if(-not $PROPOSAL){ Fail "No proposal JSON found in outbox." }

$proposal = Read-Json $PROPOSAL.FullName
if(-not $proposal){ Fail "Proposal JSON invalid: $($PROPOSAL.FullName)" }

Write-Host ""
Write-Host "=== NEO EXECUTION (PHASE 4) — HUMAN GATE ===" -ForegroundColor White
Write-Host "Proposal: $($proposal.proposal_id)" -ForegroundColor White
Write-Host ""

# HARD GATE: user must type exact token
$expected = "APPROVE " + [string]$proposal.proposal_id
$typed = Read-Host "Type EXACTLY: $expected"
if($typed -ne $expected){ Fail "Authorization denied. No execution." }
Ok "Authorization accepted."

# -------------------------
# BOUNDED EXECUTION (ALLOWLIST ONLY)
# -------------------------
# For now: we do NOT execute arbitrary actions.
# We only re-run the Phase 2 orchestrator as the sole allowlisted operation.
$orchestrator = Join-Path $NEO_ROOT "neo_orchestrate.ps1"
if(-not (Test-Path $orchestrator)){ Fail "Missing orchestrator: $orchestrator" }

Info "ALLOWLIST: Running orchestrator only (Phase 2 repro under contract)."
powershell -ExecutionPolicy Bypass -File $orchestrator
if($LASTEXITCODE -ne 0){ Fail "Orchestrator failed (exit=$LASTEXITCODE)." }

Ok "Phase 4 bounded execution complete."
