# ============================================================
# NEO CHAT — QUEUE V2 (ATOMIC FILE IPC) + MULTI-LINE + /HELP + PROGRESS
# PowerShell 5.1 + StrictMode safe
# ============================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ROOT      = Get-Location
$Q2_ROOT   = Join-Path $ROOT "queue_v2"
$INBOX     = Join-Path $Q2_ROOT "inbox"
$OUTBOX    = Join-Path $Q2_ROOT "outbox"
$PROCESSED = Join-Path $Q2_ROOT "processed"

$script:LastResponseText = ""

function Ensure-Folders {
    foreach ($p in @($Q2_ROOT,$INBOX,$OUTBOX,$PROCESSED)) {
        if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p | Out-Null }
    }
}

function Now-UtcIso { return ([DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")) }

function New-MessageId {
    $ts = Get-Date -Format "yyyyMMdd_HHmmss_fff"
    $rand = -join ((65..90) + (48..57) | Get-Random -Count 6 | ForEach-Object {[char]$_})
    return ("{0}_{1}" -f $ts, $rand)
}

function Write-InboxMessage([string]$payload) {
    $id = New-MessageId
    $obj = @{
        id = $id
        ts_utc = (Now-UtcIso)
        type = "user_message"
        payload = $payload
    }
    $path = Join-Path $INBOX ("{0}.json" -f $id)
    $obj | ConvertTo-Json -Depth 10 | Set-Content $path -Encoding UTF8
    return $id
}

function Outbox-Dir([string]$id) { return (Join-Path $OUTBOX $id) }
function Status-Path([string]$id) { return (Join-Path (Outbox-Dir $id) "status.json") }
function Response-Path([string]$id){ return (Join-Path (Outbox-Dir $id) "response.txt") }

function Read-JsonOrNull([string]$path) {
    if (-not (Test-Path $path)) { return $null }
    try { return (Get-Content $path -Raw) | ConvertFrom-Json } catch { return $null }
}

function Wait-ForResponse([string]$id, [int]$TimeoutSec = 900) {
    $start = Get-Date
    $respPath = Response-Path $id
    $statusPath = Status-Path $id

    $lastPhase = ""

    while ($true) {
        Start-Sleep -Milliseconds 200
        if ((Get-Date) - $start -gt [TimeSpan]::FromSeconds($TimeoutSec)) { return $null }

        # Show progress if available
        $st = Read-JsonOrNull $statusPath
        if ($st -and ($st.PSObject.Properties.Name -contains "phase")) {
            $phase = [string]$st.phase
            if ($phase -and ($phase -ne $lastPhase)) {
                Write-Host ("[NEO] working... phase={0}" -f $phase) -ForegroundColor DarkGray
                $lastPhase = $phase
            }
        }

        if (Test-Path $respPath) {
            try { return (Get-Content $respPath -Raw) } catch { return $null }
        }
    }
}

function Show-Help {
@"
NEO CHAT (QUEUE V2) COMMANDS
===========================

/help                 Show this help
/exit                 Exit
/pwd                  Show current directory
/cd <path>            Change directory (chat-side only)

/ml                   Multi-line input mode (.send / .cancel)

/summary <topic>      One concise response
/detail <topic>       One detailed response
/report <topic>       One multi-page report (single response)

/save <path>          Save last response to a file

Pass-through to NEO loop:
/status
/objective <text>
/context <text>
/reportmode on|off|status
/memclear chat|code|analysis|vision|all
"@ | Write-Host
}

function Build-OneShotPrompt([string]$kind, [string]$topic) {
    if (-not $topic) { $topic = "UNSPECIFIED_TOPIC" }

    if ($kind -eq "SUMMARY") {
@"
[NEO_OUTPUT_MODE:SUMMARY]
Provide ONE single response only. No questions. Be concise and complete.
Topic:
$topic
"@
        return
    }

    if ($kind -eq "DETAIL") {
@"
[NEO_OUTPUT_MODE:DETAILED]
Provide ONE single response only. No questions. Be thorough and technical.
Topic:
$topic
"@
        return
    }

@"
[NEO_OUTPUT_MODE:REPORT]
Produce ONE single multi-page report in one response. No questions.
Include: Executive Summary, Scope & Assumptions, Core Analysis, Methods/Math (if applicable),
Implementation (if applicable), Risks/Limitations/Verification Checklist, References/Source Guidance.
Topic:
$topic
"@
}

function Read-Multiline([string]$banner) {
    if ($banner) { Write-Host $banner -ForegroundColor Cyan }
    Write-Host "Multi-line mode (.send to finish, .cancel to abort)" -ForegroundColor DarkGray
    $lines = New-Object System.Collections.Generic.List[string]
    while ($true) {
        $line = Read-Host "..."
        if ($line -eq ".cancel") { return $null }
        if ($line -eq ".send")   { break }
        $lines.Add($line) | Out-Null
    }
    return ($lines -join "`n")
}

# ---------------------------
# Main
# ---------------------------
Ensure-Folders
Write-Host "=== NEO CHAT STARTED (QUEUE V2) ===" -ForegroundColor Green
Write-Host "Type /help for commands." -ForegroundColor DarkGray

while ($true) {
    $inputLine = Read-Host "NEO>"

    if (-not $inputLine) { continue }

    if ($inputLine -eq "/exit") { break }
    if ($inputLine -eq "/help") { Show-Help; continue }
    if ($inputLine -eq "/pwd")  { Write-Host (Get-Location); continue }

    if ($inputLine.StartsWith("/cd ")) {
        $path = $inputLine.Substring(4).Trim()
        try { Set-Location $path; Write-Host ("Now in: {0}" -f (Get-Location)) -ForegroundColor Green } catch { Write-Host $_.Exception.Message -ForegroundColor Red }
        continue
    }

    if ($inputLine.StartsWith("/save ")) {
        $path = $inputLine.Substring(6).Trim()
        if (-not $path) { Write-Host "Usage: /save C:\path\file.txt" -ForegroundColor Yellow; continue }
        if (-not $script:LastResponseText) { Write-Host "No response to save yet." -ForegroundColor Yellow; continue }
        try {
            $dir = Split-Path $path -Parent
            if ($dir -and (-not (Test-Path $dir))) { New-Item -ItemType Directory -Path $dir | Out-Null }
            Set-Content -Path $path -Value $script:LastResponseText -Encoding UTF8
            Write-Host ("Saved to: {0}" -f $path) -ForegroundColor Green
        } catch { Write-Host $_.Exception.Message -ForegroundColor Red }
        continue
    }

    if ($inputLine -eq "/ml") {
        $body = Read-Multiline "Enter multi-line message"
        if (-not $body) { Write-Host "Canceled." -ForegroundColor Yellow; continue }
        $id = Write-InboxMessage $body
        $resp = Wait-ForResponse $id 900
        if (-not $resp) { Write-Host "Timeout waiting for response." -ForegroundColor Red; continue }
        $script:LastResponseText = $resp
        Write-Host ""; Write-Host $resp; Write-Host ""
        continue
    }

    if ($inputLine.StartsWith("/summary ")) {
        $topic = $inputLine.Substring(9).Trim()
        $id = Write-InboxMessage (Build-OneShotPrompt "SUMMARY" $topic)
        $resp = Wait-ForResponse $id 900
        if (-not $resp) { Write-Host "Timeout." -ForegroundColor Red; continue }
        $script:LastResponseText = $resp
        Write-Host ""; Write-Host $resp; Write-Host ""
        continue
    }

    if ($inputLine.StartsWith("/detail ")) {
        $topic = $inputLine.Substring(8).Trim()
        $id = Write-InboxMessage (Build-OneShotPrompt "DETAIL" $topic)
        $resp = Wait-ForResponse $id 900
        if (-not $resp) { Write-Host "Timeout." -ForegroundColor Red; continue }
        $script:LastResponseText = $resp
        Write-Host ""; Write-Host $resp; Write-Host ""
        continue
    }

    if ($inputLine.StartsWith("/report")) {
        $topic = $inputLine.Substring(7).Trim()
        if (-not $topic) {
            $topic = Read-Multiline "Report topic/specification"
            if (-not $topic) { Write-Host "Canceled." -ForegroundColor Yellow; continue }
        }
        $id = Write-InboxMessage (Build-OneShotPrompt "REPORT" $topic)
        $resp = Wait-ForResponse $id 1200
        if (-not $resp) { Write-Host "Timeout." -ForegroundColor Red; continue }
        $script:LastResponseText = $resp
        Write-Host ""; Write-Host $resp; Write-Host ""
        continue
    }

    # pass-through to loop
    if ($inputLine.StartsWith("/status") -or
        $inputLine.StartsWith("/objective") -or
        $inputLine.StartsWith("/context") -or
        $inputLine.StartsWith("/reportmode") -or
        $inputLine.StartsWith("/memclear")) {

        $id = Write-InboxMessage $inputLine
        $resp = Wait-ForResponse $id 600
        if (-not $resp) { Write-Host "Timeout." -ForegroundColor Red; continue }
        $script:LastResponseText = $resp
        Write-Host ""; Write-Host $resp; Write-Host ""
        continue
    }

    # default
    $id = Write-InboxMessage $inputLine
    $resp = Wait-ForResponse $id 900
    if (-not $resp) { Write-Host "Timeout." -ForegroundColor Red; continue }
    $script:LastResponseText = $resp
    Write-Host ""; Write-Host $resp; Write-Host ""
}

Write-Host "=== NEO CHAT EXITED ===" -ForegroundColor DarkGray

