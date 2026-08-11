# Run this once the Audible player tab is the one showing in its window.
#
# It puts the player back to the last place the watcher recorded, then starts
# the watcher. Use it after the player has been left somewhere wrong - it trusts
# the saved record, not whatever the player currently shows.

$ErrorActionPreference = 'Continue'
$here  = Split-Path -Parent $MyInvocation.MyCommand.Path
$state = Join-Path $env:LOCALAPPDATA 'AudiblePlaceKeeper\data\state.json'

if (-not (Test-Path $state)) { Write-Output "no saved state found"; exit 1 }

$s = Get-Content $state -Raw -Encoding UTF8 | ConvertFrom-Json
$book = $null
foreach ($p in $s.books.PSObject.Properties) {
    if ($null -eq $book -or $p.Value.lastSeen -gt $book.lastSeen) { $book = $p.Value }
}
if (-not $book -or -not $book.best) { Write-Output "no saved position"; exit 1 }

Write-Output ("saved place : " + $book.best.remainText + "   (" + $book.best.chapter + ", recorded " + $book.best.at + ")")

# Is the player actually readable right now?
$probe = & powershell -ExecutionPolicy Bypass -File (Join-Path $here 'place-keeper.ps1') -Once 2>&1
$cur = Join-Path $env:LOCALAPPDATA 'AudiblePlaceKeeper\current.txt'
if ((Get-Content $cur -Raw) -match 'CANNOT READ|no Audible window') {
    Write-Output ""
    Write-Output "The player tab is not the one showing. Click back to it (or drag it"
    Write-Output "into its own window), then run this again."
    exit 1
}

Write-Output "restoring..."
& powershell -ExecutionPolicy Bypass -File (Join-Path $here 'place-keeper.ps1') -GoTo $book.best.remainText

Write-Output "starting the watcher..."
& wscript.exe (Join-Path $here 'run-hidden.vbs')
Start-Sleep -Seconds 15
& powershell -ExecutionPolicy Bypass -File (Join-Path $here 'place-keeper.ps1') -Once | Out-Null
Write-Output ""
Get-Content $cur
