# =============================================================================
#  Audible Place Keeper
# =============================================================================
#  The Audible web player tab reloads itself every few days. On reload it comes
#  up at the start of the book and reports position ~0 back to Audible, which
#  destroys your saved place. This watches the player, remembers where you were,
#  and puts you back.
#
#  The CODE lives in Dropbox so it survives the SSD dying:
#     Dropbox\PC\AudiblePlaceKeeper\
#         place-keeper.ps1  this script
#         run-hidden.vbs    launcher (no console window), used by the Startup entry
#         NOTES.md          diagnosis, gotchas and design decisions - read it
#
#  The DATA stays on the local disk, because a file rewritten every few minutes
#  would make Dropbox sync churn nonstop:
#     %LOCALAPPDATA%\AudiblePlaceKeeper\
#         current.txt       where you are right now, in plain English
#         data\state.json   all books, keyed by ASIN, with a rolling history
#         data\resets.txt   append-only log of every reset and every restore
#         data\titles.json  ASIN -> book title, for readability (edit freely)
#
#  Each of those two folders contains a shortcut to the other.
#
#  ---------------------------------------------------------------------------
#  Why everything is measured in REMAINING TIME
#  ---------------------------------------------------------------------------
#  The player's chapter label and its seek-bar length are STALE. After you jump
#  to a new chapter they keep showing the old chapter's name and length until
#  playback refreshes them. Measured on 2026-08-04: jumping to Chapter 5 still
#  read "Chapter 1", but the book's remaining time moved by exactly the length
#  of chapters 1-4. So the remaining time tells the truth and the labels do not.
#
#  Everything here therefore keys on "Xh Ym left". The chapter name is recorded
#  only so the files are readable by a human.
#
#  ---------------------------------------------------------------------------
#  How it decides something went wrong
#  ---------------------------------------------------------------------------
#  You cannot un-listen to an hour. If remaining time ever jumps UP, the player
#  threw your place away. That is the only trigger.
#
#  Movement FORWARD is never treated as a reset - that is your phone's position
#  syncing over, and it is correct. Only backward jumps count.
#
#  Small backward moves (a 30-second rewind, re-listening to a chapter) are
#  recorded as normal listening. The threshold is 10 minutes, which no rewind
#  button can produce.
#
#  Usage
#  -----
#    powershell -ExecutionPolicy Bypass -File place-keeper.ps1
#    powershell -ExecutionPolicy Bypass -File place-keeper.ps1 -Once
#    powershell -ExecutionPolicy Bypass -File place-keeper.ps1 -SelfTest
#    powershell -ExecutionPolicy Bypass -File place-keeper.ps1 -NoRestore
#    powershell -ExecutionPolicy Bypass -File place-keeper.ps1 -GoTo "22h 10m"
# =============================================================================

param(
    # A full sample walks the whole accessibility tree, so it runs rarely.
    # Resets only happen during idle hours, so 5 minutes is plenty.
    [int]$HeavyIntervalSeconds = 300,

    # But a reset has to be caught in SECONDS, not minutes, or it blares in the
    # next room. The watchdog holds direct references to the seek bar and the
    # remaining-time label and just re-reads those two. Measured at 0.14 ms per
    # read, so once a second costs nothing. It does NOT walk the tree.
    [int]$WatchdogSeconds = 1,

    # Pause instantly on a reset only if you have not touched the machine for
    # this long. If you are sitting at the PC you do not need it silenced out
    # from under you; if you are asleep, you very much do.
    [int]$IdleBeforeInstantPause = 120,

    # Data stays on the local disk. The script itself lives in Dropbox, but a
    # file rewritten every few minutes would make Dropbox churn forever.
    [string]$DataRoot = (Join-Path $env:LOCALAPPDATA 'AudiblePlaceKeeper'),

    [switch]$Once,          # take one sample and exit
    [switch]$SelfTest,      # prove the record -> reset -> restore path
    [switch]$NoRestore,     # record only; never touch the player
    [string]$GoTo           # manually send the player to "Xh Ym" remaining
)

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$ErrorActionPreference = 'Continue'

# Hard ceiling on clicks, enforced in Invoke-Element. Raised for a restore,
# reset every pass. Nothing may click without spending from this.
$script:ClickBudget = 6
$script:PauseBudget = 6
$script:ManualRun   = $false

# Clicking a player control pulls the browser window to the front. Doing that
# repeatedly makes the machine unusable - on 2026-08-09 it yanked focus back to
# Firefox every time Mike clicked another window. Two defences: put the
# foreground window back after every click, and (the real fix, further down)
# never run a restore while he is actually using the PC.
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Fg {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
}
"@ -ErrorAction SilentlyContinue

# Idle time lives up here, NOT further down with the loop. It used to be defined
# only in the watcher section, so -GoTo ran without it - and since the click
# logger calls it, every log write threw and was swallowed. The log came back
# empty and I read that as "it made no clicks", which was wrong. A logger that
# fails silently is worse than no logger.
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Idle {
    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO p);
    [DllImport("kernel32.dll")] public static extern uint GetTickCount();
    public static uint Seconds() {
        LASTINPUTINFO i = new LASTINPUTINFO();
        i.cbSize = (uint)Marshal.SizeOf(i);
        if (!GetLastInputInfo(ref i)) return 0;
        return (GetTickCount() - i.dwTime) / 1000;
    }
}
"@ -ErrorAction SilentlyContinue

# ------------------------------------------------------------------ config --
$HISTORY_CAP         = 150    # samples kept per book (rolling)
$BOOK_PRUNE_DAYS     = 120    # forget books untouched this long
$RESET_JUMP_SEC      = 600    # remaining-time jump upward that means "reset"
$MAX_RESTORES_PER_HR = 3      # stop fighting a player that resets in a loop
$RESTORE_TOL_SEC     = 60     # close enough, in seconds
$MAX_SECTION_CLICKS  = 40     # safety cap when stepping through chapters
$ACTIVE_IDLE_SEC     = 180    # if you touched the keyboard/mouse more recently
                              # than this, DO NOT drive the player - clicking it
                              # steals focus and makes the machine unusable.
                              # Wait until you have stepped away.
$RESTORE_BACKOFF_SEC = 5      # land 5s EARLIER than recorded, so a lost second
                              # or two never costs you context

# ------------------------------------------------------------------- paths --
$dataDir = Join-Path $DataRoot 'data'
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }
$stateFile  = Join-Path $dataDir 'state.json'
$resetFile  = Join-Path $dataDir 'resets.txt'
$titleFile  = Join-Path $dataDir 'titles.json'
$currentTxt = Join-Path $DataRoot 'current.txt'

$AE = [System.Windows.Automation.AutomationElement]
$CT = [System.Windows.Automation.ControlType]
$TS = [System.Windows.Automation.TreeScope]

# ------------------------------------------------------------------ helpers -

function ConvertTo-Hash {
    param($Obj)
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $Obj.PSObject.Properties) { $h[$p.Name] = ConvertTo-Hash $p.Value }
        return $h
    }
    if ($Obj -is [System.Object[]]) {
        $a = @()
        foreach ($i in $Obj) { $a += ,(ConvertTo-Hash $i) }
        return ,$a
    }
    return $Obj
}

function Load-State {
    if (-not (Test-Path $stateFile)) { return @{ books = @{} } }
    try {
        $raw = Get-Content $stateFile -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return @{ books = @{} } }
        $s = ConvertTo-Hash (ConvertFrom-Json $raw)
        if (-not $s.books) { $s.books = @{} }
        return $s
    } catch {
        Copy-Item $stateFile "$stateFile.corrupt" -Force -ErrorAction SilentlyContinue
        return @{ books = @{} }
    }
}

function Save-State {
    param($State)
    try {
        $tmp = "$stateFile.tmp"
        ($State | ConvertTo-Json -Depth 8) | Set-Content -Path $tmp -Encoding UTF8
        Move-Item -Path $tmp -Destination $stateFile -Force
    } catch { }
}

function Load-Titles {
    if (-not (Test-Path $titleFile)) { return @{} }
    try { return ConvertTo-Hash (ConvertFrom-Json (Get-Content $titleFile -Raw -Encoding UTF8)) }
    catch { return @{} }
}

function ConvertFrom-RemainingText {
    param([string]$Text)
    if (-not $Text) { return $null }
    $h = 0; $m = 0; $got = $false
    if ($Text -match '(\d+)\s*h') { $h = [int]$Matches[1]; $got = $true }
    if ($Text -match '(\d+)\s*m') { $m = [int]$Matches[1]; $got = $true }
    if (-not $got) { return $null }
    return ($h * 3600) + ($m * 60)
}

function Format-Hms {
    param([double]$Seconds)
    $ts = [TimeSpan]::FromSeconds([Math]::Max(0, $Seconds))
    if ($ts.Hours -gt 0) { return ('{0}:{1:00}:{2:00}' -f $ts.Hours, $ts.Minutes, $ts.Seconds) }
    return ('{0}:{1:00}' -f $ts.Minutes, $ts.Seconds)
}

function Format-Remain {
    param([double]$Seconds)
    # [int] ROUNDS in PowerShell - [int]23.55 is 24 - so floor the hours
    # explicitly or 23h33m renders as "24h 33m".
    $ts = [TimeSpan]::FromSeconds([Math]::Max(0, $Seconds))
    return ('{0}h {1}m' -f [Math]::Floor($ts.TotalHours), $ts.Minutes)
}

function Now-Str { return (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') }

function Write-ResetLog {
    param([string]$Text)
    try { Add-Content -Path $resetFile -Value $Text -Encoding UTF8 } catch { }
}

# --------------------------------------------------------------- UIA access -

function Get-BrowserWindows {
    # MATCH ON THE TITLE, NOT ON "is a browser".
    #
    # This used to return every browser window, and the caller then searched
    # each one's whole accessibility tree for the seek bar. With ten browser
    # windows open - X, Google Docs, Patreon - that meant crawling enormous
    # page trees across process boundaries, and the watcher simply stopped
    # keeping up: alive, burning almost no CPU, blocked in UIA, and silently
    # never completing a pass. Observed 2026-08-08, five minutes with no update.
    #
    # The player window is always titled "Audible Cloud Player", in every
    # browser, and the whole design already requires it to be the active tab of
    # its own window. So find it by name and touch nothing else.
    $out = @()
    try {
        $root   = $AE::RootElement
        $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
        $child  = $walker.GetFirstChild($root)
        while ($child) {
            try {
                $nm = $child.Current.Name
                if ($nm -and $nm -match '^Audible Cloud Player') { $out += $child }
            } catch { }
            $child = $walker.GetNextSibling($child)
        }
    } catch { }
    return $out
}

function Read-Window {
    # One pass over a window's tree. Returns $null if this is not an Audible
    # player window, or if the Chapters panel is open (the readout is not in its
    # normal shape then, and the user is probably mid-click).
    param($Win)

    $all = $null
    try { $all = $Win.FindAll($TS::Descendants, [System.Windows.Automation.Condition]::TrueCondition) }
    catch { return $null }
    if (-not $all -or $all.Count -eq 0) { return $null }

    $slider = $null; $texts = @(); $url = $null
    $panelOpen = $false; $isPlaying = $false

    foreach ($e in $all) {
        try { $ct = $e.Current.ControlType; $nm = $e.Current.Name } catch { continue }
        if ([string]::IsNullOrWhiteSpace($nm)) { continue }

        if ($ct -eq $CT::Slider -and $nm -eq 'Seek position') { $slider = $e; continue }
        if ($ct -eq $CT::List   -and $nm -eq 'Chapters')      { $panelOpen = $true; continue }
        if ($ct -eq $CT::Button -and $nm -eq 'Pause')         { $isPlaying = $true; continue }
        if ($ct -eq $CT::Text) { $texts += $nm.Trim() }
        if ($nm -match 'webplayer\?asin=') { $url = $nm }
        if (-not $url -and $ct -eq $CT::ComboBox) {
            try {
                $vp = $e.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
                if ($vp -and $vp.Current.Value -match 'webplayer\?asin=') { $url = $vp.Current.Value }
            } catch { }
        }
    }

    if (-not $slider -or $panelOpen) { return $null }

    $asin = $null
    if ($url -and $url -match 'asin=([A-Za-z0-9]+)') { $asin = $Matches[1] }
    if (-not $asin) { return $null }

    try {
        $rp  = $slider.GetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern)
        $pos = [double]$rp.Current.Value
        $len = [double]$rp.Current.Maximum
    } catch { return $null }

    $remainText = $texts | Where-Object { $_ -match 'left\s*$' } | Select-Object -First 1
    $remainSec  = ConvertFrom-RemainingText $remainText
    if ($null -eq $remainSec) { return $null }   # without this we know nothing

    $chapter = $texts | Where-Object {
                   $_ -notmatch 'left\s*$' -and
                   $_ -notmatch '^-?\d+:\d{2}' -and
                   $_ -notmatch 'audible\.com' -and
                   $_ -notmatch '^www\.' -and
                   $_ -ne 'Chapters'
               } | Select-Object -First 1
    if (-not $chapter) { $chapter = '(unknown)' }

    return [pscustomobject]@{
        Asin       = $asin
        Chapter    = $chapter      # display only - can be stale, see header
        Pos        = $pos
        Len        = $len
        RemainText = $(if ($remainText) { $remainText } else { '' })
        RemainSec  = $remainSec
        IsPlaying  = $isPlaying
        Window     = $Win
    }
}

function Get-PlayerSamples {
    $out = @()
    foreach ($w in (Get-BrowserWindows)) {
        $s = Read-Window $w
        if ($s) { $out += $s }
    }
    return $out
}

function Invoke-Element {
    # EVERY click on the player goes through here. Three jobs: enforce a hard
    # click budget, hand the foreground window straight back, and write down
    # that a click happened.
    #
    # THE BUDGET IS THE IMPORTANT ONE. Each click drags the browser to the
    # front, so a loop that clicks 200 times is a machine-wide input thief for a
    # minute. That happened on 2026-08-10. A logic bug must not be able to cause
    # it again, so the ceiling is enforced here, at the one place every click
    # must pass through, rather than trusted to the callers getting it right.
    param($Element, [switch]$Reserved)

    if ($Reserved) {
        # Pause clicks spend from a separate, FINITE pool. They used to top the
        # main budget back up, which turned the chapter-stepping loop into a
        # self-refuelling pump: spend a click, pause tops it up, forever. Worst
        # case was ~600 clicks. A reserve must be a reserve, not a refill.
        if ($script:PauseBudget -le 0) { return $false }
        $script:PauseBudget--
    }
    elseif ($script:ClickBudget -le 0) {
        try {
            Add-Content -Path (Join-Path $dataDir 'clicks.log') -Encoding UTF8 `
                -Value ('{0}  CLICK BUDGET EXHAUSTED - refusing further clicks' -f (Now-Str))
        } catch { }
        return $false
    }
    $script:ClickBudget--
    try {
        $nm = ''
        try { $nm = $Element.Current.Name } catch { }
        Add-Content -Path (Join-Path $dataDir 'clicks.log') -Encoding UTF8 `
            -Value ('{0}  idle={1,-6} click [{2}]' -f (Now-Str), ([Idle]::Seconds()), $nm)
    } catch { }

    $before = [IntPtr]::Zero
    try { $before = [Fg]::GetForegroundWindow() } catch { }
    try { $Element.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() }
    catch { return $false }
    try {
        if ($before -ne [IntPtr]::Zero) {
            Start-Sleep -Milliseconds 40
            if ([Fg]::GetForegroundWindow() -ne $before) { [Fg]::SetForegroundWindow($before) | Out-Null }
        }
    } catch { }
    return $true
}

function Invoke-Btn {
    param($Win, [string]$Name)
    $c1 = New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, $Name)
    $c2 = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Button)
    $b = $Win.FindFirst($TS::Descendants, (New-Object System.Windows.Automation.AndCondition($c1, $c2)))
    if (-not $b) { return $false }
    return (Invoke-Element $b)
}

function Silence-Player {
    # Clicking a chapter, stepping a section or skipping all RESUME PLAYBACK,
    # even from a paused player. Pausing once at the start of a restore is
    # therefore useless - the first navigation undoes it, and everything after
    # runs out loud. On 2026-08-08 that meant reading out the opening of 32
    # chapters into a dark bedroom.
    #
    # So: after EVERY action that can move the player, shut it up again. The
    # 'Pause' button only exists while audio is actually playing, so this is a
    # cheap no-op the rest of the time.
    param($Win)
    try {
        $c1 = New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, 'Pause')
        $c2 = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Button)
        $b = $Win.FindFirst($TS::Descendants, (New-Object System.Windows.Automation.AndCondition($c1, $c2)))
        # No Pause button means it is genuinely silent. That is the ONLY thing
        # that counts as proof - do not infer silence from a click failing.
        if (-not $b) { return $false }

        # Pause spends from the reserve, never from the main budget.
        return (Invoke-Element $b -Reserved)
    } catch { }
    return $false
}

function Test-IsPlaying {
    # Read-only. Never clicks.
    param($Win)
    try {
        $c1 = New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, 'Pause')
        $c2 = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Button)
        return [bool]$Win.FindFirst($TS::Descendants, (New-Object System.Windows.Automation.AndCondition($c1, $c2)))
    } catch { return $false }
}

function Invoke-Pattern {
    # Expand / Collapse / SetValue are not Invokes, so they used to bypass the
    # budget, the click log AND the foreground restore entirely - even though
    # expanding the Chapters panel both steals focus and resumes playback.
    # Everything that touches the player now goes through a budgeted path.
    param($Element, [string]$What, [scriptblock]$Action)

    if ($script:ClickBudget -le 0) {
        try { Add-Content -Path (Join-Path $dataDir 'clicks.log') -Encoding UTF8 `
                -Value ('{0}  BUDGET EXHAUSTED - refused [{1}]' -f (Now-Str), $What) } catch { }
        return $false
    }
    $script:ClickBudget--

    $idle = 'n/a'
    try { $idle = [Idle]::Seconds() } catch { }
    try {
        Add-Content -Path (Join-Path $dataDir 'clicks.log') -Encoding UTF8 `
            -Value ('{0}  idle={1,-6} pattern [{2}]' -f (Now-Str), $idle, $What)
    } catch { }

    $before = [IntPtr]::Zero
    try { $before = [Fg]::GetForegroundWindow() } catch { }
    try { & $Action } catch { return $false }
    try {
        if ($before -ne [IntPtr]::Zero) {
            Start-Sleep -Milliseconds 40
            if ([Fg]::GetForegroundWindow() -ne $before) { [Fg]::SetForegroundWindow($before) | Out-Null }
        }
    } catch { }
    return $true
}

function Get-Live {
    # Current (remaining, sliderPos, sliderMax) for a window, or $null.
    param($Win)
    $remain = $null; $pos = $null; $max = $null
    try {
        $all = $Win.FindAll($TS::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
        foreach ($e in $all) {
            try { $ct = $e.Current.ControlType; $nm = $e.Current.Name } catch { continue }
            if ([string]::IsNullOrWhiteSpace($nm)) { continue }
            if ($ct -eq $CT::Slider -and $nm -eq 'Seek position') {
                $rp  = $e.GetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern)
                $pos = [double]$rp.Current.Value
                $max = [double]$rp.Current.Maximum
                continue
            }
            if ($ct -eq $CT::Text -and $nm -match 'left\s*$') {
                $remain = ConvertFrom-RemainingText $nm.Trim()
            }
        }
    } catch { return $null }
    if ($null -eq $remain -or $null -eq $pos) { return $null }
    return [pscustomobject]@{ Remain = $remain; Pos = $pos; Max = $max }
}

# -------------------------------------------------------------- the restore -

function ConvertFrom-DurationText {
    # "36:26" -> 2186 ;  "1:02:15" -> 3735
    param([string]$Text)
    $p = $Text.Split(':')
    if ($p.Count -eq 2) { return ([int]$p[0] * 60) + [int]$p[1] }
    if ($p.Count -eq 3) { return ([int]$p[0] * 3600) + ([int]$p[1] * 60) + [int]$p[2] }
    return $null
}

function Close-ChapterPanel {
    param($Win)
    $d1 = New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, 'Dismiss')
    $d2 = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Button)
    $d = $Win.FindFirst($TS::Descendants, (New-Object System.Windows.Automation.AndCondition($d1, $d2)))
    if ($d) {
        Invoke-Element $d | Out-Null
        Start-Sleep -Milliseconds 1000
        return
    }
    # No Dismiss button. Try collapsing the toggle instead - without a fallback
    # the panel can get stuck open, which blinds the whole tool.
    $t1 = New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, 'Chapters')
    $t2 = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Button)
    $t = $Win.FindFirst($TS::Descendants, (New-Object System.Windows.Automation.AndCondition($t1, $t2)))
    if ($t) {
        Invoke-Pattern $t 'collapse-chapters' { $t.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Collapse() } | Out-Null
        Start-Sleep -Milliseconds 1000
    }
}

function Invoke-ChapterJump {
    # Jump most of the way in ONE click, using the Chapters panel.
    #
    # Stepping chapter by chapter costs ~1.5s each, which is 30-60s on this book
    # and would be minutes on a book with many chapters. The panel lists every
    # chapter with its duration, so the right one can be computed and clicked
    # directly.
    #
    # Returns the chosen chapter's duration in seconds, or $null if it could not
    # be done - in which case the caller falls back to stepping.
    param($Win, [double]$TargetRemain)

    # THE PANEL MAY ALREADY BE OPEN, left behind by an attempt that failed
    # before it could close it. In that state there is no 'Chapters' toggle to
    # press any more - and the old code gave up right here, leaving the panel
    # up forever. An open panel hides the seek bar, so the player then reads as
    # "not visible" on every future pass and the tool goes permanently blind.
    # That is exactly what happened on 2026-08-10.
    $listCond = New-Object System.Windows.Automation.AndCondition(
        (New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, 'Chapters')),
        (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::List)))
    $alreadyOpen = [bool]$Win.FindFirst($TS::Descendants, $listCond)

    if (-not $alreadyOpen) {
        $c1 = New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, 'Chapters')
        $c2 = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Button)
        $btn = $Win.FindFirst($TS::Descendants, (New-Object System.Windows.Automation.AndCondition($c1, $c2)))
        if (-not $btn) { return $null }
        if (-not (Invoke-Pattern $btn 'expand-chapters' { $btn.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand() })) { return $null }
        Start-Sleep -Milliseconds 2200
    }

    # Read the chapter list. Only chapter entries carry a trailing duration, and
    # only the Button form actually navigates - the ListItem wrapper is inert.
    # DE-DUPLICATE. The panel exposes each chapter more than once, so a naive
    # scan of this 42-chapter book returned 80 entries. Summing those doubled
    # the apparent book length, which threw the "how far in is the target"
    # arithmetic completely off and sent the jump to the wrong chapter.
    $chapters = @()
    $seen = @{}
    try {
        foreach ($e in $Win.FindAll($TS::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) {
            try { $ct = $e.Current.ControlType; $nm = $e.Current.Name } catch { continue }
            if ([string]::IsNullOrWhiteSpace($nm) -or $ct -ne $CT::Button) { continue }
            if ($nm -notmatch '\s(\d{1,3}:\d{2}(?::\d{2})?)\s*$') { continue }
            $dur = ConvertFrom-DurationText $Matches[1]
            if ($null -eq $dur -or $dur -le 0) { continue }
            if ($seen.ContainsKey($nm)) { continue }
            $seen[$nm] = $true
            $chapters += ,@{ El = $e; Dur = $dur; Label = $nm }
        }
    } catch {
        # This catch used to be empty. It was hiding a call to a function that
        # no longer existed, so the chapter scan threw EVERY time, the one-click
        # jump never ran, and every restore fell back to clicking its way
        # through the book - which is what stole the machine on 2026-08-10.
        # A swallowed exception cost a week. Never leave one silent.
        Write-ResetLog ("[" + (Now-Str) + "] chapter scan failed: " + $_.Exception.Message)
    }

    if ($chapters.Count -lt 2) { Close-ChapterPanel $Win; return $null }

    $total = 0
    foreach ($c in $chapters) { $total += $c.Dur }

    # How far INTO the book we want to be.
    $targetElapsed = $total - $TargetRemain
    if ($targetElapsed -lt 0) { $targetElapsed = 0 }

    $cum = 0; $pick = $null; $pickDur = $null
    foreach ($c in $chapters) {
        if ($targetElapsed -lt ($cum + $c.Dur)) { $pick = $c; $pickDur = $c.Dur; break }
        $cum += $c.Dur
    }
    if (-not $pick) { $pick = $chapters[-1]; $pickDur = $pick.Dur }

    if (-not (Invoke-Element $pick.El)) { Close-ChapterPanel $Win; return $null }

    # the click just started playback - kill it before the wind-through begins
    Start-Sleep -Milliseconds 400
    Silence-Player $Win | Out-Null
    Start-Sleep -Milliseconds 2100
    Silence-Player $Win | Out-Null
    Close-ChapterPanel $Win
    Silence-Player $Win | Out-Null
    return $pickDur
}

function Wait-Settled {
    # After a jump the player spends up to a minute visibly winding through
    # chapters before the readout means anything. Acting on it during that
    # window is acting on a number that is still moving - which is how restores
    # ended up landing on the chapter boundary instead of the exact spot.
    #
    # Waits until the remaining time holds steady across three reads. Playback
    # is always paused before this is called, so a settled player does not tick.
    param($Win, [int]$TimeoutSec = 75, [switch]$NoSilence)

    $stable = 0
    $last   = $null
    $tries  = [int]($TimeoutSec / 2)

    $gone = 0
    for ($i = 0; $i -lt $tries; $i++) {
        Start-Sleep -Milliseconds 2000
        # The wind-through is the loud part, so keep muzzling it - but only
        # every third pass. Every 2s was a click every 2s, and that is what made
        # the machine unusable.
        if (-not $NoSilence -and ($i % 3) -eq 0) { Silence-Player $Win | Out-Null }
        $l = Get-Live $Win
        if (-not $l) {
            # If the player window has gone, stop. Do not sit here clicking at
            # something that is not there.
            $gone++
            if ($gone -ge 4) { return $null }
            continue
        }
        $gone = 0
        if ($null -ne $last -and [Math]::Abs($l.Remain - $last) -lt 1) { $stable++ }
        else { $stable = 0 }
        $last = $l.Remain
        if ($stable -ge 2) { return $l }
    }
    return (Get-Live $Win)
}

function Test-UserReturned {
    # A restore takes minutes. Idle time used to be read ONCE before it started,
    # so if you sat back down ten seconds in it carried on clicking and stealing
    # focus for the rest. Checked every loop turn now; a manual -GoTo is exempt
    # because you asked for that one yourself.
    if ($script:ManualRun) { return $false }
    try { return ([Idle]::Seconds() -lt $ACTIVE_IDLE_SEC) } catch { return $true }
}

function Restore-ToRemaining {
    # Drive the player until "remaining" matches the target.
    #
    # Coarse: step whole chapters with Next/Previous Section, watching remaining
    #         time after every click (never trusting a label).
    # Fine:   seek inside the chapter. Moving forward N seconds reduces the
    #         remaining time by N, so the seek target is simply
    #         sliderPos + (currentRemaining - targetRemaining).
    param($Win, [double]$TargetRemain, [switch]$ThenPause)

    # A whole restore gets this many clicks and no more. Chapter click, panel
    # dismiss, a few pauses, and the commit - that is the entire budget. If the
    # logic ever tries to click its way somewhere again, it runs out and stops
    # instead of taking over the machine.
    $script:ClickBudget = 12
    $script:PauseBudget = 8

    try {

    # DO THE CHAPTER JUMP FIRST, before demanding a readable position.
    #
    # If the Chapters panel is open, the seek bar is hidden and the position
    # cannot be read at all - so requiring a reading up front meant a stuck
    # panel could never be recovered from. But the chapter LIST is readable in
    # exactly that state, and clicking a chapter both moves the player and
    # closes the panel. So jump first, read second.
    Silence-Player $Win | Out-Null

    $skipCoarse = $false
    $jumpDur = Invoke-ChapterJump $Win $TargetRemain

    $live = Get-Live $Win
    if (-not $live) { $live = Wait-Settled $Win }
    if (-not $live) { return $false }

    if ($null -ne $jumpDur) {
        $after = Wait-Settled $Win        # do not read a display still in motion
        if ($after) {
            $live = $after
            $gap = $live.Remain - $TargetRemain
            # Landed at the start of the chapter that contains the target, so
            # the gap should be somewhere inside that chapter. If so there is
            # nothing left for the chapter-stepping loop to do.
            if ($gap -ge -60 -and $gap -le ($jumpDur + 60)) { $skipCoarse = $true }
        }
    }

    # ---- coarse: land on a chapter whose start is at or before the target ----
    $clicks = 0
    if ($skipCoarse) {
        # nothing to do - the jump already landed us in the right chapter
    }
    elseif ($live.Remain -lt $TargetRemain) {
        # we are further along than the target; walk backwards
        while ($clicks -lt $MAX_SECTION_CLICKS -and $live.Remain -lt $TargetRemain) {
            if (Test-UserReturned) { break }
            $before = $live.Remain
            if (-not (Invoke-Btn $Win 'Previous Section')) { break }
            Start-Sleep -Milliseconds 1200
            Silence-Player $Win | Out-Null
            $live = Get-Live $Win
            if (-not $live) { return $false }
            if ($live.Remain -eq $before) { break }   # hit the start of the book
            $clicks++
        }
    }
    else {
        # walk forwards until one more chapter would overshoot
        while ($clicks -lt $MAX_SECTION_CLICKS) {
            if ($live.Remain -le $TargetRemain) { break }
            if (Test-UserReturned) { break }
            $before = $live.Remain
            if (-not (Invoke-Btn $Win 'Next Section')) { break }
            Start-Sleep -Milliseconds 1200
            Silence-Player $Win | Out-Null
            $after = Get-Live $Win
            if (-not $after) { return $false }
            if ($after.Remain -lt $TargetRemain) {
                # overshot - step back to this chapter's start and stop
                Invoke-Btn $Win 'Previous Section' | Out-Null
                Start-Sleep -Milliseconds 1200
            Silence-Player $Win | Out-Null
                $live = Get-Live $Win
                break
            }
            if ($after.Remain -eq $before) { break }  # hit the end of the book
            $live = $after
            $clicks++
        }
    }
    if (-not $live) { return $false }

    # ---- fine: SET the position. Do not click your way there. ---------------
    #
    # This used to close the gap with the 30-second skip buttons - up to 200
    # clicks, one every 250ms. Every one of those is a click, and every click
    # drags the browser to the front, so a restore became a machine-wide input
    # thief for a solid minute. That is what made the PC unusable on 2026-08-10.
    #
    # Writing the seek bar's value is a PROPERTY SET, not a click. It moves the
    # player without touching the foreground window at all. The only reason it
    # was not used before is that the seek bar reports a stale maximum right
    # after a jump and clamps - so wait for the display to settle first, by
    # which point it reports the real length of the chapter we are actually in.
    #
    # Budget for a whole restore is now about three clicks: the chapter, the
    # panel dismiss, and a pause. Not two hundred.
    $live = Wait-Settled $Win
    if (-not $live) { return $false }

    for ($i = 0; $i -lt 3; $i++) {
        $delta = $live.Remain - $TargetRemain      # seconds still to move forward
        if ([Math]::Abs($delta) -le $RESTORE_TOL_SEC) { break }

        $seekTo = $live.Pos + $delta
        $reachable = ($seekTo -ge 0 -and $null -ne $live.Max -and $seekTo -le $live.Max)

        if ($reachable) {
            $sc1 = New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, 'Seek position')
            $sc2 = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Slider)
            $sl = $Win.FindFirst($TS::Descendants, (New-Object System.Windows.Automation.AndCondition($sc1, $sc2)))
            if (-not $sl) { break }
            if (-not (Invoke-Pattern $sl 'seek-set' { $sl.GetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern).SetValue($seekTo) })) { break }
            Start-Sleep -Milliseconds 1500
        }
        else {
            # Slider still cannot reach it. Nudge with a HARD CAP of six clicks
            # - three seconds - and accept being slightly off rather than
            # hammering the foreground window. Being 90 seconds out beats
            # stealing your keyboard.
            # READ the skip size off the button instead of assuming 30 seconds.
            # Audible lets the interval be changed (10-90s) on the mobile apps,
            # and the setting is per-account - so if it ever changes, or a
            # future web player exposes it, hard-coded 30 would silently seek
            # the wrong distance and the restore would land in the wrong place.
            $dir  = $(if ($delta -gt 0) { 'forward' } else { 'back' })
            $btn  = $null
            $step = 30
            try {
                $bc = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Button)
                foreach ($cand in $Win.FindAll($TS::Descendants, $bc)) {
                    $cn = $null
                    try { $cn = $cand.Current.Name } catch { continue }
                    if ($cn -match ("^Skip " + $dir + " (\d+) seconds$")) {
                        $btn = $cn; $step = [int]$Matches[1]; break
                    }
                }
            } catch { }
            if (-not $btn) { $btn = "Skip $dir 30 seconds" }
            if ($step -le 0) { $step = 30 }
            $n = [int][Math]::Round([Math]::Abs($delta) / [double]$step)
            if ($n -gt 6) { $n = 6 }
            for ($k = 0; $k -lt $n; $k++) {
                if (-not (Invoke-Btn $Win $btn)) { break }
                Start-Sleep -Milliseconds 250
            }
            Start-Sleep -Milliseconds 900
        }

        $live = Get-Live $Win
        if (-not $live) { return $false }
    }

    # COMMIT THE POSITION.
    #
    # Seeking while paused appears to be a local-only change: the player keeps
    # syncing from Audible's server, and if the server still holds the reset
    # position it snaps back there a couple of minutes later, silently undoing
    # the restore. Observed 2026-08-06: a restore to 18h 30m held for 90s and
    # was back at 23h 34m by two minutes, with NO page reload in Firefox's
    # history - so this is an in-page re-sync, not the reload bug.
    #
    # Playing for a moment makes the player report the new position upstream.
    # The cost is about a second of audio; the alternative is a restore that
    # quietly does nothing.
    Invoke-Btn $Win 'Play' | Out-Null
    Start-Sleep -Milliseconds 900
    Invoke-Btn $Win 'Pause' | Out-Null
    Start-Sleep -Milliseconds 800

    # NEVER LEAVE IT TALKING. Verify it is actually silent instead of assuming
    # one Pause click worked - opening the panel, clicking a chapter and the
    # commit above all resume playback, and a single pause has been missed
    # before. Silence-Player returns $false once there is no Pause button left,
    # which is the only proof that it is really stopped.
    for ($p = 0; $p -lt 4; $p++) {
        if (-not (Test-IsPlaying $Win)) { break }
        Silence-Player $Win | Out-Null
        Start-Sleep -Milliseconds 700
    }

    # Verify against a settled readout, not a mid-flight one, or we report
    # success for a position the player is about to abandon.
    $final = Wait-Settled $Win
    if (-not $final) { return $false }
    return ([Math]::Abs($final.Remain - $TargetRemain) -le ($RESTORE_TOL_SEC + 60))
    }
    finally {
        # NOTHING may leave this function with the book talking. Not an early
        # return, not an exception, not a failed jump. Opening the panel,
        # clicking a chapter and the commit nudge all resume playback, and
        # single pause clicks have been missed before - so this VERIFIES by
        # reading, and keeps trying, rather than firing one click and hoping.
        # Close the panel FIRST. Closing it restarts playback, so proving
        # silence before this point proves nothing.
        try {
            $lc = New-Object System.Windows.Automation.AndCondition(
                (New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, 'Chapters')),
                (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::List)))
            if ($Win.FindFirst($TS::Descendants, $lc)) {
                if ($script:ClickBudget -le 0) { $script:ClickBudget = 2 }
                Close-ChapterPanel $Win | Out-Null
            }
        } catch { }

        # THEN prove it is silent, by reading.
        for ($q = 0; $q -lt 5; $q++) {
            if (-not (Test-IsPlaying $Win)) { break }
            Silence-Player $Win | Out-Null
            Start-Sleep -Milliseconds 700
        }
        if (Test-IsPlaying $Win) {
            Write-ResetLog ("[" + (Now-Str) + "] WARNING: could not stop playback after a restore")
        }
    }
}

# ------------------------------------------------------------- book records -

function Test-IsReset {
    # The whole decision, in one place, with no UI access - so it can be unit
    # tested. See tests.ps1.
    #
    #   RemainSec - what the player says now
    #   BestSec   - the last position we trusted
    #   BookLen   - the largest remaining ever seen for this book, i.e. its
    #               length, i.e. what the readout says at the very start
    param(
        [double]$RemainSec,
        $BestSec,
        $BookLen,
        [double]$JumpThreshold = 600,
        [double]$StartSlack    = 120
    )
    if ($null -eq $BestSec -or $null -eq $BookLen) { return $false }

    # Listening, rewinding 30s, or your phone's position syncing forward all
    # move remaining DOWN or barely at all. Only a loss moves it up.
    $jumped = ($RemainSec - [double]$BestSec) -gt $JumpThreshold
    if (-not $jumped) { return $false }

    # Not enough on its own: flipping chapters forward and back to find your
    # place also sends remaining upward. A real reset always lands at the very
    # START of the book, so require that too.
    return ($RemainSec -ge ([double]$BookLen - $StartSlack))
}

function Get-BookTitle {
    param([string]$Asin, $Titles)
    if ($Titles -and $Titles.ContainsKey($Asin)) { return $Titles[$Asin] }
    return $Asin
}

function Update-Current {
    param($Samples, $Titles)
    $lines = @("Audible - where you are right now", "updated: $(Now-Str)", "")
    if (-not $Samples -or $Samples.Count -eq 0) {
        # Distinguish "no Audible window at all" from "the window is there but
        # another tab is in front of the player" - they need different actions.
        if (@(Get-BrowserWindows).Count -gt 0) {
            $lines += "  CANNOT READ THE PLAYER - another tab is in front of it."
            $lines += ""
            $lines += "  The Audible window is open, but the player is not the tab"
            $lines += "  currently showing. Firefox only exposes the frontmost tab,"
            $lines += "  so nothing can be read or restored until the player tab is"
            $lines += "  the one on top."
            $lines += ""
            $lines += "  Fix: click back to the player tab, or drag it out into a"
            $lines += "  window of its own so nothing can ever get in front of it."
        } else {
            $lines += "  (no Audible window open)"
        }
    }
    foreach ($s in $Samples) {
        $lines += "  " + (Get-BookTitle $s.Asin $Titles)
        $lines += "      $($s.RemainText) in the book      <- this is the reliable one"
        $lines += "      $($s.Chapter), $(Format-Hms $s.Pos) in   (label can lag; see notes)"
        $lines += ""
    }
    try { Set-Content -Path $currentTxt -Value ($lines -join "`r`n") -Encoding UTF8 } catch { }
}

function Prune-State {
    param($State)
    $cutoff = (Get-Date).AddDays(-$BOOK_PRUNE_DAYS)
    $dead = @()
    foreach ($k in @($State.books.Keys)) {
        $seen = $null
        try { if ($State.books[$k].lastSeen) { $seen = [DateTime]::Parse($State.books[$k].lastSeen) } } catch { }
        if ($seen -and $seen -lt $cutoff) { $dead += $k }
    }
    foreach ($k in $dead) { $State.books.Remove($k) }
}

# ================================================================ MANUAL GOTO
if ($GoTo) {
    $target = ConvertFrom-RemainingText $GoTo
    if ($null -eq $target) { Write-Output "could not read '$GoTo' - try something like '22h 10m'"; exit 1 }
    $samples = @(Get-PlayerSamples)
    $win = $null
    if ($samples.Count -gt 0) {
        $win = $samples[0].Window
        Write-Output ("now    : " + $samples[0].RemainText)
    } else {
        # Position unreadable - usually the Chapters panel stuck open. That is
        # recoverable, so carry on with the window itself rather than refusing.
        $win = @(Get-BrowserWindows)[0]
        if (-not $win) { Write-Output "no player window found"; exit 1 }
        Write-Output "now    : (position unreadable - attempting recovery)"
    }
    Write-Output ("target : " + (Format-Remain $target))
    $script:ManualRun = $true
    $ok = Restore-ToRemaining $win ([double]$target)
    $after = Get-PlayerSamples
    if ($after.Count -gt 0) { Write-Output ("landed : " + $after[0].RemainText) }
    Write-Output $(if ($ok) { "OK" } else { "did not land within tolerance" })
    exit $(if ($ok) { 0 } else { 1 })
}

# =================================================================== SELFTEST
if ($SelfTest) {
    Write-Output "=== SELF TEST ==="
    $samples = Get-PlayerSamples
    if ($samples.Count -eq 0) { Write-Output "FAIL: no player window found"; exit 1 }
    $s0 = $samples[0]
    $origRemain = $s0.RemainSec
    Write-Output ("player  : " + $s0.Asin)
    Write-Output ("start   : " + $s0.RemainText)

    # 1. put it somewhere specific, as if you had been listening
    $pretend = $origRemain - (95 * 60)    # 95 minutes further in
    Write-Output ""
    Write-Output ("step 1 - move to " + (Format-Remain $pretend) + " left (pretend this is where you were)")
    if (-not (Restore-ToRemaining $s0.Window ([double]$pretend))) { Write-Output "FAIL: could not get there"; exit 1 }
    $s1 = (Get-PlayerSamples)[0]
    Write-Output ("  now at  : " + $s1.RemainText)

    # 2. record it, exactly as the watcher would
    $remembered = $s1.RemainSec
    Write-Output ""
    Write-Output ("step 2 - remembered: " + (Format-Remain $remembered) + " left")

    # 3. simulate the reload dumping you at the start of the book
    Write-Output ""
    Write-Output "step 3 - simulate the reset (back to the beginning)"
    if (-not (Restore-ToRemaining $s0.Window ([double]$origRemain))) { Write-Output "FAIL: could not simulate"; exit 1 }
    $s2 = (Get-PlayerSamples)[0]
    Write-Output ("  now at  : " + $s2.RemainText)

    # 4. would the detector fire?
    Write-Output ""
    $jump = $s2.RemainSec - $remembered
    Write-Output ("step 4 - remaining jumped UP by " + [Math]::Round($jump/60) + " min (threshold " + ($RESET_JUMP_SEC/60) + " min)")
    if ($jump -le $RESET_JUMP_SEC) { Write-Output "FAIL: reset would not be detected"; exit 1 }
    Write-Output "  RESET DETECTED"

    # 5. restore
    Write-Output ""
    Write-Output "step 5 - restoring"
    $ok = Restore-ToRemaining $s0.Window ([double]$remembered)
    $s3 = (Get-PlayerSamples)[0]
    Write-Output ("  now at  : " + $s3.RemainText + "   (wanted " + (Format-Remain $remembered) + ")")
    $off = [Math]::Abs($s3.RemainSec - $remembered)
    Write-Output ("  off by  : " + [Math]::Round($off) + " s")

    Write-Output ""
    if ($ok -and $off -le ($RESTORE_TOL_SEC + 60)) { Write-Output "RESULT: PASS - recorded, detected, restored" }
    else { Write-Output "RESULT: FAIL"; }

    Write-Output ""
    Write-Output "putting the player back where I found it..."
    Restore-ToRemaining $s0.Window ([double]$origRemain) | Out-Null
    $s4 = (Get-PlayerSamples)[0]
    Write-Output ("  final   : " + $s4.RemainText + "   (found it at " + $s0.RemainText + ")")
    exit 0
}

# ====================================================================== LOOP =

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Idle {
    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO p);
    [DllImport("kernel32.dll")] public static extern uint GetTickCount();
    public static uint Seconds() {
        LASTINPUTINFO i = new LASTINPUTINFO();
        i.cbSize = (uint)Marshal.SizeOf(i);
        if (!GetLastInputInfo(ref i)) return 0;
        return (GetTickCount() - i.dwTime) / 1000;
    }
}
"@ -ErrorAction SilentlyContinue

function New-Watch {
    # Grab direct handles to the two things worth watching. Doing this costs a
    # tree walk, so it happens once and then gets re-used every tick.
    foreach ($w in (Get-BrowserWindows)) {
        try {
            $sc1 = New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, 'Seek position')
            $sc2 = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Slider)
            $sl = $w.FindFirst($TS::Descendants, (New-Object System.Windows.Automation.AndCondition($sc1, $sc2)))
            if (-not $sl) { continue }
            $rp = $sl.GetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern)

            $remainEl = $null
            $tc = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Text)
            foreach ($t in $w.FindAll($TS::Descendants, $tc)) {
                $nm = $t.Current.Name
                if ($nm -and $nm.Trim() -match 'left\s*$') { $remainEl = $t }
            }
            if (-not $remainEl) { continue }

            return [pscustomobject]@{
                Window = $w
                Range  = $rp
                Remain = $remainEl
            }
        } catch { }
    }
    return $null
}

function Read-Watch {
    # One tick. Returns remaining seconds, or $null if the page was torn down
    # (a reload destroys these elements, and the read throws).
    param($Watch)
    try {
        $null = $Watch.Range.Current.Value
        $nm   = $Watch.Remain.Current.Name
        if (-not $nm) { return $null }
        return (ConvertFrom-RemainingText $nm.Trim())
    } catch {
        return $null
    }
}

function Invoke-FullPass {
    param($Titles)
    # Fresh, small click allowance every pass. Normal operation needs ZERO
    # clicks - this only covers stopping unwanted playback. A restore raises it.
    $script:ClickBudget = 6
    $script:PauseBudget = 6
    try {
        $state   = Load-State
        $samples = Get-PlayerSamples
        $dirty   = $false
        $moved   = $false     # did we actually reposition the player this pass?

        foreach ($s in $samples) {
            $asin = $s.Asin
            if (-not $state.books.ContainsKey($asin)) {
                $state.books[$asin] = @{
                    title = (Get-BookTitle $asin $Titles); lastSeen = (Now-Str)
                    best  = $null; restores = @(); history = @()
                }
            }
            $book = $state.books[$asin]
            $book.lastSeen = Now-Str
            $book.title    = (Get-BookTitle $asin $Titles)

            # Highest remaining ever seen for this book is, in effect, its
            # length - i.e. what the readout says when you are at the start.
            if (-not $book.bookLen -or $s.RemainSec -gt [double]$book.bookLen) {
                $book.bookLen = $s.RemainSec
                $dirty = $true
            }

            $best = $book.best
            $bestSec = $null
            if ($best) { $bestSec = $best.remainSec }
            $isReset = Test-IsReset -RemainSec $s.RemainSec -BestSec $bestSec `
                                    -BookLen $book.bookLen -JumpThreshold $RESET_JUMP_SEC

            if ($isReset) {
                $suppressLog = $false
                $restoredOk  = $false
                $entry = @(
                    ("=" * 62),
                    "RESET DETECTED  $(Now-Str)",
                    "  book : $($book.title)  [$asin]",
                    "",
                    "  you were at      : $(Format-Remain $best.remainSec) left   ($($best.chapter), $(Format-Hms $best.pos) in)",
                    "  it dumped you at : $($s.RemainText)"
                ) -join "`r`n"

                $recent = @()
                foreach ($r in @($book.restores)) {
                    try { if (([DateTime]::Parse($r)) -gt (Get-Date).AddHours(-1)) { $recent += $r } } catch { }
                }

                $idleFor = 0
                try { $idleFor = [int][Idle]::Seconds() } catch { }

                # SILENCE IT FIRST - but only if he is away. Clicking Pause is
                # still a click, and a click still steals the foreground. If he
                # is at the keyboard he can hit pause himself far faster than
                # this can, and without stealing his keystrokes.
                if ($s.IsPlaying -and -not $NoRestore -and $idleFor -ge $ACTIVE_IDLE_SEC) {
                    if (Invoke-Btn $s.Window 'Pause') {
                        $entry += "`r`n  paused it immediately"
                    }
                }

                # Land slightly EARLIER than recorded, so a second or two lost
                # in the rounding never costs context.
                $target = [double]$best.remainSec + $RESTORE_BACKOFF_SEC

                if ($NoRestore) {
                    $entry += "`r`n  restore : skipped (record-only mode)"
                } elseif ($idleFor -lt $ACTIVE_IDLE_SEC) {
                    # THE IMPORTANT ONE. Driving the player means clicking it,
                    # and every click drags the browser window to the front. Not
                    # while he is working. Your place is safely recorded above;
                    # it will be put back the moment the machine goes quiet.
                    $entry += "`r`n  restore : DEFERRED - you were using the PC ($idleFor s since last input)."
                    $entry += "`r`n            Your place is recorded above and will be restored once you step away."
                    if ($book.deferredAt) { $suppressLog = $true } else { $book.deferredAt = (Now-Str) }
                } elseif ($recent.Count -ge $MAX_RESTORES_PER_HR) {
                    $entry += "`r`n  restore : SKIPPED - already restored $($recent.Count) times this hour"
                } else {
                    $did = Restore-ToRemaining $s.Window $target -ThenPause
                    if ($did) {
                        $entry += "`r`n  restore : OK - put back to $(Format-Remain $best.remainSec) left, and paused"
                        $moved = $true

                        # Read back where it actually ended up. The remaining
                        # time is accurate immediately; the chapter label can
                        # take up to a minute to catch up, so treat it as a hint.
                        $landed = @(Get-PlayerSamples) | Where-Object { $_.Asin -eq $asin } | Select-Object -First 1
                        if ($landed) {
                            $entry += "`r`n  verified : $($landed.RemainText), $($landed.Chapter)"
                        }
                        $recent += (Now-Str)
                        $book.restores = @(@($recent) | Select-Object -Last 20)
                        $book.deferredAt = $null
                        $restoredOk = $true
                    } else {
                        $entry += "`r`n  restore : FAILED - your place is written above, set it by hand"
                    }
                }
                # A reset we did NOT fix leaves the player sitting at the wrong
                # place - usually the start of the book, quietly playing on.
                # Mark it pending, or ordinary sampling will adopt that wrong
                # position as your new place and the real one is gone.
                # This happened on 2026-08-10: a reset went unrestored, the book
                # played on to chapter 6, and "where you are" was overwritten
                # from 14h 9m to 21h 33m.
                if (-not $restoredOk -and -not $book.deferredAt) { $book.deferredAt = (Now-Str) }

                $entry += "`r`n" + ("=" * 62) + "`r`n"
                # A deferred reset is re-detected on every pass. Log it once,
                # not every five minutes.
                if (-not $suppressLog) {
                    Write-ResetLog $entry
                    Write-Output "RESET on $($book.title) - see data\resets.txt"
                }
                $dirty = $true
                # deliberately do NOT let the reset sample become 'best'
            }
            else {
                # While a reset is pending (detected but not fixed), the player
                # is parked somewhere wrong and may be playing on. Refuse to
                # adopt any position EARLIER than the one we are protecting.
                # Getting genuinely past it clears the flag.
                if ($book.deferredAt -and $best -and $null -ne $best.remainSec) {
                    if ($s.RemainSec -gt [double]$best.remainSec) {

                        # THE DEFERRED RESTORE ACTUALLY HAPPENS HERE.
                        # The log promised "will be restored once you step away"
                        # and nothing ever did it - there was no retry anywhere,
                        # and once the book drifted more than two minutes past
                        # the start, Test-IsReset stopped recognising it, so the
                        # place sat in state.json and was never put back.
                        $idleNow = 0
                        try { $idleNow = [int][Idle]::Seconds() } catch { }
                        if (-not $NoRestore -and $idleNow -ge $ACTIVE_IDLE_SEC) {
                            if (Test-IsPlaying $s.Window) { Silence-Player $s.Window | Out-Null }
                            $lateOk = Restore-ToRemaining $s.Window ([double]$best.remainSec + $RESTORE_BACKOFF_SEC)
                            Write-ResetLog (("=" * 62) + "`r`n" +
                                "DEFERRED RESTORE $(Now-Str)`r`n" +
                                "  book : $($book.title)`r`n" +
                                "  putting you back to $(Format-Remain $best.remainSec) left`r`n" +
                                "  result : " + $(if ($lateOk) { 'OK' } else { 'FAILED - set it by hand' }) + "`r`n" +
                                ("=" * 62) + "`r`n")
                            if ($lateOk) { $book.deferredAt = $null }
                            $dirty = $true
                            continue
                        }
                        $book.history = @(@($book.history) + ,@{
                            t = (Now-Str); remainSec = $s.RemainSec
                            chapter = $s.Chapter; pos = [Math]::Round($s.Pos,1); note = 'drift-after-reset'
                        } | Select-Object -Last $HISTORY_CAP)
                        $dirty = $true
                        Update-Current $samples $Titles
                        continue
                    }
                    $book.deferredAt = $null   # listened past it - back to normal
                }

                $changed = $false
                if (-not $best) { $changed = $true }
                elseif ([Math]::Abs([double]$best.remainSec - $s.RemainSec) -ge 30) { $changed = $true }
                elseif ([Math]::Abs([double]$best.pos - $s.Pos) -ge 15) { $changed = $true }

                if ($changed) {
                    $book.best = @{
                        remainSec  = $s.RemainSec
                        remainText = $s.RemainText
                        chapter    = $s.Chapter
                        pos        = [Math]::Round($s.Pos, 1)
                        at         = (Now-Str)
                    }
                    $h = @($book.history)
                    $h += ,@{ t = (Now-Str); remainSec = $s.RemainSec; chapter = $s.Chapter; pos = [Math]::Round($s.Pos,1) }
                    if ($h.Count -gt $HISTORY_CAP) { $h = @(@($h) | Select-Object -Last $HISTORY_CAP) }
                    $book.history = $h
                    $dirty = $true
                }
            }
        }

        if ($dirty) { Prune-State $state; Save-State $state }
        # $samples was read BEFORE any restore ran, so after a restore it holds
        # the position we just corrected away from. Re-read, or current.txt
        # would show you the reset value we already fixed.
        if ($moved) { $samples = Get-PlayerSamples }
        Update-Current $samples $Titles
    }
    catch {
        Write-ResetLog ("[" + (Now-Str) + "] watcher error: " + $_.Exception.Message)
    }
}

$titles = Load-Titles

# -Once is a read-only snapshot, so it must not be blocked by the running
# watcher's lock - you want to be able to check on things at any time.
if ($Once) { Invoke-FullPass $titles; exit 0 }

# Two watchers would fight each other during a restore. First one wins.
$mutex = New-Object System.Threading.Mutex($false, 'Global\AudiblePlaceKeeper')
if (-not $mutex.WaitOne(0)) {
    Write-Output "Another Audible Place Keeper is already running - exiting."
    exit 0
}

Write-Output "Audible Place Keeper running."
Write-Output ("  script   : " + $PSScriptRoot)
Write-Output ("  data     : " + $DataRoot)
Write-Output ("  full pass: every $HeavyIntervalSeconds s")
Write-Output ("  watchdog : every $WatchdogSeconds s")
if ($NoRestore) { Write-Output "  mode     : record only (no restore)" }

$lastHeavy  = [DateTime]::MinValue
$watch      = $null
$lastRemain = $null

while ($true) {
    try {
        # ---- the fast path -------------------------------------------------
        #
        # This does NOT look for "audio started" - you press play all the time
        # and that must never trigger anything. It looks for the one thing that
        # only a reset can do: the book's REMAINING time jumping upward. Normal
        # listening only ever drives that number down.
        if (-not $watch) {
            $watch = New-Watch
            if ($watch) { $lastRemain = Read-Watch $watch }
        }
        else {
            $remain = Read-Watch $watch

            if ($null -eq $remain) {
                # elements died - the page was torn down, i.e. it reloaded.
                # Re-acquire and let the full pass work out what happened.
                $watch = $null
                Invoke-FullPass $titles
                $lastHeavy = Get-Date
            }
            elseif ($null -ne $lastRemain -and ($remain - $lastRemain) -gt $RESET_JUMP_SEC) {
                # caught it in the act, within a second
                if (-not $NoRestore -and [Idle]::Seconds() -ge $ACTIVE_IDLE_SEC) {
                    Invoke-Btn $watch.Window 'Pause' | Out-Null
                }
                Invoke-FullPass $titles
                $lastHeavy  = Get-Date
                $watch      = $null
                $lastRemain = $null
            }
            else {
                $lastRemain = $remain
            }
        }

        # ---- the scheduled full sample -------------------------------------
        if (((Get-Date) - $lastHeavy).TotalSeconds -ge $HeavyIntervalSeconds) {
            Invoke-FullPass $titles
            $lastHeavy = Get-Date
            $watch     = $null      # re-acquire; the tree may have changed
        }
    }
    catch {
        Write-ResetLog ("[" + (Now-Str) + "] loop error: " + $_.Exception.Message)
        $watch = $null
    }

    Start-Sleep -Seconds $WatchdogSeconds
}






