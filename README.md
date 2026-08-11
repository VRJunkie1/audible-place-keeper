# Audible Place Keeper

The Audible **web player** reloads its own tab every few days. When it does, it
comes back at the start of the book and reports position ~0 to Audible, which
overwrites your saved place. It usually happens while you are away, and on
Chrome it also starts playing at full volume.

Audible offers no desktop player other than the web one, and its bookmark
feature has no readable list, so a lost position means hunting through chapters.

This is a Windows background watcher that notices when that happens, stops the
playback, and puts you back where you were.

## How it works

It reads the player through Windows UI Automation — no browser extension, no
injected script, nothing installed into Firefox.

**Everything keys on the book's remaining time.** The player's chapter label and
seek-bar length are stale after a jump: jumping to Chapter 5 still displayed
"Chapter 1", while the remaining time moved by exactly the combined length of
chapters 1–4. Remaining time is the only readout that tells the truth.

**A reset needs two conditions**, not one: remaining time must jump *up* by more
than 10 minutes **and** the player must land at the very start of the book. The
jump alone is not enough — hunting for your place by flipping chapters forward
and back raises remaining time exactly like a reset does, and acting on that
would drag you to a spot you were only passing through.

Forward jumps are never treated as a reset. That is your phone's position
syncing over, and it is correct.

## Files

| | |
|---|---|
| `place-keeper.ps1` | the watcher |
| `tests.ps1` | unit tests for the reset decision — no browser needed |
| `run-hidden.vbs` | launcher (restores your place when you are away) |
| `run-hidden-recordonly.vbs` | launcher that **never clicks anything** |
| `resume.ps1` | put the player back to the last recorded place, by hand |
| `NOTES.md` | diagnosis, evidence, and thirteen hard-won gotchas |

Data is written to `%LOCALAPPDATA%\AudiblePlaceKeeper` — `current.txt` always
says where you are, `data\resets.txt` logs every reset and what was done about
it.

## Two modes

`run-hidden-recordonly.vbs` only watches and writes down where you are. It has
no code path that clicks, so it cannot steal focus or make noise.

`run-hidden.vbs` also restores your position — but only after you have been away
from the keyboard for three minutes, because driving the player means clicking
it, and clicking a browser control pulls that window to the front.

## Read NOTES.md before changing anything

Several behaviours here look wrong until you know why they are that way. Some
highlights:

- A UIA descendant search that does **not** match walks the entire subtree.
  Pointing one at an unidentified browser window can hang for minutes.
- The Chapters panel exposes each chapter twice; de-duplicate or the book length
  comes out double.
- Opening the panel, clicking a chapter, and closing the panel all **resume
  playback**.
- Every click is capped by a hard budget, because an early version clicked 200
  times in a row and made the machine unusable.

## Status

Works, and has recovered real resets. The reload itself is Audible's bug and is
not fixed here — this only limits the damage.

MIT licensed. Written for one machine; paths are derived, not hard-coded, but it
has only ever been run against Firefox.
