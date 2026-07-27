# EtherBeep

Bench companion for [speedWATCH](https://github.com/xtopher757/SpeedWATCH):
docks a tiny console window in a screen corner and **beeps the instant the
unit under test answers 3 consecutive pings** - so the operator hears a unit
come alive without watching any window.

## Run

Double-click `EtherBeep.bat`, or:

```
powershell -ExecutionPolicy Bypass -File "EtherBeep.ps1"
```

Plug a unit in -> rising two-tone beep within ~a second of it answering.
Unplug -> `down - re-armed` -> the next unit beeps again. Ctrl+C to stop.

## How it stays fast

- In-process .NET pings (`System.Net.NetworkInformation.Ping`) - no `ping.exe`
  process spawn, 250ms timeout, ~1ms LAN round-trips.
- Zero adapter/CIM calls in the hot loop; ping success is the only signal.
- During a success streak the next ping fires with no gap - worst-case beep
  latency after the unit first answers is one 200ms armed-gap + 3 RTTs.
- Consecutive means consecutive: any miss resets the streak (no false beeps
  from a unit mid-boot).
- After beeping it drops to a lazy 1s watch; 4 consecutive misses re-arm it.

## Parameters

| Param | Default | Meaning |
|---|---|---|
| `-Target` | `192.168.0.1` | IP to ping (the unit's LAN gateway) |
| `-Required` | `3` | consecutive successes that trigger the beep |
| `-TimeoutMs` | `250` | per-ping timeout |
| `-ArmedGapMs` | `200` | gap between probes while waiting |
| `-DownFails` | `4` | consecutive failures that re-arm |
| `-Corner` | `bottomleft` | screen corner to dock (`topright`, `topleft`, `bottomright`, `bottomleft`) |
| `-NoLayout` | off | skip the window resize/move |

Note: .NET Ping cannot bind a source interface; a one-time startup check warns
if more than one NIC sits on the target's subnet.
