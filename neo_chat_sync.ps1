param(
  [string]$ManifestPath = ".\neo_manifest.json",
  [int]$PollMs = 250,
  [int]$TimeoutSec = 180
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Utf8NoBom($Path, $Text) {
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Text, $utf8)
}
function Read-Json($Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
function New-Id { ([Guid]::NewGuid().ToString("N")) }

$manifest = Read-Json (Resolve-Path $ManifestPath)
$INBOX  = $manifest.paths.queue_inbox
$OUTBOX = $manifest.paths.queue_outbox
$ART    = $manifest.paths.artifacts_root

New-Item -ItemType Directory -Force -Path $INBOX,$OUTBOX,$ART | Out-Null

$global:CurrentRoute = "chat"

Write-Host "NEO CHAT SYNC (queue_v2)"
Write-Host "INBOX:  $INBOX"
Write-Host "OUTBOX: $OUTBOX"
Write-Host "Commands: /exit /help  |  /chat /coder /reasoner"
Write-Host ""

function Extract-Text($j) {
  foreach ($k in @("text","reply","content","output","message")) {
    if ($j.PSObject.Properties.Name -contains $k) {
      $v = $j.$k
      if ($null -ne $v -and "$v".Trim().Length -gt 0) { return "$v" }
    }
  }
  return $null
}

function Find-ReplyForRequest([string]$RequestId) {
  $files = Get-ChildItem -LiteralPath $OUTBOX -File -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime  # oldest->newest

  foreach ($f in $files) {
    try {
      $j = Read-Json $f.FullName

      # Preferred correlation keys you already have in your outbox:
      foreach ($k in @("in_reply_to","request_id","req_id","parent_id")) {
        if ($j.PSObject.Properties.Name -contains $k) {
          if ("$($j.$k)" -eq $RequestId) { return $j }
        }
      }

      # Fallback: sometimes the reply id embeds the msg id
      if ($j.PSObject.Properties.Name -contains "id") {
        if ("$($j.id)" -match [Regex]::Escape($RequestId)) { return $j }
      }
    } catch {
      # If JSON parse fails, ignore
    }
  }

  return $null
}

function Get-NewestReply {
  $f = Get-ChildItem -LiteralPath $OUTBOX -File -ErrorAction SilentlyContinue |
       Sort-Object LastWriteTime -Desc | Select-Object -First 1
  if (-not $f) { return $null }
  try { return (Read-Json $f.FullName) } catch { return $null }
}

function Set-Route([string]$r) {
  $r = $r.ToLowerInvariant()
  $valid = $manifest.routes.PSObject.Properties.Name
  if ($valid -notcontains $r) { throw "Unknown route '$r'. Valid: $($valid -join ', ')" }
  $global:CurrentRoute = $r
  Write-Host "ROUTE SET: $global:CurrentRoute"
}

while ($true) {
  $user = Read-Host "YOU"
  if ($null -eq $user) { continue }

  $trim = ($user -replace "^\s+|\s+$","")
  if ($trim.Length -eq 0) { continue }

  if ($trim -match '^\s*YOU:\s*') {
    Write-Host "NEO: (input error) Do not type 'YOU:'. Type only the message."
    continue
  }

  if ($trim -match '\/(chat|coder|reasoner)\s+\S') {
    Write-Host "NEO: (input error) Route switches must be on their own line: /chat or /coder or /reasoner"
    continue
  }

  switch ($trim.ToLowerInvariant()) {
    "/exit" { break }
    "/help" {
      Write-Host "Use /chat /coder /reasoner on their own line."
      Write-Host "Then type ONE prompt per message."
      Write-Host "Current route: $global:CurrentRoute"
      continue
    }
    "/chat"     { Set-Route "chat"; continue }
    "/coder"    { Set-Route "coder"; continue }
    "/reasoner" { Set-Route "reasoner"; continue }
  }

  $id = New-Id
  $payload = [ordered]@{
    id        = $id
    msg_id    = $id
    ts_utc    = [DateTime]::UtcNow.ToString("o")
    role      = "user"
    route     = $global:CurrentRoute
    user_text = $trim
    text      = $trim
    prompt    = $trim
    stack_id  = $manifest.stack_id
  }

  $json = $payload | ConvertTo-Json -Depth 10
  Write-Utf8NoBom (Join-Path $ART "last_inbox_written.json") $json

  $tmp = Join-Path $INBOX "msg_$id.json.tmp"
  $dst = Join-Path $INBOX "msg_$id.json"
  Write-Utf8NoBom $tmp $json
  Move-Item -LiteralPath $tmp -Destination $dst -Force

  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  $reply = $null

  while ((Get-Date) -lt $deadline) {
    $reply = Find-ReplyForRequest $id
    if ($reply) { break }
    Start-Sleep -Milliseconds $PollMs
  }

  if (-not $reply) {
    Write-Host "NEO:"
    Write-Host "WARNING: (no reply found yet - timeout after $TimeoutSec s)"
    $newest = Get-NewestReply
    if ($newest) {
      $t = Extract-Text $newest
      if ($t) { Write-Host "(newest outbox) $t" }
      else { Write-Host "(newest outbox raw)"; ($newest | ConvertTo-Json -Depth 10) }
    } else {
      Write-Host "(outbox is empty/unreadable)"
    }
    continue
  }

  $txt = Extract-Text $reply
  if ($txt) { Write-Host "NEO: $txt"; continue }

  Write-Host "NEO: (raw)"
  ($reply | ConvertTo-Json -Depth 10)
}

