Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Abort([string]$msg) { throw "[ABORT] $msg" }

Write-Host "[NEO] Phase 5 - Execution Gate (DRY_RUN)" -ForegroundColor Cyan

# Load Phase 4 state
$phase4Path = "C:\ai_control\NEO_Stack\runtime\neo_phase4_state.json"
if (-not (Test-Path $phase4Path)) { Abort "missing Phase4 state" }

$p4 = Get-Content $phase4Path -Raw | ConvertFrom-Json

$runDir = [System.IO.Path]::GetFullPath($p4.run_dir)
$inbox  = Join-Path $runDir "inbox"

# Required artifacts
$authPath = Join-Path $inbox "phase4_auth.json"
$sigPath  = Join-Path $inbox "phase4_auth.sig"
$reqPath  = Join-Path $inbox "proposal_request.json"
$manPath  = Join-Path $runDir "run_manifest.json"

foreach ($p in @($authPath,$sigPath,$reqPath,$manPath)) {
    if (-not (Test-Path $p)) { Abort "missing required artifact: $p" }
}

Write-Host "[OK] Phase4 envelope present" -ForegroundColor Green

# DRY RUN intent
$intent = "DRY_RUN_ONLY"
Write-Host "[INFO] Execution intent: $intent" -ForegroundColor Yellow

# Hash verification
$reqHash = (Get-FileHash $reqPath -Algorithm SHA256).Hash
$manHash = (Get-FileHash $manPath -Algorithm SHA256).Hash

Write-Host "Proposal SHA256 : $reqHash"
Write-Host "Manifest SHA256 : $manHash"

# Write Phase 5 state
$state = [ordered]@{
    phase           = 5
    mode            = "DRY_RUN"
    run_dir         = $runDir
    proposal_sha256 = $reqHash
    manifest_sha256 = $manHash
    executed        = $false
    timestamp_utc   = (Get-Date).ToUniversalTime().ToString("o")
}

$outPath = "C:\ai_control\NEO_Stack\runtime\neo_phase5_state.json"
$tmp = "$outPath.tmp_$([guid]::NewGuid().ToString('N'))"
$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($tmp, ($state | ConvertTo-Json -Depth 10), $utf8)
Move-Item $tmp $outPath -Force

Write-Host "[NEO] Phase 5 DRY_RUN complete - execution NOT performed" -ForegroundColor Cyan

