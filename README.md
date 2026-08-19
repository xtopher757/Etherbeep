# Etherbeep

An audible ping monitor for the bench. It watches `192.168.1.1` over the USB Ethernet
adapter and beeps when the device drops and when it comes back, so you can work at the
far end of a cable run without watching a screen.

The window is deliberately tiny. It stays on top of everything else, it never steals
focus from what you are working in, and you drag it wherever you want it.

```
+----------------------------+
|  UP           192.168.1.1 x|      green  = replying
|  00:04:12   1 ms   0% loss |      red    = not replying
+----------------------------+      grey   = still looking
```

Nothing to install alongside it. No modules, no runtime, no internet. It is one
PowerShell script that runs on any Windows PC as it comes.

---

## Install

### One line, any PC with internet

Open PowerShell (no admin needed) and paste:

```powershell
irm https://raw.githubusercontent.com/xtopher757/Etherbeep/main/Get-Etherbeep.ps1 | iex
```

Done. There is an Etherbeep shortcut on your desktop.

### From the QR code on the wall

Print the codes in [`docs/`](docs/) and put them next to the bench:

- **`qr-install-command`** holds the whole install command. Scan it with the bench
  barcode scanner into a **Win+R** box or a PowerShell window, press Enter, done.
  No typing at all.
- **`qr-repo-page`** opens this page, for reading on a phone.

Use the `.svg` files for printing, they stay sharp at any size.

### From a zip or USB stick

1. Download the folder ([Code > Download ZIP](https://github.com/xtopher757/Etherbeep/archive/refs/heads/main.zip)) and unzip it anywhere.
2. Right-click `Install-Etherbeep.ps1` and choose **Run with PowerShell**.
3. Done. There is an Etherbeep shortcut on your desktop.

The installer needs no administrator. It writes only inside your own user profile:

- copies Etherbeep to `%LOCALAPPDATA%\Etherbeep`
- makes a desktop shortcut and a Start menu entry
- puts the folder on your PATH, so `etherbeep` works in any terminal

To have it start by itself every time you log on, which is what you want on a bench PC
that sits waiting for a device:

```powershell
.\Install-Etherbeep.ps1 -Startup
```

or through the one-liner:

```powershell
iex "& { $(irm https://raw.githubusercontent.com/xtopher757/Etherbeep/main/Get-Etherbeep.ps1) } -Startup"
```

To remove it again:

```powershell
.\Install-Etherbeep.ps1 -Uninstall
```

### Without installing

Copy `Etherbeep.ps1` and `Etherbeep.cmd` onto a USB stick, keep them together in the
same folder, and double-click `Etherbeep.cmd`. That is the whole thing.

---

## What the beeps mean

| Sound | Meaning |
|---|---|
| Two quick notes at startup | Etherbeep is running and your speakers work |
| Rising three-note | **UP.** The device is replying |
| Falling two-note | **DOWN.** The device stopped replying |

Learn the two and you never have to look at the screen.

One dropped packet does not set off the alarm. Etherbeep only calls the device down
after two misses in a row, so ordinary packet loss stays quiet.

---

## Using the window

| Action | What it does |
|---|---|
| Drag anywhere | Move it. It remembers where you put it |
| Double-click | Switch between the wide and the narrow layout |
| Right-click | Menu: sound, always on top, move to corner, exit |
| `x` | Close |

---

## Standby

The bench sits waiting for a device overnight, so outside work hours Etherbeep slows
down instead of pinging every second until morning.

- **06:00 to 16:00** ping every second
- **16:00 to 06:00** ping every 30 seconds, and the window shows `standby`

It never stops watching. A device that comes up at 05:00 still beeps. Any state change
also pulls it back to the fast rate for five minutes, so whoever is standing at the
bench gets live feedback instead of a 30 second wait.

Change the hours to match your shift:

```powershell
etherbeep -StandbyFrom 17:30 -StandbyTo 07:00
```

Turn it off completely:

```powershell
etherbeep -NoStandby
```

Standby follows the clock only, not the calendar. If you want it to cover weekends too,
say so and it is a small change.

---

## Recording a soak test

For something you want to attach to a ticket, run the text version with a log. It writes
a CSV of every ping and every state change, and prints a summary when you stop it.

```powershell
etherbeep -Console -LogFile .
```

```
Timestamp,Event,Target,LatencyMs,Status,Detail
2026-08-17 08:05:08,PING,192.168.1.1,1,Success,""
2026-08-17 08:05:12,DOWN,192.168.1.1,,TimedOut,"after 2 missed replies; adapter: ..."
2026-08-17 08:05:48,UP,192.168.1.1,1,Success,"previous state Down for 00:00:36"
```

The summary at the end gives total time up, total time down, longest outage, packet
loss and latency.

---

## Options

Everything has a working default. You only need these when the bench is set up
differently.

| Option | Default | What it does |
|---|---|---|
| `-Target` | `192.168.1.1` | Device to ping |
| `-Interval` | `1` | Seconds between pings during work hours |
| `-TimeoutMs` | `800` | How long to wait for a reply |
| `-FailCount` | `2` | Misses in a row before it calls it down |
| `-OkCount` | `1` | Replies in a row before it calls it up |
| `-StandbyFrom` | `16:00` | Start of the slow window |
| `-StandbyTo` | `06:00` | End of the slow window |
| `-StandbyInterval` | `30` | Seconds between pings in standby |
| `-WakeMinutes` | `5` | Fast pinging for this long after any change |
| `-NoStandby` | off | Fast pinging around the clock |
| `-Reminder` | `0` | Chirp the current state every N seconds. Silent in standby |
| `-Zoom` | `1` | Make the window and text bigger, up to 3 |
| `-NoTopMost` | off | Let other windows cover it |
| `-ResetPosition` | off | Start in the bottom right corner again |
| `-Quiet` | off | No sound |
| `-LogFile` | none | Write a CSV. Give a file, or a folder to be named for you |
| `-Console` | off | Text monitor instead of the window |
| `-Count` | `0` | Stop after this many pings |

Full help, including examples:

```powershell
Get-Help .\Etherbeep.ps1 -Full
```

---

## If something is wrong

**No sound.** Etherbeep says so on startup if the PC cannot make a tone. Otherwise check
the volume and that the speakers are not muted. It keeps working either way, the window
still turns red and green.

**"Running scripts is disabled on this system."** Start it from `Etherbeep.cmd` or the
desktop shortcut. Both run it without changing any setting on the PC. If you must run
the `.ps1` directly:

```powershell
powershell -ExecutionPolicy Bypass -File .\Etherbeep.ps1
```

**Windows says the file is blocked.** It came from a download. The installer unblocks it
for you. To do it by hand:

```powershell
Unblock-File .\Etherbeep.ps1, .\Etherbeep.cmd
```

**It says DOWN and you think it should be up.** The DOWN line reports what the adapter
is doing. `no link` means the cable or the USB adapter, not the device. Check it in the
CSV log or in the text version:

```powershell
etherbeep -Console
```

**The window will not appear.** On a PC that cannot show it, Etherbeep says so and
switches to the text version by itself. Nothing is lost except the window.

**It is in the way.** Drag it. Double-click makes it narrower. Right-click turns off
always-on-top.

---

## What it runs on

Any Windows PC with Windows PowerShell 5.1, which is every Windows 10 and Windows 11
machine as installed. PowerShell 7 works too. Nothing else is needed.
