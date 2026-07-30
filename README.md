# Etherbeep

A Project Zomboid mod that plays a sound when a new character is created.

Four sounds are bundled, you can drop in your own, and the volume, delay and
master switch are all configurable. Existing characters stay silent when you
load them — only brand new ones get the sound.

![poster](Etherbeep/poster.png)

## Install

Copy the `Etherbeep` folder (the one containing `mod.info`) into your Zomboid
mods folder, then enable **Etherbeep** in the game's Mods menu.

| Platform | Mods folder |
| --- | --- |
| Windows | `C:\Users\<you>\Zomboid\mods\` |
| Linux | `~/Zomboid/mods/` |
| macOS | `~/Zomboid/mods/` |

The mod is client side. In multiplayer only the people who install it hear
anything, and the server does not need it.

## Configuration

The first time the game boots with the mod enabled, it writes `Etherbeep.ini`
into your Zomboid user folder (alongside `console.txt`, in the `Lua`
sub-folder). Every option is documented in the file itself:

```ini
# Master switch. false disables the mod without uninstalling it.
enabled = true

# Sound to play. Bundled: Etherbeep_Chime, Etherbeep_Fanfare, Etherbeep_Blip, Etherbeep_Custom.
sound = Etherbeep_Chime

# Playback volume, 0.0 to 1.0. Your in-game sound sliders still apply on top of this.
volume = 0.8

# Ticks to wait after the character spawns before playing (~60 ticks = 1 second).
delayTicks = 30

# true also plays the sound every time you load an existing character, not just brand new ones.
playOnEveryLoad = false

# true prints what Etherbeep is doing to console.txt.
debug = false
```

Edit it and restart the game. Out-of-range numbers are clamped rather than
rejected, and unknown keys are ignored with a note in `console.txt`.

If you have the [Mod Options](https://steamcommunity.com/sharedfiles/filedetails/?id=2169435993)
mod installed, Etherbeep also adds a page there so the sound, volume and
switches can be changed in-game; those changes are written straight back to
`Etherbeep.ini`. Mod Options is entirely optional — without it, the `.ini` is
the only thing that matters.

### Bundled sounds

| Name | What it is |
| --- | --- |
| `Etherbeep_Chime` | Soft two-note bell. The default. |
| `Etherbeep_Fanfare` | Rising four-note arpeggio. |
| `Etherbeep_Blip` | Terse 160 ms UI blip. |
| `Etherbeep_Custom` | A copy of the chime, meant to be replaced by you. |

### Using your own sound

The quickest way: overwrite `Etherbeep/media/sound/Etherbeep_Custom.ogg` with
your own `.ogg` file, keeping the file name, and set `sound = Etherbeep_Custom`.

To add a sound under its own name instead, drop the `.ogg` into
`Etherbeep/media/sound/` and copy a block in
`Etherbeep/media/scripts/etherbeep_sounds.txt`:

```
sound MyOwnSound
{
	category = UI,
	loop = false,
	is3D = false,
	clip
	{
		file = media/sound/MyOwnSound.ogg,
		distanceMax = 30,
		volume = 1.0,
	}
}
```

Then set `sound = MyOwnSound`. The name in the `sound` line of the script is
what goes in the `.ini`, not the file name. Any sound the game already knows
works too, including vanilla ones. If the configured name cannot be played,
Etherbeep falls back to `Etherbeep_Chime` and says so in `console.txt`.

### Testing it without making a character

Bind **Options → Key Bindings → [Etherbeep] → Etherbeep: Test sound** to a key
and press it in-game to hear the current settings. It is unbound by default so
it cannot fire while you are typing. From the Lua debug console, `Etherbeep.test()`
does the same thing.

## How "new character" is decided

Two events are watched, because neither one covers every case on its own:

- `OnNewGame` fires when a new singleplayer game starts, but not in multiplayer.
- `OnCreatePlayer` fires for every character entering the world — new or loaded,
  singleplayer or multiplayer.

So `OnCreatePlayer` does the real work and treats a character as new only when
it has survived no measurable time yet (`getHoursSurvived() < 0.05`). A flag
written into the character's own mod data marks it as greeted, which stops the
sound replaying on later loads and stops the two events double-firing for the
same character. Dying and rolling a new character counts as new, which is the
point.

Playback is delayed by `delayTicks` (half a second by default) so the sound is
not swallowed by the tail end of the loading screen. The sound goes to the
player's own sound emitter, which is what allows an exact volume; if that is
unavailable it falls back to a UI sound.

## Layout

```
Etherbeep/                        the mod — this is what you copy into mods/
  mod.info
  poster.png
  media/
    scripts/etherbeep_sounds.txt  sound definitions
    sound/*.ogg                   the audio
    lua/shared/Etherbeep_Config.lua        defaults, schema, validation
    lua/client/Etherbeep_Settings.lua      reads and writes Etherbeep.ini
    lua/client/Etherbeep_Sound.lua         playback and fallbacks
    lua/client/Etherbeep_NewCharacter.lua  new-character detection
    lua/client/Etherbeep_Keybind.lua       optional test hotkey
    lua/client/Etherbeep_ModOptions.lua    optional in-game options page
tools/                            development only, not part of the mod
  generate_sounds.py              regenerates the .ogg files
  generate_poster.py              regenerates poster.png
  tests/                          Lua test suite with a stubbed PZ API
```

## Development

The bundled audio and the poster are generated, so they can be tweaked and
rebuilt:

```sh
pip install numpy soundfile
python3 tools/generate_sounds.py
python3 tools/generate_poster.py
```

The mod's Lua runs against a stubbed Project Zomboid API, which covers the
detection rules, the `.ini` round trip, volume and range clamping, fallbacks,
split screen, the hotkey and the Mod Options integration:

```sh
pip install lupa
python3 tools/tests/run.py
```

## Compatibility

Written for the Build 41 mod format (`versionMin=41.65`), the layout Build 42
still loads. Nothing here overrides a vanilla file, so it should not conflict
with other mods.

The Lua is verified against the stubbed API in `tools/tests`, not inside a
running game — the event names, sound script syntax and mod layout follow the
documented Build 41 modding API, but a first run in-game is still worth doing
with `debug = true` so `console.txt` shows what fires.
