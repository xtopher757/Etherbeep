--[[ Etherbeep - optional in-game settings page.

	If the Mod Options mod (Steam Workshop id 2169435993) is installed, Etherbeep
	registers a page there so the sound, volume and master switch can be changed
	without leaving the game. Changes are written straight back to Etherbeep.ini.

	Mod Options is NOT required. Without it the mod reads Etherbeep.ini as usual,
	and everything below is skipped. The whole registration runs inside pcall so
	an API change in Mod Options can never stop Etherbeep from loading.
]]

require "Etherbeep_Config"
require "Etherbeep_Settings"

local VOLUME_STEPS = { "0%", "10%", "20%", "30%", "40%", "50%", "60%", "70%", "80%", "90%", "100%" }

local function volumeToIndex(volume)
	local index = math.floor((tonumber(volume) or 0.8) * 10 + 0.5) + 1
	return math.max(1, math.min(#VOLUME_STEPS, index))
end

local function indexToVolume(index)
	return (math.max(1, math.min(#VOLUME_STEPS, tonumber(index) or 9)) - 1) / 10
end

--- The bundled sounds, plus whatever custom name is configured, so a hand
--- edited Etherbeep.ini still shows its own value in the dropdown.
local function buildSoundList()
	local list = {}
	for _, name in ipairs(Etherbeep.BUNDLED_SOUNDS) do
		table.insert(list, name)
	end

	local configured = Etherbeep.settings.sound
	local index = 1
	for i, name in ipairs(list) do
		if name == configured then
			index = i
		end
	end
	if configured and configured ~= list[index] then
		table.insert(list, configured)
		index = #list
	end
	return list, index
end

--- Read the value out of a Mod Options callback, whichever way it is handed over.
local function valueOf(option, value)
	if value ~= nil then
		return value
	end
	if type(option) == "table" then
		return option.value or option.selected
	end
	return nil
end

local function register()
	local soundList, soundIndex = buildSoundList()
	soundList.default = soundIndex

	local volumeList = {}
	for _, step in ipairs(VOLUME_STEPS) do
		table.insert(volumeList, step)
	end
	volumeList.default = volumeToIndex(Etherbeep.settings.volume)

	local config = {
		options = {
			enabled = Etherbeep.settings.enabled,
			sound = soundList,
			volume = volumeList,
			playOnEveryLoad = Etherbeep.settings.playOnEveryLoad,
		},
		names = {
			enabled = "Play a sound for new characters",
			sound = "Sound",
			volume = "Volume",
			playOnEveryLoad = "Also play when loading an existing character",
		},
		mod_id = Etherbeep.MOD_ID,
		mod_shortname = "Etherbeep",
		mod_fullname = "Etherbeep - New Character Sound",
	}

	local instance = ModOptions:getInstance(config)
	if ModOptions.loadFile then
		ModOptions:loadFile()
	end

	local function bind(key, handler)
		local option = instance:getData(key)
		if not option then
			return
		end
		local apply = function(self, value)
			handler(valueOf(self, value))
		end
		option.OnApplyInGame = apply
		option.OnApplyMainMenu = apply
	end

	bind("enabled", function(value)
		Etherbeep.setSetting("enabled", value and true or false)
	end)

	bind("playOnEveryLoad", function(value)
		Etherbeep.setSetting("playOnEveryLoad", value and true or false)
	end)

	bind("sound", function(value)
		local name = soundList[tonumber(value) or 0] or value
		Etherbeep.setSetting("sound", name)
	end)

	bind("volume", function(value)
		Etherbeep.setSetting("volume", indexToVolume(value))
	end)

	Etherbeep.debug("registered a Mod Options page")
end

local function onGameBoot()
	if not ModOptions or not ModOptions.getInstance then
		Etherbeep.debug("Mod Options not installed, using " .. Etherbeep.CONFIG_FILE .. " only")
		return
	end

	local ok, err = pcall(register)
	if not ok then
		Etherbeep.log("could not register the Mod Options page (" .. tostring(err)
			.. "). Edit " .. Etherbeep.CONFIG_FILE .. " instead.")
	end
end

-- The require above pulls in Etherbeep_Settings first, so its OnGameBoot handler
-- runs before this one and the page opens with the values from Etherbeep.ini.
if not Etherbeep._modOptionsBootHandler then
	Etherbeep._modOptionsBootHandler = true
	Events.OnGameBoot.Add(onGameBoot)
end
