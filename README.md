# EtherBeep

Bench companion for [speedWATCH](https://github.com/xtopher757/SpeedWATCH):
docks a tiny console window in a screen corner and **beeps the instant a port
answers 3 consecutive pings** - so the operator hears a port come alive
without watching any window.

Built for sweeping a unit's ports with one cable. Works the same on 2-port
and 4-port units: one beep means one port answered.

## Run

Double-click `EtherBeep.bat`, or:

```
powershell -ExecutionPolicy Bypass -File "EtherBeep.ps1"
```

The launcher never elevates on its own - no UAC prompt on double-click. If
you're already in an admin console EtherBeep pins the test NIC to 100M
automatically (see below); otherwise it just runs on auto. To get 100M
without opening an admin console first, right-click `EtherBeep.bat` ->
"Run as administrator".

Plug into a port -> short rising beep as soon as it answers. Move the cable ->
the next beep. Ctrl+C to stop.

## Layouts

Three 46x12 console layouts, from a Claude Design exploration
(`EtherBeep Console.dc.html`). Pick one with `-Layout`.

### `tape` (default) - a scrolling log in fixed columns

```
EtherBeep  192.168.0.1  3 pings
link  100M full  ·  Ethernet 4
──────────────────────────────────────────
16:05:52  UP    410ms    1ms
16:05:56  UP    395ms    1ms
16:06:01  UP    402ms    1ms
16:06:07  UP    398ms    1ms
16:06:14  ··    waiting 6s
```

Time, a 2-char state marker, cycle, rtt - so cycle times compare down the
page instead of needing to be re-read line by line. `··` is the ambient
marker for anything that isn't a confirmed port: a `waiting` heartbeat,
`still up`, `standby`, `awake`. Append-only, so scrollback is preserved and
nothing depends on cursor control.

### `status` - scrolling log plus one live row redrawn in place

```
EtherBeep  192.168.0.1  100M full
──────────────────────────────────────────
16:05:52  UP    410ms    1ms
16:05:56  UP    395ms    1ms
16:06:01  UP    402ms    1ms
16:06:11  UP    398ms    1ms
                                              <- 7-row log block
──────────────────────────────────────────
 UP    ■■■  398ms  1ms rtt   4 up             <- redrawn, never scrolls
```

The bottom row is rewritten in place: state, streak dots, the last cycle,
and a running ports-confirmed tally. Because the elapsed time ticks in one
spot, the 5s `waiting` heartbeat lines disappear entirely. Newest log entry
is green; the whole block dims in standby. ` UP ` is reverse video - a
background colour on a run of spaces, which is all the design's filled band
ever was.

### `glance` - no scrollback, readable at arm's length

```
                   PORT  UP                     <- filled colour band
     cycle     398ms
     rtt         1ms      streak ■■■
──────────────────────────────────────────
  16:05:52  16:05:56  16:06:01  16:06:11
  410ms     395ms     402ms     398ms
──────────────────────────────────────────
192.168.0.1  100M full  ·  ctrl+c stop
```

The whole panel repaints per event. State is a band of colour rather than a
word in a list (green `PORT  UP`, yellow `ARMED`, near-black `STANDBY`), the
last cycle time gets its own oversized line, and history shrinks to two
aligned rows of the last four ports. Nothing accumulates, so the corner
never fills up.

### Notes on the panel layouts

`status` and `glance` repaint 11 rows in place, which means:

- **They need cursor control.** With output redirected or piped they fall
  back to `tape` and say so, rather than drawing nothing.
- **They never scroll.** Every row is written with an explicit cursor
  position and no newline, and the layout occupies rows 0-10 of the 12-row
  window so row 11 always has somewhere to land. One accidental scroll would
  slide the pinned row off and desync every subsequent write.
- **They repaint only when something visible changed** - the state, the
  streak, a new port, or the one field that ticks. A 50ms poll would
  otherwise drive 20 full redraws a second.
- **The "N up" tally is a session total, not "port 2 of 4"** - it makes no
  claim about *which* port, so unlike an ordered counter nothing can desync
  it (see below).

Two places these differ from the mock, both deliberate:

- The design's streak squares are U+25AA/U+25AB, which aren't in code page
  437 - Windows PowerShell 5.1 renders those as `?`. They become `■` (CP437
  0xFE) and `░` (0xB0). The rule `─` and separator `·` are already CP437-safe.
- The mock puts the tally at column 28 on the `ARMED` row and 29 on the `UP`
  row. Both use 29 here, because on a row that redraws in place a one-column
  jump on every state change reads as jitter.

Colour is the 16 ANSI conhost defaults, as the design intended. The one thing
that doesn't survive: the mock dims standby history from `#767676` to
`#4a4a4a`, and conhost has no grey between DarkGray and Black, so in `glance`
the history rows can't visibly dim - the band carries that signal instead. In
`status` the log dims properly, since it goes from Gray to DarkGray.

Non-ASCII glyphs mean the script file carries a UTF-8 BOM; Windows
PowerShell 5.1 needs it to read the file as UTF-8 rather than the system
codepage. All glyphs used are in CP437, but rendering is unverified on real
Windows hardware from here - worth a glance the first time it runs.

### No port counting, on purpose

EtherBeep does not track "port 2 of 4". A counter only stays honest if every
port is tried exactly once, in order - one dead port or one re-test shifts it,
and from then on it reports the wrong port as passing. A counter that can lie
about which port passed is worse than no counter, so there isn't one. One beep
= one port answered, and the operator knows which port they just plugged into.

## Speed

Two separate costs, and they need different fixes.

**Script overhead: ~100ms.** Port-to-port turnaround, measured:

- With the cable out the interface has no route, so `Ping.Send` fails
  *instantly* instead of burning `-TimeoutMs`. That is what makes the re-arm
  cheap - it costs `(DownFails - 1) x UpGapMs`, 100ms at the defaults.
- All ports answer on the same IP, so the ARP entry stays warm across the
  swap - no resolution round-trip on the new port.
- In-process .NET pings (`System.Net.NetworkInformation.Ping`) - no `ping.exe`
  spawn, ~1ms LAN round-trips.
- Zero adapter/CIM calls in the hot loop; ping success is the only signal.
- During a success streak the next ping fires with no gap.
- Consecutive means consecutive: any miss resets the streak, so a port that
  answers once mid-negotiation will not beep.

**Link negotiation: ~1-2s, and it dominates.** Copper autonegotiation has to
finish before any ping can succeed, and no amount of loop tuning touches it.
So when run as admin, EtherBeep pins the test adapter to **100M full-duplex**
at startup, which skips most of the autoneg cycle:

- It finds the NIC carrying the target's subnet, then sets the standard NDIS
  `*SpeedDuplex` property - matching against the values the driver actually
  declares, since the strings differ per vendor.
- If the adapter offers no 100M full option (some are gig-only), it says so
  and leaves it on auto rather than guessing.
- **It puts the setting back on exit**, including on Ctrl+C. If that restore
  ever fails it prints the exact command to undo it by hand - a shared bench
  NIC left pinned at 100M is the kind of thing that gets debugged three weeks
  later.
- `-NoForce100` skips the whole thing.

Not running as admin just means this step is skipped, with a note saying so.

## Standby

After an hour with nothing happening, EtherBeep drops from 20 pings a second
to one every 2s. A unit left plugged in over a weekend is otherwise millions
of pings that nobody is listening to. In `tape` that prints
`··    standby · 2s poll`; in the panel layouts the state band and idle
counter show it instead.

It wakes on the **first** ping that changes - one answer while it is waiting,
or one miss while a port is up - not on the confirmed result. Waiting for the
full 3-ping streak or all of `-DownFails` would have put the 2s standby gap in
front of every one of them. So the cost of standby is at most one 2s poll on
the first cable touch after the idle period, and nothing after that.

`-StandbyMin 0` disables it; `-StandbyMin 15 -StandbyGapMs 5000` is a more
aggressive setting for a bench that sits unused often.

Because the per-port figure is measured from the unplug, a port plugged in
after a long gap would otherwise report a nonsense "cycle time" - it prints
`after 62m` instead of `3720000ms` when the gap was not really a swap.

## Beep in a noisy shop

`Console.Beep` has no volume control - it plays at whatever the PC speaker or
default output device is already set to, full stop. Pitch and repetition are
the only real levers against motors, compressors, and air tools, so:

- The tone is pitched high (G6 -> D7), above most shop noise, which tends to
  sit low/mid frequency.
- The whole phrase repeats `-BeepReps` times (2 by default) - redundancy gives
  the ear a second chance to catch it against a transient clatter, which does
  more for "was that actually heard" than one longer tone would.
- It's kept short: 80ms a rep, 40ms between. A sweep is a rapid sequence of
  these, so a long tone runs into the operator's next cable move.

`-BeepReps 1` goes back to a single phrase (fastest, quietest); `-BeepReps 3`
for a shop loud enough that two isn't reliable. The beep blocks while it
plays, so more reps means more time to the "definitely heard" point, not just
more noise - 80ms per rep plus a 40ms gap, so 200ms at the default 2.

## Parameters

| Param | Default | Meaning |
|---|---|---|
| `-Target` | `192.168.0.1` | IP to ping (the unit's LAN gateway) |
| `-Required` | `3` | consecutive successes that trigger the beep |
| `-TimeoutMs` | `250` | per-ping timeout |
| `-ArmedGapMs` | `50` | gap between probes while hunting for a port |
| `-UpGapMs` | `50` | gap between probes while up (the unplug watch) |
| `-DownFails` | `3` | consecutive failures that re-arm |
| `-StandbyMin` | `60` | idle minutes before standby (`0` = never) |
| `-StandbyGapMs` | `2000` | gap between probes while in standby |
| `-BeepReps` | `2` | times to repeat the beep phrase (shop-noise insurance) |
| `-Layout` | `tape` | console layout: `tape`, `status`, `glance` (see above) |
| `-NoForce100` | off | leave the adapter's speed/duplex alone |
| `-Corner` | `bottomleft` | screen corner to dock (`topright`, `topleft`, `bottomright`, `bottomleft`) |
| `-NoLayout` | off | skip the window resize/move |

Trading safety for speed: `-DownFails 2 -UpGapMs 25` re-arms in ~25ms, but a
single dropped ping on a live port will then re-arm and re-beep the same port.
The defaults are set so that takes three consecutive misses.

Note: .NET Ping cannot bind a source interface; a one-time startup check warns
if more than one NIC sits on the target's subnet.
