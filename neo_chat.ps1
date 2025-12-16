# neo_chat.ps1
# PRAXIS NEO-LAB — Atomic Inbox Writer
# ARCH_BREAK hardened

$ErrorActionPreference = "Stop"

$ROOT = Split-Path -Parent $MyInvocation.MyCommand.Path
$QUEUE = Join-Path $ROOT "queue_v2\inbox"

if (-not (Test-Path $QUEUE)) {
    New-Item -ItemType Directory -Path $QUEUE | Out-Null
}

# Generate deterministic message ID
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss_fff"
$procId = $PID
$msg_id = "msg_${timestamp}_${procId}"

$payload = @{
    message_id  = $msg_id
    created_utc = (Get-Date).ToUniversalTime().ToString("o")
    user        = $env:USERNAME
    cwd         = (Get-Location).Path
    content     = Read-Host "Enter message"
}

$json = $payload | ConvertTo-Json -Depth 5

$tmp   = Join-Path $QUEUE "$msg_id.json.tmp"
$final = Join-Path $QUEUE "$msg_id.json"

# --- ATOMIC WRITE ---
$json | Out-File -Encoding UTF8 -NoNewline $tmp
Move-Item -Force $tmp $final
# --------------------

Write-Host "Queued message $msg_id"

