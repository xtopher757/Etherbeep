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

The launcher asks for admin. Say yes if you can - that is what lets EtherBeep
pin the test NIC to 100M, which is the single biggest speed win (see below).
Declining is fine; it runs unelevated and leaves the adapter on auto.

Plug into a port -> short rising beep as soon as it answers. Move the cable ->
the next beep. Ctrl+C to stop.

```
16:05:52 port UP  (410ms, 1ms rtt)
16:05:56 port UP  (395ms, 1ms rtt)
16:06:01 port UP  (402ms, 1ms rtt)
```

The time in parentheses is the whole cable-to-beep cost, measured from the
first missed ping after the unplug - so it is the real per-port cycle time,
not just the part after EtherBeep made its mind up.

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

## Parameters

| Param | Default | Meaning |
|---|---|---|
| `-Target` | `192.168.0.1` | IP to ping (the unit's LAN gateway) |
| `-Required` | `3` | consecutive successes that trigger the beep |
| `-TimeoutMs` | `250` | per-ping timeout |
| `-ArmedGapMs` | `50` | gap between probes while hunting for a port |
| `-UpGapMs` | `50` | gap between probes while up (the unplug watch) |
| `-DownFails` | `3` | consecutive failures that re-arm |
| `-NoForce100` | off | leave the adapter's speed/duplex alone |
| `-Corner` | `bottomleft` | screen corner to dock (`topright`, `topleft`, `bottomright`, `bottomleft`) |
| `-NoLayout` | off | skip the window resize/move |

Trading safety for speed: `-DownFails 2 -UpGapMs 25` re-arms in ~25ms, but a
single dropped ping on a live port will then re-arm and re-beep the same port.
The defaults are set so that takes three consecutive misses.

Note: .NET Ping cannot bind a source interface; a one-time startup check warns
if more than one NIC sits on the target's subnet.
