# ============================================================
# NEO ORCHESTRATION — PHASE 2 (HARDENED)
# NEO → TITAN → SIGN/VERIFY → MANTIS → LOCATE PLAN → VERIFY
#
# Governance is enforced by contracts, not agents.
# ============================================================

$ErrorActionPreference = "Stop"

function Fail($msg) { throw "[ABORT] $msg" }

Write-Host "[INFO] === NEO ORCHESTRATION (PHASE 2) ===" -ForegroundColor Cyan

# ------------------------------------------------------------
# Roots
# ------------------------------------------------------------
$ROOT        = "C:\ai_control"
$NEO_ROOT    = Join-Path $ROOT "NEO_Stack"
$TITAN_REPO  = Join-Path $ROOT "praxis-titan-p6.3"
$MANTIS_REPO = Join-Path $ROOT "mantis"

# ------------------------------------------------------------
# Run IDs (TITAN is controlled here; MANTIS may be hardcoded internally)
# ------------------------------------------------------------
$TITAN_RUN  = "TITAN_R2"
$MANTIS_RUN = "MANTIS_R2"

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------
function Find-Example($name) {
    $hit = Get-ChildItem $ROOT -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq $name } |
        Select-Object -First 1
    if (-not $hit) { Fail "Config example not found: $name" }
    return $hit.FullName
}

function Require-Path($p, $label) {
    if (-not (Test-Path $p)) { Fail "$label missing: $p" }
}

# ------------------------------------------------------------
# Directories
# ------------------------------------------------------------
$TITAN_RUN_DIR = Join-Path $ROOT "runs\$TITAN_RUN"
$TITAN_OUT_DIR = Join-Path $TITAN_RUN_DIR "out"

mkdir $TITAN_RUN_DIR -Force | Out-Null
mkdir $TITAN_OUT_DIR -Force | Out-Null

# ------------------------------------------------------------
# Locate TITAN example configs (auto-discovery)
# ------------------------------------------------------------
Write-Host "[INFO] Materializing TITAN configs (fail-closed)..." -ForegroundColor Cyan

$CFG_SCEN_EX = Find-Example "configscenario_example.json.txt"
$CFG_PRI_EX  = Find-Example "configrisk_priors_example.json.txt"
$CFG_CCF_EX  = Find-Example "configccf_groups_example.json.txt"
$CFG_FT_EX   = Find-Example "configfault_tree_example.json.txt"
$CFG_CAS_EX  = Find-Example "configcascade_example.json.txt"

Copy-Item $CFG_SCEN_EX (Join-Path $TITAN_RUN_DIR "scenario_config.json") -Force
Copy-Item $CFG_PRI_EX  (Join-Path $TITAN_RUN_DIR "risk_priors.json")     -Force
Copy-Item $CFG_CCF_EX  (Join-Path $TITAN_RUN_DIR "ccf_groups.json")      -Force
Copy-Item $CFG_FT_EX   (Join-Path $TITAN_RUN_DIR "fault_tree.json")      -Force
Copy-Item $CFG_CAS_EX  (Join-Path $TITAN_RUN_DIR "cascade.json")         -Force

# ------------------------------------------------------------
# Run TITAN
# ------------------------------------------------------------
Write-Host "[INFO] Running TITAN ($TITAN_RUN)..." -ForegroundColor Cyan

python "$ROOT\praxis_core_run.py" `
    --scenario-config "$TITAN_RUN_DIR\scenario_config.json" `
    --priors          "$TITAN_RUN_DIR\risk_priors.json" `
    --ccf-groups      "$TITAN_RUN_DIR\ccf_groups.json" `
    --fault-tree      "$TITAN_RUN_DIR\fault_tree.json" `
    --cascade         "$TITAN_RUN_DIR\cascade.json" `
    --out-dir         "$TITAN_OUT_DIR" `
    --pseudo-n        1000

# ------------------------------------------------------------
# Locate TITAN output JSON
# ------------------------------------------------------------
$TITAN_OUTPUT = Get-ChildItem $TITAN_OUT_DIR -Filter "*praxis_output.json" -File |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

if (-not $TITAN_OUTPUT) { Fail "No TITAN output JSON produced in: $TITAN_OUT_DIR" }

# ------------------------------------------------------------
# Extract p_top (canonical)
# ------------------------------------------------------------
$j = Get-Content $TITAN_OUTPUT.FullName -Raw | ConvertFrom-Json
try { $p_top = [double]$j.fault_tree.top_events[0].probability } catch { Fail "Failed to extract p_top from TITAN output." }
if ($p_top -lt 0 -or $p_top -gt 1) { Fail "p_top out of range: $p_top" }

# ------------------------------------------------------------
# Build baseline_summary.json (contract) — UTF8 NO BOM
# ------------------------------------------------------------
$BASELINE = Join-Path $TITAN_OUT_DIR "baseline_summary.json"

$baselineObj = [ordered]@{
    run_id        = $TITAN_RUN
    created_utc   = (Get-Date).ToUniversalTime().ToString("o")
    engine        = "PRAXIS_TITAN"
    version       = "P6.3"
    p_top         = $p_top
    top_event_id  = $j.fault_tree.top_events[0].top_event_id
    source_file   = $TITAN_OUTPUT.Name
}

$jsonText = ($baselineObj | ConvertTo-Json -Depth 8)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($BASELINE, $jsonText, $utf8NoBom)

# ------------------------------------------------------------
# Sign + verify baseline (TITAN tools)
# ------------------------------------------------------------
$SIGN_TOOL   = Join-Path $TITAN_REPO "tools\praxis_artifact_sign.py"
$VERIFY_TOOL = Join-Path $TITAN_REPO "tools\praxis_artifact_verify.py"

Require-Path $SIGN_TOOL   "SIGN tool"
Require-Path $VERIFY_TOOL "VERIFY tool"

python $SIGN_TOOL `
    --file $BASELINE `
    --run-id $TITAN_RUN `
    --ttl-seconds 86400 `
    --engine "PRAXIS_TITAN" `
    --version "P6.3"

python $VERIFY_TOOL --file $BASELINE

$BASE_SIG = "$BASELINE.sig.json"
Require-Path $BASE_SIG "Baseline signature"

# ------------------------------------------------------------
# Copy baseline into MANTIS inputs (HARDENED)
# MANTIS may be hardcoded to MANTIS_R1 internally.
# We therefore populate BOTH MANTIS_R1 and MANTIS_R2 inputs.
# ------------------------------------------------------------
$MANTIS_R1_IN = Join-Path $ROOT "runs\MANTIS_R1\input"
$MANTIS_R2_IN = Join-Path $ROOT "runs\$MANTIS_RUN\input"

mkdir $MANTIS_R1_IN -Force | Out-Null
mkdir $MANTIS_R2_IN -Force | Out-Null

Copy-Item $BASELINE (Join-Path $MANTIS_R1_IN "baseline_summary.json") -Force
Copy-Item $BASE_SIG (Join-Path $MANTIS_R1_IN "baseline_summary.json.sig.json") -Force

Copy-Item $BASELINE (Join-Path $MANTIS_R2_IN "baseline_summary.json") -Force
Copy-Item $BASE_SIG (Join-Path $MANTIS_R2_IN "baseline_summary.json.sig.json") -Force

# ------------------------------------------------------------
# Run MANTIS
# ------------------------------------------------------------
Write-Host "[INFO] Running MANTIS ($MANTIS_RUN)..." -ForegroundColor Cyan
Require-Path $MANTIS_REPO "MANTIS repo"

Push-Location $MANTIS_REPO
python .\mantis_run.py
Pop-Location

# ------------------------------------------------------------
# Locate newest mantis_plan.json anywhere under runs\*\out (FAIL-CLOSED)
# ------------------------------------------------------------
$PLAN_HIT = Get-ChildItem (Join-Path $ROOT "runs") -Recurse -Filter "mantis_plan.json" -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

if (-not $PLAN_HIT) { Fail "MANTIS plan not produced (no mantis_plan.json found under $ROOT\runs)" }

# Ensure JSON parses (contract hygiene)
try {
    $null = (Get-Content $PLAN_HIT.FullName -Raw | ConvertFrom-Json)
} catch {
    Fail "MANTIS plan exists but is not valid JSON: $($PLAN_HIT.FullName)"
}

# ------------------------------------------------------------
# Final governed response
# ------------------------------------------------------------
Write-Host ""
Write-Host "=== GOVERNED ORCHESTRATION RESULT ===" -ForegroundColor Green
Write-Host "TITAN baseline : VERIFIED (p_top=$p_top)"
Write-Host "MANTIS plan    : PRESENT ($($PLAN_HIT.FullName))"
Write-Host "Authority      : HUMAN (no autonomous execution)"
Write-Host ""
Write-Host "[OK] Phase 2 orchestration complete." -ForegroundColor Green

