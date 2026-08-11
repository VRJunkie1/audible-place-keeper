# Audible Place Keeper — project notes

Written 2026-08-04. For whoever picks this up next, human or AI.

## The problem

Mike's Audible web player tab resets to the start of the book every few days,
usually while he is away from the PC, and loses his place every time. Audible's
web player is the only PC player they offer, and its bookmark feature has no
readable list, so a lost position means manually hunting through chapters.

## What was actually wrong (diagnosed, not guessed)

**The tab reloads itself.** Firefox's `places.sqlite` and Chrome's `History` both
record a transition type per page load. The webplayer URL has a long run of
`RELOAD` transitions with no preceding navigation:

    Firefox: 7/18 04:50, 7/19 00:43, 7/21 04:05, 7/21 14:02, 7/22 06:52,
             7/24 17:09, 7/27 18:02, 7/28 17:12, 7/30 20:23, 7/31 22:59

**On reload the player comes up at the start of the book and reports position ~0
back to Audible**, which overwrites the server-side "last position heard". One
event, both symptoms: the noise and the amnesia.

Every Audible player URL carries `initialCPLaunch=true`, which tells a freshly
loaded player to start playing. Audible appends it to *library* links too, so
"open it from your library instead" does not avoid it.

Chrome is roughly 3x worse than Firefox because Chrome's Media Engagement Index
auto-grants autoplay to sites you use heavily, while Firefox blocks
autoplay-with-sound by default. Firefox still loses the place — it just does it
silently. Blocking autoplay does **not** protect the position.

### Ruled out, with evidence

- **Sleep/wake** — sleep is disabled (High performance, standby+hibernate = 0);
  last real sleep/wake was months earlier.
- **Reboots** — uptime unbroken since 2026-07-15.
- **Browser crashes** — no Firefox crash dumps; newest Chrome crashpad dump
  predates the reloads.
- **Network drops** — `Tcpip` ephemeral-port-exhaustion warnings occur near
  daily but do not correlate with any reload timestamp. (Separate real issue.)

### Not known

**Why** it reloads. No crash dumps, no matching system events. Mike reports he
has never seen it happen mid-listen — only after the player has been idle for
hours. That is consistent with both browsers exempting audio-playing tabs from
tab unloading, and with a site-side session/DRM token expiring while idle, but
neither is confirmed.

**When it started.** Cannot be dated: Chrome prunes history at 90 days, so the
record begins 2026-05-06 no matter when the problem began. The oldest surviving
webplayer record (2026-05-08) is *itself* a reload, so it is at least that old.
`data/resets.txt` timestamps every future event, which is how we will finally
correlate it against browser/OS updates.

## Gotchas — read before touching the automation

These each cost a debugging cycle. They are not obvious.

1. **The chapter label and the seek bar's maximum are STALE.** After jumping to a
   new chapter the player keeps displaying the previous chapter's name and
   length until playback refreshes them. Verified: jumping to Chapter 5 still
   read "Chapter 1", but the book's remaining time moved by exactly the summed
   length of chapters 1–4.
   **Consequence: never verify a jump by reading the chapter label.** Everything
   in this project keys on the book's remaining time ("Xh Ym left"), which is
   the only readout that tells the truth. Its resolution is one minute.

2. **The seek slider clamps to that stale maximum.** `SetValue` cannot reach deep
   into a chapter longer than whatever chapter loaded first. Fine positioning
   uses the `Skip forward/back 30 seconds` buttons instead — exact, and immune.

3. **Each chapter appears in the Chapters panel twice**, as a `ListItem` and as a
   `Button` nested in it. Invoking the ListItem silently does nothing; only the
   Button navigates. Both report an `Invoke` pattern.

4. **The `Chapters` control is ExpandCollapse, not Invoke.** Calling
   `InvokePattern` on it throws `Unsupported Pattern`.

5. **`[int]` rounds in PowerShell.** `[int]23.55` is `24`, so `[int]$ts.TotalHours`
   turned 23h33m into "24h 33m". Use `[Math]::Floor`.

6. **Firefox only exposes the foreground tab to accessibility.** A player in a
   background tab cannot be read at all. Keeping it in its own window satisfies
   this permanently, even when that window is buried.

10. **After any jump the player takes up to a minute to settle, and everything
    it displays during that window is meaningless.** Mike watched it: once a
    position is set, the player visibly winds through chapters at roughly one
    per 1.5 seconds until it catches up.

    This bit hard. The fine-tuning step was reading the remaining-time display
    *while it was still winding*, "correcting" against a number in motion, and
    the restore ended up parked on the chapter boundary instead of the exact
    spot - reporting success on the way past. Measured 2026-08-06: restore to
    15h 2m reported OK, then read 15h 15m (Chapter 28, 0:00 in) a minute later.

    `Wait-Settled` fixes it by polling until the remaining time holds steady
    across three reads before anything acts on it, and again before the final
    verification. Same restore afterwards: asked for 18h 30m, landed 18h 30m,
    still 18h 30m ninety seconds later, at Chapter 15, 7:00 in.

    **Never read a position within a minute of moving one without settling
    first.** The settle wait is not overhead that can be optimised away - it is
    the player's own catch-up time.

11. **Jump chapters with the Chapters panel, not by stepping.** Stepping with
    Next/Previous Section costs ~1.5s per chapter, which was 30-60s on a
    28-chapter book and would be minutes on a long one. The panel lists every
    chapter with its duration, so the correct chapter can be computed from
    cumulative durations and reached in a single click, regardless of book
    length. `Invoke-ChapterJump` does this; the stepping loop remains only as a
    fallback when the panel cannot be read.

12. **The watcher WILL be killed, silently, and you will not find out why.** On
    2026-08-07 at 08:44 both the place keeper and the port sampler died in the
    same minute. No reboot (uptime unbroken since 2026-07-15), no crash in the
    Application log, no error line in `resets.txt` - and the loop's catch would
    have logged an exception. They were killed, by something never identified.

    The cost was real: a reset on 2026-08-08 restarted the book and nothing
    stopped it, because nothing was running. Two days of protection silently
    absent while the files all looked fine.

    **Do not assume the process is alive. Assume it is not.** Both tools now
    have keepalive scheduled tasks that fire every 5 minutes:

        schtasks /query /tn AudiblePlaceKeeperKeepalive
        schtasks /query /tn PortLeakSamplerKeepalive

    They just run `run-hidden.vbs`. The `Global\AudiblePlaceKeeper` mutex makes
    a launch a no-op when one is already running, so firing every 5 minutes
    costs nothing and revives it when it is not. Verified 2026-08-08 by killing
    the watcher: it came back on its own in about 4 minutes. Worst-case exposure
    is one 5-minute window.

    `Register-ScheduledTask` needs elevation and fails with Access Denied.
    `schtasks /create` works as a normal user. Use that.

    The Startup shortcuts are deliberately kept as well - they cover the logon
    case, the tasks cover the keep-alive case, and the mutex makes the overlap
    harmless.

13. **Find the player window by TITLE. Never scan every browser window.**
    This was the real cause of the 2026-08-08 failure, and it is subtle: the
    watcher was alive, using almost no CPU, and had not completed a pass in
    over five minutes.

    `Get-BrowserWindows` used to return every Firefox/Chrome/Edge/Opera window,
    and the caller then searched each one's entire accessibility tree for the
    seek bar. Mike had ten browser windows open - X, Google Docs, Patreon,
    Toggl - and walking those page trees across process boundaries is
    effectively unbounded. The process was not spinning, it was blocked inside
    UIA, which is why it looked healthy from the outside.

    The player window is titled "Audible Cloud Player" in every browser, and the
    design already requires it to be the active tab of its own window. Matching
    on that name took a full pass from "never finishes" to **0.7 seconds**.

    The lesson generalises: a UIA `FindFirst`/`FindAll` with `TreeScope
    ::Descendants` that does NOT match walks the entire subtree. Never aim one
    at a window you have not already identified.

## Design decisions

- **Remaining time is the position key**, not chapter+offset — see gotcha 1.

- **A reset needs TWO conditions, not one.** Remaining time must jump UP by more
  than 10 minutes *and* the player must land at the very start of the book.

  The jump alone is not enough, and assuming it was would have been a real bug.
  Mike hunts for his place by flipping chapters forward and then back, and the
  "back" half of that raises remaining exactly like a reset does. Acting on it
  would have dragged him to the too-far-forward spot he was only passing
  through. A genuine reset always lands at the beginning; manual hunting lands
  mid-book. Hence the second condition.

  "The start of the book" means within 120s of `bookLen`, which is simply the
  largest remaining value ever seen for that book. It is learned, not
  configured, and only ever grows.

  The decision lives in one function, `Test-IsReset`, with no UI access, so it
  can be unit tested. Do not inline it again.

- **Forward movement is never a reset.** When Mike listens on his phone and then
  refreshes the PC, the position jumps forward; that is his phone's position
  winning and it is correct. Only backward jumps trigger anything.

- **The reset sample is never allowed to become the stored place.** This was
  chosen over a strict "never record an earlier time" high-water rule, which
  would have broken his habitual 30-second rewinds — rewind twice and the stored
  place would drift ahead of where he actually is.

- **Pause first, restore second.** A restore can take a minute or two of stepping
  through chapters. Doing that while the book blares at 3am is unacceptable, so
  playback is stopped in one action before any navigation begins.

- **Two-speed polling.** A full sample is expensive (walks the whole UIA tree) and
  resets only happen during idle hours, so it runs every 5 minutes. But a reset
  that autoplays needs catching in seconds, so a cheap watchdog runs every 15s
  and only asks "is a Pause button present", i.e. did audio just start. Audio
  starting when we believed it was paused escalates immediately to a full pass.

- **Restores land 5 seconds early** so a lost second or two never costs context.

- **One state file keyed by ASIN**, not a file per book, so several player windows
  work at once without accumulating hundreds of stale buffers. History is capped
  at 150 samples per book; books untouched for 120 days are pruned.

## Layout

The script lives in Dropbox so it survives an SSD failure. The data files stay
on the local disk, because a file rewritten every few minutes would make Dropbox
sync churn constantly.

    Dropbox\PC\AudiblePlaceKeeper\     place-keeper.ps1, run-hidden.vbs, NOTES.md
    %LOCALAPPDATA%\AudiblePlaceKeeper\ current.txt, data\{state,resets,titles}

Each folder holds a shortcut to the other. Startup shortcut lives in the user's
Startup folder and points at `run-hidden.vbs` in Dropbox.

## Testing

    tests.ps1                          unit tests, no browser needed - RUN THESE
    place-keeper.ps1 -SelfTest         full record -> reset -> restore proof
    place-keeper.ps1 -Once             one sample, then exit
    place-keeper.ps1 -GoTo "11h 23m"   send the player to a position by hand

`tests.ps1` extracts `Test-IsReset` straight out of `place-keeper.ps1` by regex
and exercises it, so it tests the shipped code rather than a copy. It covers
normal listening, 30-second rewinds, chapter-hunting in both directions, phone
sync forward and backward, real resets, and the threshold boundaries. 18 cases,
all passing as of 2026-08-04. If you change the reset rule, change these too.

`-SelfTest` drives the real player: it moves 95 minutes in, records that,
simulates the reset, checks the detector fires, restores, and finally puts the
player back exactly where it found it. Last run: PASS, off by 0 seconds.

## More gotchas, from the reload experiments

7. **Navigating the player starts playback.** Clicking a chapter or stepping
   sections leaves it playing even if it was paused. This is why restores pause
   first and pause again at the end.

8. **Synthetic F5 via SendKeys is unreliable.** `SetForegroundWindow` from a
   background process often silently fails, and if `Ctrl+L` ran first the
   address bar keeps focus and swallows the F5 entirely. Two "results" were
   produced this way that meant nothing.

9. **Never trust that a reload happened — verify it against `places.sqlite`.**
   A `RELOAD` visit row is the only proof. Note Firefox buffers history writes,
   so a reload from seconds ago may not be in the file yet; wait a couple of
   minutes before concluding a reload did not happen.

## Open items

- **Does a reload preserve the position once Audible has synced it?** One
  verified reload (10:11:20 on 2026-08-04) threw the position from 21h26m back
  to 23h33m — but that reload came seconds after the position was set by
  automation, so "the reload wiped it" and "the reload correctly resumed a
  server position that had not been updated yet" both still fit. Two attempts to
  retest with a wait failed for the reasons in gotchas 8 and 9.
  This matters: if the position does survive once synced, then refreshing after
  a restore becomes safe and would fix the stale display in gotcha 1. Until it
  is proven, **refresh-after-restore stays off** — its failure mode is silently
  undoing the restore it was meant to display.
  To test properly: drive the reload some way that is verifiable, wait several
  minutes, then check `places.sqlite` for the `RELOAD` row before trusting any
  reading.

- **Whether trimming `initialCPLaunch=true` changes anything.** Still untested;
  the one attempt never actually navigated.

- **The daily `Tcpip` ephemeral-port exhaustion** (4231/4266) is a SEPARATE
  issue, unrelated to any of this — the timestamps do not correlate with a
  single reload. A recorder for it lives in `Dropbox\PC\PortLeakSampler\`.
  Note: 19 `claude.exe` processes were briefly suspected of leaking sockets;
  checking parent PIDs showed they are all children of the Claude desktop app
  (an Electron app, so many helper processes is normal), not DevBot subagents.
  That suspect is eliminated.

- **Root cause of the reload itself.** Mike reports it never happens mid-listen,
  only after hours idle. Both browsers exempt audio-playing tabs from unloading,
  and an idle session/DRM token expiring would also fit. Unconfirmed.
  `data/resets.txt` timestamps every future event, which is the way in.
