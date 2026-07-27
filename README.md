# EtherBeep

Bench companion for [speedWATCH](https://github.com/xtopher757/SpeedWATCH):
docks a tiny console window in a screen corner and **beeps the instant a port
answers 3 consecutive pings** - so the operator hears a port come alive
without watching any window.

Built for sweeping a unit's 4 ports with one cable: each port beeps a step
higher in pitch, and a three-note chord marks the last one, so a whole unit
runs by ear.

## Run

Double-click `EtherBeep.bat`, or:

```
powershell -ExecutionPolicy Bypass -File "EtherBeep.ps1"
```

Plug into port 1 -> two-tone beep as soon as it answers. Move the cable to
port 2 -> a higher beep. After port 4, a rising chord means the unit is done
and the counter resets for the next one. Ctrl+C to stop.

```
15:34:08 port 1/4 UP  (1180ms, 1ms rtt)
15:34:11 port 2/4 UP  (1240ms, 1ms rtt)
15:34:13 port 3/4 UP  (1205ms, 1ms rtt)
15:34:15 port 4/4 UP  (1190ms, 1ms rtt)
15:34:15 unit done - 4/4 ports
```

The time in parentheses is the whole cable-to-beep cost, measured from the
first missed ping after the unplug - so it is the real per-port cycle time,
not just the part after EtherBeep made its mind up.

Units with a different port count: `-Ports 8`.

## Speed

Port-to-port turnaround is **~100ms of script overhead**, so in practice the
only thing you wait for is the cable:

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

**The remaining wait is physical, not ours.** Copper autonegotiation takes
~1-2s on gigabit before any ping can succeed, which dominates everything
above. If you need the sweep faster than that, the lever is the link, not
this script: forcing the test adapter to 100M full-duplex skips most of the
autoneg cycle, if the unit's ports support it.

## Parameters

| Param | Default | Meaning |
|---|---|---|
| `-Target` | `192.168.0.1` | IP to ping (the unit's LAN gateway) |
| `-Ports` | `4` | ports per unit; chord + counter reset after the last |
| `-Required` | `3` | consecutive successes that trigger the beep |
| `-TimeoutMs` | `250` | per-ping timeout |
| `-ArmedGapMs` | `50` | gap between probes while hunting for a port |
| `-UpGapMs` | `50` | gap between probes while up (the unplug watch) |
| `-DownFails` | `3` | consecutive failures that re-arm |
| `-Corner` | `bottomleft` | screen corner to dock (`topright`, `topleft`, `bottomright`, `bottomleft`) |
| `-NoLayout` | off | skip the window resize/move |

Trading safety for speed: `-DownFails 2 -UpGapMs 25` re-arms in ~25ms, but a
single dropped ping on a live port will then re-arm and re-beep the same port.
The defaults are set so that takes three consecutive misses.

Note: .NET Ping cannot bind a source interface; a one-time startup check warns
if more than one NIC sits on the target's subnet.
