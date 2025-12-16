function Read-AllTextLocked([string]$Path, [int]$TimeoutMs = 5000) {
    if (-not (Test-Path -LiteralPath $Path)) {
        Abort "Missing file: $Path"
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $utf8 = New-Object System.Text.UTF8Encoding($true) # detect BOM if present
    $lastLen = -1
    $stableCount = 0

    while ($true) {
        try {
            # Check length stability (helps defeat partial writes / truncation races)
            $len = (Get-Item -LiteralPath $Path).Length
            if ($len -eq $lastLen -and $len -gt 0) {
                $stableCount++
            } else {
                $stableCount = 0
                $lastLen = $len
            }

            # Only read once length is stable across 2 consecutive checks
            if ($stableCount -lt 2) {
                if ($sw.ElapsedMilliseconds -ge $TimeoutMs) {
                    Abort "Timeout waiting for stable file size: $Path"
                }
                Start-Sleep -Milliseconds 100
                continue
            }

            # Read bytes in one shot (no StreamReader partial behavior)
            $bytes = [System.IO.File]::ReadAllBytes($Path)

            # Decode as UTF-8 (with BOM detection)
            return $utf8.GetString($bytes)
        }
        catch {
            if ($sw.ElapsedMilliseconds -ge $TimeoutMs) {
                Abort "Timeout waiting for readable file: $Path"
            }
            Start-Sleep -Milliseconds 100
        }
    }
}

