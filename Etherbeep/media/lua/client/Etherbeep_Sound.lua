--[[ Etherbeep - sound playback.

	Two ways to make noise, tried in order:

	1. The player's own sound emitter. This is the good path: it returns a
	   channel we can set an exact volume on.
	2. getSoundManager():playUISound(). Works with no player in the world (main
	   menu, keybind test) but follows the in-game UI volume slider only.

	If the configured sound name does not exist, we fall back through the
	bundled chime so a typo in Etherbeep.ini is never silent-with-no-explanation.
]]

require "Etherbeep_Config"

local FALLBACK_SOUND = "Etherbeep_Chime"

local function playOnEmitter(player, soundName, volume)
	if not player then
		return false
	end

	local ok, channel = pcall(function()
		local emitter = player:getEmitter()
		if not emitter then
			return nil
		end
		return emitter:playSound(soundName)
	end)

	if not ok or not channel or channel == 0 then
		return false
	end

	-- Best effort: some builds ignore per-channel volume for 2D sounds.
	pcall(function()
		player:getEmitter():setVolume(channel, volume)
	end)
	return true
end

local function playAsUISound(soundName)
	local ok, channel = pcall(function()
		local manager = getSoundManager()
		if not manager then
			return nil
		end
		return manager:playUISound(soundName)
	end)
	return ok and channel ~= nil and channel ~= 0
end

--- Play a sound by name, ignoring the "enabled" switch.
--- @param soundName string|nil defaults to the configured sound
--- @param volume number|nil defaults to the configured volume
--- @param player IsoPlayer|nil defaults to player 0
--- @return boolean whether anything was played
function Etherbeep.playSound(soundName, volume, player)
	soundName = soundName or Etherbeep.settings.sound or FALLBACK_SOUND
	volume = volume or Etherbeep.settings.volume or 1.0
	if player == nil then
		player = getSpecificPlayer(0)
	end

	if volume <= 0 then
		Etherbeep.debug("volume is 0, not playing")
		return false
	end

	local candidates = { soundName }
	if soundName ~= FALLBACK_SOUND then
		table.insert(candidates, FALLBACK_SOUND)
	end

	for index, candidate in ipairs(candidates) do
		if index > 1 then
			Etherbeep.log("sound '" .. tostring(candidates[index - 1])
				.. "' could not be played, falling back to '" .. candidate .. "'")
		end
		if playOnEmitter(player, candidate, volume) then
			Etherbeep.debug("played '" .. candidate .. "' on the player emitter at volume " .. tostring(volume))
			return true
		end
		if playAsUISound(candidate) then
			Etherbeep.debug("played '" .. candidate .. "' as a UI sound")
			return true
		end
	end

	Etherbeep.log("failed to play any sound (tried '" .. table.concat(candidates, "', '") .. "')")
	return false
end

--- Preview the configured sound. Bound to a key and callable from the Lua
--- debug console as: Etherbeep.test()
function Etherbeep.test()
	Etherbeep.log("testing sound '" .. tostring(Etherbeep.settings.sound)
		.. "' at volume " .. tostring(Etherbeep.settings.volume))
	return Etherbeep.playSound()
end
