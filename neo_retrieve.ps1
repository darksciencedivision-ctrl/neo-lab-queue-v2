# C:\ai_control\NEO_Stack\neo_retrieve.ps1
# Fast local retrieval for NEO.
# Uses ripgrep (rg) if available; falls back to Select-String.
#
# Example:
#   .\neo_retrieve.ps1 -Query "NEO-LAB" -Root "C:\ai_control" -MaxHits 10

param(
  [Parameter(Mandatory = $true)]
  [string]$Query,

  [Parameter(Mandatory = $false)]
  [string]$Root = 'C:\ai_control',

  [Parameter(Mandatory = $false)]
  [int]$MaxHits = 25,

  [Parameter(Mandatory = $false)]
  [string[]]$Include = @('*.md','*.txt','*.ps1','*.py','*.json','*.yml','*.yaml'),

  [Parameter(Mandatory = $false)]
  [string[]]$ExcludeDir = @('.git','node_modules','venv','__pycache__','dist','build')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Root)) { throw "Root not found: $Root" }
if ([string]::IsNullOrWhiteSpace($Query)) { throw "Query cannot be empty." }

function Has-Rg {
  return [bool](Get-Command rg -ErrorAction SilentlyContinue)
}

function Write-Utf8NoBom {
  param([Parameter(Mandatory = $true)][string]$Text)
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  $bytes = $utf8NoBom.GetBytes($Text)
  $out = [Console]::OpenStandardOutput()
  $out.Write($bytes, 0, $bytes.Length)
}

$ts = (Get-Date).ToString('o')
$hits = New-Object System.Collections.Generic.List[object]

if (Has-Rg) {
  # Do NOT use $args (reserved automatic variable)
  $rgArgs = @('--no-heading','--line-number','--hidden','--follow','--max-count',"$MaxHits")

  foreach ($d in $ExcludeDir) { $rgArgs += @('--glob', "!**/$d/**") }
  foreach ($g in $Include)    { $rgArgs += @('--glob', $g) }

  $rgArgs += @($Query, $Root)

  $lines = & rg @rgArgs 2>$null
  foreach ($ln in $lines) {
    if ($ln -match '^(.*?):(\d+):(.*)$') {
      $path = $Matches[1]
      $line = [int]$Matches[2]
      $text = ($Matches[3]).Trim()
      $hits.Add([ordered]@{ path = $path; line = $line; text = $text }) | Out-Null
    }
  }
}
else {
  $files = Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object {
      $ok = $false
      foreach ($g in $Include) { if ($_.Name -like $g) { $ok = $true; break } }
      if (-not $ok) { return $false }
      foreach ($d in $ExcludeDir) { if ($_.FullName -match "\\$d\\") { return $false } }
      return $true
    }

  foreach ($f in $files) {
    if ($hits.Count -ge $MaxHits) { break }
    $matches = Select-String -LiteralPath $f.FullName -Pattern $Query -SimpleMatch -AllMatches -ErrorAction SilentlyContinue
    foreach ($m in $matches) {
      if ($hits.Count -ge $MaxHits) { break }
      $hits.Add([ordered]@{ path = $f.FullName; line = $m.LineNumber; text = ($m.Line.Trim()) }) | Out-Null
    }
  }
}

$out = [ordered]@{
  type   = 'retrieval_result'
  ts     = $ts
  query  = $Query
  root   = $Root
  engine = $(if (Has-Rg) { 'rg' } else { 'select-string' })
  hits   = $hits
}

$json = $out | ConvertTo-Json -Depth 10
Write-Utf8NoBom $json

