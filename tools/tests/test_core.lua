dofile(TESTS .. "/harness.lua")

local failures, passes = 0, 0

local function check(name, condition, detail)
	if condition then
		passes = passes + 1
		print("  ok   " .. name)
	else
		failures = failures + 1
		print("  FAIL " .. name .. (detail and ("  -> " .. tostring(detail)) or ""))
	end
end

local function lastPlayed()
	return PLAYED[#PLAYED]
end

print("== load and boot ==")
loadMod()
Events.OnGameBoot.fire()
check("config file created on first boot", FILES["Etherbeep.ini"] ~= nil)
check("ini contains the sound key", string.find(FILES["Etherbeep.ini"] or "", "sound = Etherbeep_Chime", 1, true) ~= nil)
check("defaults applied", Etherbeep.settings.enabled == true and Etherbeep.settings.volume == 0.8)
check("keybinding registered once", #keyBinding == 2, #keyBinding)

print("== new character in singleplayer ==")
resetPlayed()
local fresh = makePlayer({ hours = 0 })
CURRENT_PLAYER = fresh
Events.OnCreatePlayer.fire(0, fresh)
Events.OnNewGame.fire(fresh, nil)
check("nothing plays before the delay", #PLAYED == 0, #PLAYED)
tick(29)
check("still quiet at 29 ticks", #PLAYED == 0, #PLAYED)
tick(1)
check("plays once at 30 ticks", #PLAYED == 1, #PLAYED)
check("used the configured sound", lastPlayed() and lastPlayed().name == "Etherbeep_Chime")
check("played on the player emitter", lastPlayed() and lastPlayed().via == "emitter")
check("volume applied", lastPlayed() and lastPlayed().volume == 0.8, lastPlayed() and lastPlayed().volume)
check("character marked as greeted", fresh:getModData().EtherbeepGreeted == true)
tick(120)
check("does not repeat afterwards", #PLAYED == 1, #PLAYED)

print("== reloading that same character ==")
resetPlayed()
local reloaded = makePlayer({ hours = 12.5, modData = fresh:getModData() })
CURRENT_PLAYER = reloaded
Events.OnCreatePlayer.fire(0, reloaded)
tick(120)
check("stays silent for an existing character", #PLAYED == 0, #PLAYED)

print("== new character with survival time unavailable ==")
resetPlayed()
local mpChar = makePlayer({ hours = 0, playerNum = 0 })
CURRENT_PLAYER = mpChar
Events.OnCreatePlayer.fire(0, mpChar)  -- multiplayer path: no OnNewGame at all
tick(30)
check("multiplayer style creation still plays", #PLAYED == 1, #PLAYED)

print("== quit right after creation, then reload ==")
resetPlayed()
local quick = makePlayer({ hours = 0.01, modData = mpChar:getModData() })
CURRENT_PLAYER = quick
Events.OnCreatePlayer.fire(0, quick)
tick(30)
check("greeted flag beats the low survival time", #PLAYED == 0, #PLAYED)

print("== settings changes ==")
resetPlayed()
Etherbeep.setSetting("sound", "Etherbeep_Fanfare")
Etherbeep.setSetting("volume", 0.3)
Etherbeep.setSetting("delayTicks", 0)
local another = makePlayer({ hours = 0 })
CURRENT_PLAYER = another
Events.OnNewGame.fire(another, nil)
check("zero delay plays immediately", #PLAYED == 1, #PLAYED)
check("honours the new sound", lastPlayed() and lastPlayed().name == "Etherbeep_Fanfare")
check("honours the new volume", lastPlayed() and lastPlayed().volume == 0.3, lastPlayed() and lastPlayed().volume)
check("settings persisted to the ini",
	string.find(FILES["Etherbeep.ini"] or "", "sound = Etherbeep_Fanfare", 1, true) ~= nil)

print("== volume and range clamping ==")
Etherbeep.setSetting("volume", 5)
check("volume clamped to 1.0", Etherbeep.settings.volume == 1.0, Etherbeep.settings.volume)
Etherbeep.setSetting("volume", -2)
check("volume clamped to 0.0", Etherbeep.settings.volume == 0.0, Etherbeep.settings.volume)
Etherbeep.setSetting("delayTicks", 99999)
check("delay clamped to 600", Etherbeep.settings.delayTicks == 600, Etherbeep.settings.delayTicks)
Etherbeep.setSetting("enabled", "yes")
check("boolean parsed from text", Etherbeep.settings.enabled == true)

print("== muted and disabled ==")
resetPlayed()
Etherbeep.setSetting("volume", 0)
Etherbeep.setSetting("delayTicks", 0)
CURRENT_PLAYER = makePlayer({ hours = 0 })
Events.OnNewGame.fire(CURRENT_PLAYER, nil)
check("volume 0 plays nothing", #PLAYED == 0, #PLAYED)

Etherbeep.setSetting("volume", 0.8)
Etherbeep.setSetting("enabled", false)
CURRENT_PLAYER = makePlayer({ hours = 0 })
Events.OnNewGame.fire(CURRENT_PLAYER, nil)
Events.OnCreatePlayer.fire(0, CURRENT_PLAYER)
tick(5)
check("disabled plays nothing", #PLAYED == 0, #PLAYED)
Etherbeep.setSetting("enabled", true)

print("== unknown sound name falls back ==")
resetPlayed()
Etherbeep.setSetting("sound", "ThisSoundDoesNotExist")
CURRENT_PLAYER = makePlayer({ hours = 0 })
Events.OnNewGame.fire(CURRENT_PLAYER, nil)
check("fell back to the bundled chime", #PLAYED == 1 and lastPlayed().name == "Etherbeep_Chime",
	lastPlayed() and lastPlayed().name)
Etherbeep.setSetting("sound", "Etherbeep_Chime")

print("== playOnEveryLoad ==")
resetPlayed()
Etherbeep.setSetting("playOnEveryLoad", true)
local veteran = makePlayer({ hours = 300 })
CURRENT_PLAYER = veteran
Events.OnCreatePlayer.fire(0, veteran)
check("plays for an old character when asked to", #PLAYED == 1, #PLAYED)
Etherbeep.setSetting("playOnEveryLoad", false)

print("== ini round trip ==")
FILES["Etherbeep.ini"] = table.concat({
	"# hand edited",
	"enabled = false",
	"sound = Etherbeep_Blip   # trailing comment",
	"volume = 0.45",
	"delayTicks = 5",
	"bogusKey = 3",
	"",
}, "\n")
Etherbeep.loadSettings()
check("reads booleans", Etherbeep.settings.enabled == false)
check("strips trailing comments", Etherbeep.settings.sound == "Etherbeep_Blip", Etherbeep.settings.sound)
check("reads floats", Etherbeep.settings.volume == 0.45, Etherbeep.settings.volume)
check("reads ints", Etherbeep.settings.delayTicks == 5)

print("== split screen ==")
resetPlayed()
Etherbeep.setSetting("enabled", true)
Etherbeep.setSetting("delayTicks", 10)
local one = makePlayer({ hours = 0, playerNum = 0 })
local two = makePlayer({ hours = 0, playerNum = 1 })
CURRENT_PLAYER = one
Events.OnCreatePlayer.fire(0, one)
Events.OnCreatePlayer.fire(1, two)
tick(10)
check("both local characters get a sound", #PLAYED == 2, #PLAYED)

print("== test hotkey ==")
resetPlayed()
KEY_BINDING = 0
Events.OnKeyPressed.fire(0)
check("unbound key does nothing", #PLAYED == 0, #PLAYED)
KEY_BINDING = 42
CURRENT_PLAYER = one
Events.OnKeyPressed.fire(42)
check("bound key previews the sound", #PLAYED == 1, #PLAYED)
Events.OnKeyPressed.fire(41)
check("other keys ignored", #PLAYED == 1, #PLAYED)

print("== OnTick handler is cleaned up ==")
resetPlayed()
local before = Events.OnTick.count()
CURRENT_PLAYER = makePlayer({ hours = 0 })
Events.OnNewGame.fire(CURRENT_PLAYER, nil)
tick(15)
check("tick handler removed once the queue drains", Events.OnTick.count() == before,
	Events.OnTick.count() .. " vs " .. before)

print("")
print(string.format("%d passed, %d failed", passes, failures))
if failures > 0 then os.exit(1) end
