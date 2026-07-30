--[[ Etherbeep - decides when a character is brand new.

	Two events are watched because neither one covers every case:

	  OnNewGame       fires when a new singleplayer game starts. Clean signal,
	                  but it does not fire for multiplayer characters.
	  OnCreatePlayer  fires for every character that enters the world, new or
	                  loaded, in singleplayer and multiplayer alike.

	So OnCreatePlayer does the real work and only treats a character as new when
	it has survived no measurable time yet, and a flag stored in the character's
	own mod data keeps the sound from replaying every time that save is loaded.
	Whichever event arrives first wins; the other is ignored.
]]

require "Etherbeep_Config"
require "Etherbeep_Sound"

local MOD_DATA_FLAG = "EtherbeepGreeted"
-- A freshly created character has survived 0 hours. Anything under this counts
-- as new, which also covers a save that was quit seconds after creation.
local NEW_CHARACTER_HOURS = 0.05

--- Characters waiting out their delay before the sound plays.
local pending = {}

local function isPending(playerNum)
	for _, entry in ipairs(pending) do
		if entry.playerNum == playerNum then
			return true
		end
	end
	return false
end

local function onTick()
	for index = #pending, 1, -1 do
		local entry = pending[index]
		entry.ticks = entry.ticks - 1
		if entry.ticks <= 0 then
			table.remove(pending, index)
			local player = entry.player
			if player and not player:isDead() then
				Etherbeep.playSound(nil, nil, player)
			else
				Etherbeep.debug("skipped playback, player " .. entry.playerNum .. " is gone")
			end
		end
	end

	if #pending == 0 then
		Events.OnTick.Remove(onTick)
	end
end

--- Queue the sound for a character, after the configured delay.
local function schedule(player, reason)
	local playerNum = player:getPlayerNum()
	if isPending(playerNum) then
		Etherbeep.debug("already queued for player " .. playerNum .. ", ignoring " .. reason)
		return
	end

	local delay = Etherbeep.settings.delayTicks or 0
	Etherbeep.debug("queued sound for player " .. playerNum
		.. " via " .. reason .. " (delay " .. delay .. " ticks)")

	if delay <= 0 then
		Etherbeep.playSound(nil, nil, player)
		return
	end

	if #pending == 0 then
		Events.OnTick.Add(onTick)
	end
	table.insert(pending, { player = player, playerNum = playerNum, ticks = delay })
end

--- True when this character has never been greeted and looks freshly made.
local function isNewCharacter(player)
	local modData = player:getModData()
	if modData[MOD_DATA_FLAG] then
		return false
	end

	local hours = 0
	local ok, survived = pcall(function() return player:getHoursSurvived() end)
	if ok and survived then
		hours = survived
	end
	return hours < NEW_CHARACTER_HOURS
end

local function greet(player, reason)
	if not Etherbeep.settings.enabled then
		Etherbeep.debug("disabled, ignoring " .. reason)
		return
	end
	if not player then
		return
	end

	-- Mark first: the flag is what stops OnNewGame and OnCreatePlayer from both
	-- firing for the same character, and stops a replay on the next load.
	player:getModData()[MOD_DATA_FLAG] = true
	schedule(player, reason)
end

local function onCreatePlayer(playerIndex, player)
	if not player then
		return
	end

	if Etherbeep.settings.playOnEveryLoad then
		if Etherbeep.settings.enabled then
			player:getModData()[MOD_DATA_FLAG] = true
			schedule(player, "OnCreatePlayer (playOnEveryLoad)")
		end
		return
	end

	if isNewCharacter(player) then
		greet(player, "OnCreatePlayer")
	else
		Etherbeep.debug("player " .. tostring(playerIndex) .. " is an existing character, staying quiet")
	end
end

local function onNewGame(player, _square)
	greet(player, "OnNewGame")
end

if not Etherbeep._newCharacterHandlers then
	Etherbeep._newCharacterHandlers = true
	Events.OnCreatePlayer.Add(onCreatePlayer)
	Events.OnNewGame.Add(onNewGame)
end
