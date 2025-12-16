# neo_loop.ps1
# PRAXIS NEO-LAB — Queue Consumer (ARCH_BREAK Hardened v2)
# Fixes: null path root by anchoring to $PSScriptRoot and fail-closed path validation

$ErrorActionPreference = "Stop"

# --- Anchor root deterministically ---
$ROOT = $PSScriptRoot
if (-not $ROOT) {
    # Fail-closed: if PowerShell can't resolve script root, abort loudly
    Write-Host "[NEO-LAB] ABORT: PSScriptRoot is null. Run this script from a file, not pasted blocks." -ForegroundColor Red
    exit 1
}

$QROOT = Join-Path $ROOT "queue_v2"

$INBOX      = Join-Path $QROOT "inbox"
$PROCESSING = Join-Path $QROOT "processing"
$PROCESSED  = Join-Path $QROOT "processed"
$OUTBOX     = Join-Path $QROOT "outbox"

# --- Fail-closed path sanity ---
foreach ($kv in @(
    @{k="ROOT"; v=$ROOT},
    @{k="QROOT"; v=$QROOT},
    @{k="INBOX"; v=$INBOX},
    @{k="PROCESSING"; v=$PROCESSING},
    @{k="PROCESSED"; v=$PROCESSED},
    @{k="OUTBOX"; v=$OUTBOX}
)) {
    if ([string]::IsNullOrWhiteSpace($kv.v)) {
        Write-Host "[NEO-LAB] ABORT: Path $($kv.k) resolved null/empty." -ForegroundColor Red
        exit 1
    }
}

# --- Ensure dirs exist ---
foreach ($p in @($QROOT, $INBOX, $PROCESSING, $PROCESSED, $OUTBOX)) {
    if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p | Out-Null }
}

function Write-Status {
    param(
        [Parameter(Mandatory=$true)][string]$MessageId,
        [Parameter(Mandatory=$true)][string]$Phase,
        [Parameter(Mandatory=$false)][string]$Detail = ""
    )
    $dir = Join-Path $OUTBOX $MessageId
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }

    $statusPath = Join-Path $dir "status.json"
    $obj = @{
        message_id  = $MessageId
        phase       = $Phase
        detail      = $Detail
        updated_utc = (Get-Date).ToUniversalTime().ToString("o")
    }
    ($obj | ConvertTo-Json -Depth 8) | Set-Content -Encoding UTF8 $statusPath
}

function Write-Response {
    param(
        [Parameter(Mandatory=$true)][string]$MessageId,
        [Parameter(Mandatory=$true)][string]$Text
    )
    $dir = Join-Path $OUTBOX $MessageId
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }

    $respPath = Join-Path $dir "response.txt"
    $Text | Set-Content -Encoding UTF8 $respPath
}

function Safe-ReadJson {
    param([Parameter(Mandatory=$true)][string]$Path)
    try {
        $raw = Get-Content -Raw -Encoding UTF8 $Path
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Claim-NextMessage {
    $candidates = Get-ChildItem -Path $INBOX -Filter "*.json" -File |
        Sort-Object LastWriteTime

    foreach ($f in $candidates) {
        $dest = Join-Path $PROCESSING $f.Name
        try {
            Move-Item -Path $f.FullName -Destination $dest -Force
            return $dest
        } catch {
            continue
        }
    }
    return $null
}

function Complete-Message {
    param([Parameter(Mandatory=$true)][string]$ProcessingPath)
    $name = Split-Path -Leaf $ProcessingPath
    $dest = Join-Path $PROCESSED $name
    try { Move-Item -Path $ProcessingPath -Destination $dest -Force } catch { }
}

function QuoteFirst-Render {
    param([Parameter(Mandatory=$true)]$Msg)

    $mid = [string]$Msg.message_id
    $created = ""
    if ($Msg.PSObject.Properties.Name -contains "created_utc") { $created = [string]$Msg.created_utc }
    $user = ""
    if ($Msg.PSObject.Properties.Name -contains "user") { $user = [string]$Msg.user }
    $cwd = ""
    if ($Msg.PSObject.Properties.Name -contains "cwd") { $cwd = [string]$Msg.cwd }
    $content = ""
    if ($Msg.PSObject.Properties.Name -contains "content") { $content = [string]$Msg.content }

    $rawBlock = @"
=== RAW MESSAGE (AUTHORITATIVE) ===
message_id: $mid
created_utc: $created
user: $user
cwd: $cwd

content:
$content
=== END RAW MESSAGE ===

"@

    $narrative = @"
ANALYSIS (NON-AUTHORITATIVE):

This is the governed narrative zone.
- It may summarize or explain the RAW MESSAGE above.
- It may NOT contradict, override, or omit quoted fields.
- If uncertain, it must state uncertainty.

NOTE:
Model execution will be wired in here next.
"@

    return ($rawBlock + $narrative)
}

# ---------------------------
# MAIN LOOP
# ---------------------------

Write-Host "NEO-LAB loop started."
Write-Host "ROOT     : $ROOT"
Write-Host "INBOX    : $INBOX"
Write-Host "PROCESS  : $PROCESSING"
Write-Host "DONE     : $PROCESSED"
Write-Host "OUTBOX   : $OUTBOX"
Write-Host "Press Ctrl+C to stop."

while ($true) {

    $claimed = Claim-NextMessage
    if (-not $claimed) {
        Start-Sleep -Milliseconds 250
        continue
    }

    $msg = Safe-ReadJson -Path $claimed
    if (-not $msg) {
        $badId = "unknown_" + (Get-Date -Format "yyyyMMdd_HHmmss_fff")
        Write-Status -MessageId $badId -Phase "ABORT" -Detail "Invalid JSON claimed: $(Split-Path -Leaf $claimed)"
        Complete-Message -ProcessingPath $claimed
        continue
    }

    if (-not $msg.message_id -or -not $msg.content) {
        $badId2 = $msg.message_id
        if (-not $badId2) { $badId2 = "unknown_" + (Get-Date -Format "yyyyMMdd_HHmmss_fff") }
        Write-Status -MessageId $badId2 -Phase "ABORT" -Detail "Missing required fields (message_id/content)."
        Complete-Message -ProcessingPath $claimed
        continue
    }

    $mid = [string]$msg.message_id

    Write-Status -MessageId $mid -Phase "CLAIMED" -Detail "Processing message."
    Write-Status -MessageId $mid -Phase "RUNNING" -Detail "Generating response (quote-first scaffold)."

    try {
        $response = QuoteFirst-Render -Msg $msg
        Write-Response -MessageId $mid -Text $response
        Write-Status  -MessageId $mid -Phase "DONE" -Detail "Quote-first response written."
    } catch {
        Write-Status -MessageId $mid -Phase "ABORT" -Detail ("Runtime error: " + $_.Exception.Message)
    }

    Complete-Message -ProcessingPath $claimed
}

