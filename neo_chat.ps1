# C:\ai_control\NEO_Stack\neo_chat.ps1
# NEO-LAB chat wrapper (PS5-safe)
# Purpose: call local LLM and return a single JSON reply to stdout.
#
# Contract (used by neo_loop.ps1):
#   -UserText <string> -PersonaPath <string> -Model <string> -ContextJson <string>
#
# Compatibility:
#   -Message <string> is accepted as an alias for -UserText

param(
  [Parameter(Mandatory=$false)]
  [Alias("Message")]
  [string]$UserText,

  [Parameter(Mandatory=$false)]
  [string]$PersonaPath,

  [Parameter(Mandatory=$false)]
  [string]$Model,

  [Parameter(Mandatory=$false)]
  [string]$ContextJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function NEO-NowUtcIso { (Get-Date).ToUniversalTime().ToString("o") }

function NEO-ToJson {
  param([Parameter(Mandatory=$true)]$Obj, [int]$RecursionLimit = 200)
  Add-Type -AssemblyName System.Web.Extensions | Out-Null
  $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
  $ser.RecursionLimit = $RecursionLimit
  return $ser.Serialize($Obj)
}

function NEO-ReadText {
  param([Parameter(Mandatory=$true)][string]$Path)
  return (Get-Content -LiteralPath $Path -Raw)
}

# Resolve defaults
$HERE = $PSScriptRoot
if (-not $HERE) { $HERE = Split-Path -Parent $MyInvocation.MyCommand.Path }

if ([string]::IsNullOrWhiteSpace($UserText)) {
  throw "neo_chat.ps1: UserText/Message is required."
}

if ([string]::IsNullOrWhiteSpace($PersonaPath)) {
  $PersonaPath = Join-Path $HERE "persona_neo_labpartner.txt"
}

if ([string]::IsNullOrWhiteSpace($Model)) {
  $Model = "dolphin-llama3"
}

if ($null -eq $ContextJson -or [string]::IsNullOrWhiteSpace($ContextJson)) {
  $ContextJson = "{}"
}

# Read persona (optional but recommended)
$persona = ""
if (Test-Path -LiteralPath $PersonaPath) {
  $persona = NEO-ReadText -Path $PersonaPath
} else {
  # Not fatal; but better to surface in output if missing
  $persona = "[WARN] Persona file not found: $PersonaPath"
}

# Deterministic prompt assembly
# (Keep it simple + inspectable: persona, then raw context JSON, then user)
$prompt = @"
$persona

[NEO_CONTEXT_JSON]
$ContextJson

[USER]
$UserText

[ASSISTANT]
"@

# --- Primary: Ollama HTTP (recommended for non-interactive deterministic call)
function Invoke-OllamaGenerate {
  param([Parameter(Mandatory=$true)][string]$ModelName, [Parameter(Mandatory=$true)][string]$Prompt)

  $uri = "http://localhost:11434/api/generate"
  $body = @{
    model  = $ModelName
    prompt = $Prompt
    stream = $false
  }

  try {
    $resp = Invoke-RestMethod -Method Post -Uri $uri -ContentType "application/json" -Body (NEO-ToJson $body)
    if ($null -eq $resp) { throw "Empty response from Ollama." }

    # Typical fields: response, done, context, total_duration, etc.
    if ($resp.PSObject.Properties.Match("response").Count -gt 0) {
      return [string]$resp.response
    }

    # Some versions may return "message":{content:""}
    if ($resp.PSObject.Properties.Match("message").Count -gt 0) {
      if ($resp.message -and ($resp.message.PSObject.Properties.Match("content").Count -gt 0)) {
        return [string]$resp.message.content
      }
    }

    throw "Unexpected Ollama response shape."
  } catch {
    throw ("Ollama generate failed: " + $_.Exception.Message)
  }
}

# --- Fallback: LM Studio OpenAI-compatible endpoint (common default)
function Invoke-LMStudioChatCompletions {
  param([Parameter(Mandatory=$true)][string]$ModelName, [Parameter(Mandatory=$true)][string]$SystemPrompt, [Parameter(Mandatory=$true)][string]$UserPrompt)

  $uri = "http://localhost:1234/v1/chat/completions"
  $body = @{
    model = $ModelName
    temperature = 0
    stream = $false
    messages = @(
      @{ role="system"; content=$SystemPrompt },
      @{ role="user"; content=$UserPrompt }
    )
  }

  try {
    $resp = Invoke-RestMethod -Method Post -Uri $uri -ContentType "application/json" -Body (NEO-ToJson $body)
    if ($null -eq $resp) { throw "Empty response from LM Studio." }

    # OpenAI format: choices[0].message.content
    if ($resp.PSObject.Properties.Match("choices").Count -gt 0 -and $resp.choices.Count -gt 0) {
      $c0 = $resp.choices[0]
      if ($c0 -and ($c0.PSObject.Properties.Match("message").Count -gt 0)) {
        $m = $c0.message
        if ($m -and ($m.PSObject.Properties.Match("content").Count -gt 0)) {
          return [string]$m.content
        }
      }
      if ($c0 -and ($c0.PSObject.Properties.Match("text").Count -gt 0)) {
        return [string]$c0.text
      }
    }

    throw "Unexpected LM Studio response shape."
  } catch {
    throw ("LM Studio chat failed: " + $_.Exception.Message)
  }
}

# Try Ollama first, then LM Studio
$responseText = $null
try {
  $responseText = Invoke-OllamaGenerate -ModelName $Model -Prompt $prompt
} catch {
  # LM Studio fallback uses split system/user instead of monolithic prompt
  $systemPrompt = $persona + "`n`n[NEO_CONTEXT_JSON]`n" + $ContextJson
  $responseText = Invoke-LMStudioChatCompletions -ModelName $Model -SystemPrompt $systemPrompt -UserPrompt $UserText
}

# Emit strict JSON object to stdout
$out = @{
  ts = (NEO-NowUtcIso)
  model = $Model
  text = $responseText
}

# IMPORTANT: write ONLY JSON to stdout (no Write-Host)
[Console]::Out.WriteLine((NEO-ToJson $out))

