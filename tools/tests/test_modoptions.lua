dofile(TESTS .. "/harness.lua")

local failures, passes = 0, 0
local function check(name, cond, detail)
	if cond then
		passes = passes + 1
		print("  ok   " .. name)
	else
		failures = failures + 1
		print("  FAIL " .. name .. (detail and ("  -> " .. tostring(detail)) or ""))
	end
end

-- Stub of the Mod Options API. One shared data table so the callbacks the mod
-- binds stay reachable from the test.
local registered, DATA = nil, {}
ModOptions = {
	getInstance = function(_, config)
		registered = config
		for key in pairs(config.options) do
			DATA[key] = DATA[key] or {}
		end
		return { getData = function(_, key) return DATA[key] end }
	end,
	loadFile = function() end,
}

print("== Mod Options page ==")
loadMod()
Events.OnGameBoot.fire()
check("page registered", registered ~= nil)
check("mod id passed through", registered and registered.mod_id == "Etherbeep")
check("sound dropdown starts with the bundled sounds", registered and registered.options.sound[1] == "Etherbeep_Chime")
check("dropdown points at the configured sound", registered and registered.options.sound.default == 1,
	registered and registered.options.sound.default)
check("volume list has 11 steps", registered and #registered.options.volume == 11)
check("volume defaults to 80%", registered and registered.options.volume.default == 9,
	registered and registered.options.volume.default)
check("every option has a label",
	registered and registered.names.enabled and registered.names.sound
	and registered.names.volume and registered.names.playOnEveryLoad)
check("callbacks bound", DATA.sound and DATA.sound.OnApplyInGame ~= nil and DATA.volume.OnApplyMainMenu ~= nil)

print("== applying changes from the options screen ==")
DATA.sound.OnApplyInGame(DATA.sound, 2)
check("sound index maps to a name", Etherbeep.settings.sound == "Etherbeep_Fanfare", Etherbeep.settings.sound)
DATA.volume.OnApplyInGame(DATA.volume, 4)
check("volume index maps to a fraction", Etherbeep.settings.volume == 0.3, Etherbeep.settings.volume)
DATA.enabled.OnApplyInGame(DATA.enabled, false)
check("switch applies", Etherbeep.settings.enabled == false)
check("changes reached the ini",
	string.find(FILES["Etherbeep.ini"] or "", "sound = Etherbeep_Fanfare", 1, true) ~= nil)

-- Some Mod Options versions put the value on the option instead of passing it.
DATA.sound.value = 3
DATA.sound.OnApplyMainMenu(DATA.sound)
check("value read off the option when no argument is given",
	Etherbeep.settings.sound == "Etherbeep_Blip", Etherbeep.settings.sound)

print("== a broken Mod Options cannot break the mod ==")
Etherbeep._modOptionsBootHandler = nil
ModOptions = { getInstance = function() error("simulated API change") end }
local ok = pcall(function() dofile(ROOT .. "/Etherbeep/media/lua/client/Etherbeep_ModOptions.lua") end)
check("file still loads", ok)
Events.OnGameBoot.fire()
resetPlayed()
Etherbeep.setSetting("enabled", true)
Etherbeep.setSetting("delayTicks", 0)
Etherbeep.setSetting("sound", "Etherbeep_Chime")
CURRENT_PLAYER = makePlayer({ hours = 0 })
Events.OnNewGame.fire(CURRENT_PLAYER, nil)
check("sound still plays after a Mod Options failure", #PLAYED == 1, #PLAYED)

print("== files loaded twice ==")
local keyBindsBefore = #keyBinding
resetPlayed()
for _, relative in ipairs({
	"shared/Etherbeep_Config", "client/Etherbeep_Keybind", "client/Etherbeep_NewCharacter",
	"client/Etherbeep_Settings", "client/Etherbeep_Sound",
}) do
	dofile(ROOT .. "/Etherbeep/media/lua/" .. relative .. ".lua")
end
check("no duplicate key binding entries", #keyBinding == keyBindsBefore, #keyBinding)
check("reloading the config file restores the defaults", Etherbeep.settings.delayTicks == 30,
	Etherbeep.settings.delayTicks)
-- The game fires OnGameBoot after every file has loaded, so the ini wins again.
Events.OnGameBoot.fire()
check("boot reload restores the saved settings", Etherbeep.settings.sound == "Etherbeep_Chime",
	Etherbeep.settings.sound)
CURRENT_PLAYER = makePlayer({ hours = 0 })
Events.OnNewGame.fire(CURRENT_PLAYER, nil)
Events.OnCreatePlayer.fire(0, CURRENT_PLAYER)
tick(Etherbeep.settings.delayTicks + 1)
check("still exactly one sound per character", #PLAYED == 1, #PLAYED)

print("")
print(string.format("%d passed, %d failed", passes, failures))
if failures > 0 then os.exit(1) end
