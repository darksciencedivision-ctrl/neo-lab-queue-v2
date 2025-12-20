# C:\ai_control\NEO_Stack\neo_loop_hook_retrieve.ps1
# PS 5.1-safe retrieval hook.
# Purpose:
#   - Decide if retrieval is needed for a given user text (auto-retrieval).
#   - If needed, call neo_retrieve.ps1 and return JSON bundle to stdout.
#
# Example:
#   cd C:\ai_control\NEO_Stack
#   .\neo_loop_hook_retrieve.ps1 -UserText "where is queue_v2" -KbRoot "C:\ai_control" -MaxHits 10

param(
  [Parameter(Mandatory=$true)]
  [string]$UserText

  ,[Parameter(Mandatory=$false)]
  [string]$KbRoot = "C:\ai_control"

  ,[Parameter(Mandatory=$false)]
  [int]$MaxHits = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Utf8NoBom {
  param([Parameter(Mandatory=$true)][string]$Text)
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  $bytes = $utf8NoBom.GetBytes($Text)
  $out = [Console]::OpenStandardOutput()
  $out.Write($bytes, 0, $bytes.Length)
}

function Has-RetrievalIntent {
  param([Parameter(Mandatory=$true)][string]$Text)

  $t = $Text.Trim()

  if ($t.Length -eq 0) { return $false }

  # Explicit command
  if ($t -match '^\s*/search\b') { return $true }

  # Heuristic intent triggers
  $patterns = @(
    '\bwhere is\b',
    '\bwhere are\b',
    '\bfind\b',
    '\bsearch\b',
    '\blookup\b',
    '\bshow me\b',
    '\bpoint me\b',
    '\bwhich file\b',
    '\bwhat file\b',
    '\boutbox\b',
    '\binbox\b',
    '\bqueue_v2\b',
    '\bneo_loop\.ps1\b',
    '\bneo_chat(_sync)?\.ps1\b',
    '\bpersona_neo_.*\.txt\b',
    '\.ps1\b',
    '\.json\b',
    '\.md\b'
  )

  foreach ($p in $patterns) {
    if ($t -match $p) { return $true }
  }

  return $false
}

function Normalize-Query {
  param([Parameter(Mandatory=$true)][string]$Text)
  $t = $Text.Trim()
  if ($t -match '^\s*/search\s+(.*)$') {
    return $Matches[1].Trim()
  }
  return $t
}

# Resolve script directory safely (works in script + in console)
$here = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($here)) {
  $here = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if ([string]::IsNullOrWhiteSpace($here)) {
  $here = (Get-Location).Path
}

$retrieveScript = Join-Path $here "neo_retrieve.ps1"

$used = $false
$query = Normalize-Query -Text $UserText
$retrieval = $null
$citations = ""

try {
  if (Has-RetrievalIntent -Text $UserText) {
    $used = $true

    if (!(Test-Path -LiteralPath $retrieveScript)) {
      throw ("neo_retrieve.ps1 not found at: {0}" -f $retrieveScript)
    }
    if (!(Test-Path -LiteralPath $KbRoot)) {
      throw ("KbRoot not found: {0}" -f $KbRoot)
    }

    $raw = & $retrieveScript -Query $query -Root $KbRoot -MaxHits $MaxHits 2>&1
    $retrieval = $raw | ConvertFrom-Json

    # Build short citation string (path:line) for quick injection
    if ($retrieval -and $retrieval.hits) {
      $top = @($retrieval.hits | Select-Object -First 8)
      $lines = New-Object System.Collections.Generic.List[string]
      foreach ($h in $top) {
        $lines.Add(("{0}:{1}" -f $h.path, $h.line)) | Out-Null
      }
      $citations = ($lines -join "; ")
    }
  }

  $bundle = [ordered]@{
    type = "neo_retrieval_bundle"
    ts   = (Get-Date).ToString("o")
    used_retrieval = $used
    kb_root = $KbRoot
    query = $query
    citations = $citations
    retrieval = $retrieval
  }

  Write-Utf8NoBom (($bundle | ConvertTo-Json -Depth 10))
}
catch {
  $err = [ordered]@{
    type = "neo_retrieval_bundle"
    ts   = (Get-Date).ToString("o")
    used_retrieval = $used
    kb_root = $KbRoot
    query = $query
    error = $true
    message = $_.Exception.Message
  }
  Write-Utf8NoBom (($err | ConvertTo-Json -Depth 6))
  exit 1
}

