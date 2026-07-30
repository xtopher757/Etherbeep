-- Minimal Project Zomboid API stub so the Etherbeep Lua can be exercised
-- outside the game. Not a full emulation: just enough to drive the events and
-- observe which sounds get played.

local MOD = ROOT .. "/Etherbeep/media/lua"
local SEARCH = { MOD .. "/shared/", MOD .. "/client/" }

-- ---------------------------------------------------------------- events ----
local function makeEvent()
	local handlers = {}
	return {
		Add = function(_, fn) table.insert(handlers, fn) end,
		Remove = function(_, fn)
			for i = #handlers, 1, -1 do
				if handlers[i] == fn then table.remove(handlers, i) end
			end
		end,
		fire = function(...)
			local snapshot = {}
			for i, fn in ipairs(handlers) do snapshot[i] = fn end
			for _, fn in ipairs(snapshot) do fn(...) end
		end,
		count = function() return #handlers end,
	}
end

Events = {}
for _, name in ipairs({ "OnGameBoot", "OnTick", "OnCreatePlayer", "OnNewGame", "OnKeyPressed" }) do
	Events[name] = makeEvent()
	-- allow both Events.X.Add(fn) and Events.X:Add(fn) calling styles
	local event = Events[name]
	local rawAdd, rawRemove = event.Add, event.Remove
	event.Add = function(a, b) if b == nil then rawAdd(nil, a) else rawAdd(a, b) end end
	event.Remove = function(a, b) if b == nil then rawRemove(nil, a) else rawRemove(a, b) end end
end

-- ------------------------------------------------------------ filesystem ----
FILES = {}

function getFileReader(name, createIfMissing)
	local content = FILES[name]
	if not content then
		if createIfMissing then FILES[name] = "" ; content = "" else return nil end
	end
	local lines, position = {}, 0
	for line in string.gmatch(content .. "\n", "([^\n]*)\n") do table.insert(lines, line) end
	return {
		readLine = function()
			position = position + 1
			if position > #lines then return nil end
			return lines[position]
		end,
		close = function() end,
	}
end

function getFileWriter(name, _create, append)
	if not append then FILES[name] = "" end
	return {
		write = function(_, text) FILES[name] = (FILES[name] or "") .. text end,
		close = function() end,
	}
end

-- ----------------------------------------------------------------- sound ----
PLAYED = {}
KNOWN_SOUNDS = {
	Etherbeep_Chime = true,
	Etherbeep_Fanfare = true,
	Etherbeep_Blip = true,
	Etherbeep_Custom = true,
}

function getSoundManager()
	return {
		playUISound = function(_, name)
			if not KNOWN_SOUNDS[name] then return 0 end
			table.insert(PLAYED, { name = name, via = "ui" })
			return 1234
		end,
	}
end

function getCore()
	return { getKey = function(_, _name) return KEY_BINDING or 0 end }
end

Keyboard = { KEY_NONE = 0 }
keyBinding = {}

-- ---------------------------------------------------------------- player ----
local nextChannel = 1

function makePlayer(options)
	options = options or {}
	local modData = options.modData or {}
	local player
	local emitter = {
		playSound = function(_, name)
			if not KNOWN_SOUNDS[name] then return 0 end
			nextChannel = nextChannel + 1
			table.insert(PLAYED, { name = name, via = "emitter", channel = nextChannel, player = player })
			return nextChannel
		end,
		setVolume = function(_, channel, volume)
			for _, entry in ipairs(PLAYED) do
				if entry.channel == channel then entry.volume = volume end
			end
		end,
	}
	player = {
		getModData = function() return modData end,
		getPlayerNum = function() return options.playerNum or 0 end,
		getHoursSurvived = function() return options.hours or 0 end,
		isDead = function() return options.dead or false end,
		getEmitter = function() return emitter end,
	}
	return player
end

CURRENT_PLAYER = nil
function getSpecificPlayer(_index) return CURRENT_PLAYER end

-- --------------------------------------------------------------- loading ----
local loaded = {}
local realDofile = dofile

function require(name)
	if loaded[name] then return loaded[name] end
	loaded[name] = true
	for _, dir in ipairs(SEARCH) do
		local path = dir .. name .. ".lua"
		local handle = io.open(path, "r")
		if handle then
			handle:close()
			realDofile(path)
			return true
		end
	end
	error("stub require: cannot find " .. name)
end

--- Load every mod file the way the game would: shared first, then client,
--- alphabetically within each folder.
function loadMod()
	local files = {
		"shared/Etherbeep_Config",
		"client/Etherbeep_Keybind",
		"client/Etherbeep_ModOptions",
		"client/Etherbeep_NewCharacter",
		"client/Etherbeep_Settings",
		"client/Etherbeep_Sound",
	}
	for _, relative in ipairs(files) do
		local short = string.match(relative, "/(.+)$")
		if not loaded[short] then
			loaded[short] = true
			realDofile(MOD .. "/" .. relative .. ".lua")
		end
	end
end

function tick(times)
	for _ = 1, (times or 1) do Events.OnTick.fire() end
end

function resetPlayed() PLAYED = {} end
