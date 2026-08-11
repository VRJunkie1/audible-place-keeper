# Unit tests for the reset decision. No browser, no player, no waiting.
#   powershell -ExecutionPolicy Bypass -File tests.ps1
#
# Everything is in seconds of REMAINING time. Remaining goes DOWN as you listen.
# Book used below is 23h 33m = 84780s.

$ErrorActionPreference = 'Stop'
$script:pass = 0
$script:fail = 0

# Pull Test-IsReset out of the real script without running the watcher.
$src = Get-Content (Join-Path $PSScriptRoot 'place-keeper.ps1') -Raw
$m = [regex]::Match($src, '(?ms)^function Test-IsReset \{.*?^\}')
if (-not $m.Success) { Write-Output "FAILED to find Test-IsReset in place-keeper.ps1"; exit 1 }
Invoke-Expression $m.Value

function Check {
    param([string]$Name, [bool]$Expected, [double]$Remain, $Best, $Len)
    $got = Test-IsReset -RemainSec $Remain -BestSec $Best -BookLen $Len
    if ($got -eq $Expected) {
        $script:pass++
        Write-Output ("  PASS  " + $Name)
    } else {
        $script:fail++
        Write-Output ("  FAIL  " + $Name + "  (expected $Expected, got $got)")
    }
}

$LEN = 84780       # 23h 33m
$H   = 3600
$M   = 60

Write-Output "=== should NOT be treated as a reset ==="

Check "listening normally (remaining ticking down)" $false (12*$H) (12*$H + 5*$M) $LEN
Check "30-second rewind"                            $false (12*$H + 30) (12*$H) $LEN
Check "re-listening to a 9-minute stretch"          $false (12*$H + 9*$M) (12*$H) $LEN

# The one Mike asked about: hunting for his place by flipping forward, then back.
Check "flip FORWARD 40m (remaining drops)"          $false (11*$H + 20*$M) (12*$H) $LEN
Check "then flip BACK to where he really was"       $false (12*$H) (11*$H + 20*$M) $LEN
Check "overshoot back 2h while hunting"             $false (14*$H) (12*$H) $LEN
Check "hunting near the front of the book"          $false (22*$H) (20*$H) $LEN

# Phone sync: he listened an hour further ahead on his phone, then refreshed
# the PC and it jumped forward to match. Forward is never a reset.
Check "phone sync forward 1h"                       $false (11*$H) (12*$H) $LEN
Check "phone sync forward 6h"                       $false (6*$H)  (12*$H) $LEN
Check "phone sync BACKWARD 20m (phone behind)"      $false (12*$H + 20*$M) (12*$H) $LEN

Check "no history yet (first ever sighting)"        $false (12*$H) $null $LEN
Check "book length not learned yet"                 $false (12*$H) (2*$H) $null

Write-Output ""
Write-Output "=== SHOULD be treated as a reset ==="

Check "dumped to the very start from mid-book"      $true  $LEN (12*$H) $LEN
Check "dumped to the start from near the end"       $true  $LEN (20*$M) $LEN
Check "dumped to start, 90s of intro already played" $true ($LEN - 90) (12*$H) $LEN

Write-Output ""
Write-Output "=== boundary behaviour ==="

# Just inside the 'at the start' slack (120s) - still a reset.
Check "landed 100s past the start"                  $true  ($LEN - 100) (12*$H) $LEN
# Clearly not the start - that is hunting, not a reset.
Check "landed 10 minutes past the start"            $false ($LEN - 10*$M) (12*$H) $LEN
# Jumped up, but only by 9 minutes - under the threshold.
Check "jumped up only 9 minutes"                    $false ($LEN) ($LEN - 9*$M) $LEN

Write-Output ""
Write-Output ("passed: $script:pass   failed: $script:fail")
if ($script:fail -gt 0) { exit 1 }
