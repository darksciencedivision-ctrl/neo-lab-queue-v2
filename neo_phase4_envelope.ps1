# neo_phase4_envelope.ps1
# NEO Phase 4 - Envelope (Human + Crypto Gate) - Windows PowerShell 5.1 compatible
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Abort([string]$msg) { throw "[ABORT] $msg" }

function Normalize-Path([string]$p) {
  if ([string]::IsNullOrWhiteSpace($p)) { return $null }
  if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path (Get-Location) $p }
  return [System.IO.Path]::GetFullPath($p)
}

function Get-PropFirst($obj, [string[]]$names) {
  foreach ($n in $names) {
    if ($obj -and ($obj.PSObject.Properties.Name -contains $n)) {
      $v = $obj.$n
      if ($null -ne $v -and "$v".Length -gt 0) { return [string]$v }
    }
  }
  return $null
}

Write-Host "[NEO] Phase 4 - Envelope (Human + Crypto gate; PS 5.1)" -ForegroundColor Cyan

# --- Load Phase 2 state (source of truth)
$phase2Path = "C:\ai_control\NEO_Stack\runtime\neo_phase2_state.json"
if (-not (Test-Path $phase2Path)) { Abort "missing neo_phase2_state.json" }
$p2 = Get-Content $phase2Path -Raw | ConvertFrom-Json

$runDir       = Normalize-Path (Get-PropFirst $p2 @("run_dir","run_workspace","workspace","work_dir"))
$baselinePath = Normalize-Path (Get-PropFirst $p2 @("baseline_path","baseline_summary_path","baseline_file","baseline"))
$manifestPath = Normalize-Path (Get-PropFirst $p2 @("manifest_path","run_manifest_path","manifest"))
$baselineSha  = Get-PropFirst $p2 @("baseline_sha256","sha256","baseline_hash","baseline_digest")

if (-not $runDir)       { Abort "Phase2 missing run_dir/workspace path" }
if (-not $baselinePath) { Abort "Phase2 missing baseline_path" }

$inbox = Join-Path $runDir "inbox"
if (-not (Test-Path $inbox)) { Abort "missing inbox: $inbox" }

# --- Required inbox artifacts
$reqPath   = Join-Path $inbox "proposal_request.json"
$authPath  = Join-Path $inbox "phase4_auth.json"
$authSig   = Join-Path $inbox "phase4_auth.sig"

if (-not (Test-Path $reqPath)) { Abort "missing proposal_request.json" }
if (-not (Test-Path $authPath)) { Abort "missing phase4_auth.json (create it first)" }
if (-not (Test-Path $authSig)) { Abort "missing phase4_auth.sig (sign auth first)" }

# --- Load proposal_request and verify baseline_path matches Phase2 (canonical)
$req = Get-Content $reqPath -Raw | ConvertFrom-Json
$reqBaseline = Normalize-Path ([string]$req.baseline_path)

Write-Host "[OK] Phase 1/2/3 gates satisfied. run_dir=$runDir" -ForegroundColor Green
Write-Host "[OK] baseline_path (Phase2): $baselinePath" -ForegroundColor DarkGray
Write-Host "[OK] baseline_path (Request): $reqBaseline" -ForegroundColor DarkGray

if ($baselinePath.ToLowerInvariant() -ne $reqBaseline.ToLowerInvariant()) {
  Abort "proposal_request baseline_path mismatch"
}

# --- Verify manifest (optional but checked if provided)
if ($manifestPath) {
  if (-not (Test-Path $manifestPath)) { Abort "manifest_path not found: $manifestPath" }
  Write-Host "[OK] Manifest present: $manifestPath" -ForegroundColor Green
}

# --- Human gate (explicit approval)
$hashObj = Get-FileHash -Path $authPath -Algorithm SHA256
Write-Host ""
Write-Host "==================== HUMAN AUTH GATE ====================" -ForegroundColor Yellow
Write-Host "Auth file: $authPath"
Write-Host "Auth SHA256: $($hashObj.Hash)"
Write-Host "Signature file: $authSig"
Write-Host "=========================================================" -ForegroundColor Yellow
$approve = Read-Host "Type APPROVE to accept this authorization (anything else cancels)"
if ($approve -cne "APPROVE") { Abort "user cancelled at human gate" }

# --- Verify auth signature using public key
$keyDir = "C:\ai_control\NEO_Stack\keys"
$pubKeyPath = Join-Path $keyDir "human_auth_pub.xml"
if (-not (Test-Path $pubKeyPath)) { Abort "missing public key: $pubKeyPath" }

try {
  $pubXml = Get-Content $pubKeyPath -Raw
  $rsaPub = New-Object System.Security.Cryptography.RSACryptoServiceProvider
  $rsaPub.FromXmlString($pubXml)

  $authBytes = [System.IO.File]::ReadAllBytes($authPath)
  $sigBytes  = [System.IO.File]::ReadAllBytes($authSig)

  $ok = $rsaPub.VerifyData($authBytes, "SHA256", $sigBytes)
  if (-not $ok) { Abort "auth signature verification FAILED" }

  Write-Host "[OK] Auth signature verified (RSA/SHA256)" -ForegroundColor Green
}
finally {
  if ($rsaPub) { $rsaPub.Clear(); $rsaPub.Dispose() }
}

# --- Envelope success output (no model execution here; just gating)
$phase4State = [ordered]@{
  phase        = 4
  run_dir      = $runDir
  inbox        = $inbox
  created_utc  = (Get-Date).ToUniversalTime().ToString("o")
  baseline_path = $baselinePath
  baseline_sha256 = $baselineSha
  auth_path    = $authPath
  auth_sig     = $authSig
  request_path = $reqPath
  manifest_path = $manifestPath
  status       = "OK_ENVELOPE_VERIFIED"
}

$statePath = "C:\ai_control\NEO_Stack\runtime\neo_phase4_state.json"
$tmp = "$statePath.tmp_$([guid]::NewGuid().ToString('N'))"
$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($tmp, ($phase4State | ConvertTo-Json -Depth 80), $utf8)
Move-Item -LiteralPath $tmp -Destination $statePath -Force

Write-Host "[NEO] Phase 4 complete (auth + signature verified; staged)" -ForegroundColor Cyan
Write-Host "Phase4 state: $statePath" -ForegroundColor DarkGray
