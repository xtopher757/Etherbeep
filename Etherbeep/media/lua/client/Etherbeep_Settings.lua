--[[ Etherbeep - reads and writes Etherbeep.ini in the Zomboid user folder.

	The file is plain key=value text. Lines starting with # or ; are comments.
	It is created with the defaults the first time the game boots with the mod
	installed, so there is always a documented file to edit.
]]

require "Etherbeep_Config"

local function trim(text)
	return (string.gsub(text, "^%s*(.-)%s*$", "%1"))
end

local function serialize(value)
	if type(value) == "boolean" then
		return value and "true" or "false"
	end
	return tostring(value)
end

--- Read Etherbeep.ini, if it exists, into Etherbeep.settings.
--- @return boolean true when a file was found and read
function Etherbeep.loadSettings()
	local reader = getFileReader(Etherbeep.CONFIG_FILE, false)
	if not reader then
		return false
	end

	local found = 0
	local line = reader:readLine()
	while line do
		line = trim(line)
		if line ~= "" and string.sub(line, 1, 1) ~= "#" and string.sub(line, 1, 1) ~= ";" then
			local key, value = string.match(line, "^([%w_]+)%s*=%s*(.*)$")
			if key then
				-- allow trailing comments: sound = Etherbeep_Blip  # quieter
				value = trim((string.gsub(value, "%s+[#;].*$", "")))
				if Etherbeep.getSchemaEntry(key) then
					Etherbeep.settings[key] = Etherbeep.sanitize(key, value)
					found = found + 1
				else
					Etherbeep.log("ignoring unknown option '" .. key .. "' in " .. Etherbeep.CONFIG_FILE)
				end
			end
		end
		line = reader:readLine()
	end
	reader:close()

	Etherbeep.debug("loaded " .. found .. " option(s) from " .. Etherbeep.CONFIG_FILE)
	return true
end

--- Write the current settings back out, keeping the comments.
function Etherbeep.saveSettings()
	local writer = getFileWriter(Etherbeep.CONFIG_FILE, true, false)
	if not writer then
		Etherbeep.log("could not open " .. Etherbeep.CONFIG_FILE .. " for writing")
		return false
	end

	writer:write("# Etherbeep " .. Etherbeep.VERSION .. " configuration\r\n")
	writer:write("# Plays a sound when a new character is created.\r\n")
	writer:write("# Edit values below, then restart the game (or use the Mod Options menu in-game).\r\n")

	for _, entry in ipairs(Etherbeep.SCHEMA) do
		writer:write("\r\n")
		writer:write("# " .. entry.comment .. "\r\n")
		if entry.min and entry.max then
			writer:write("# range: " .. entry.min .. " to " .. entry.max
				.. " (default " .. serialize(entry.default) .. ")\r\n")
		else
			writer:write("# default: " .. serialize(entry.default) .. "\r\n")
		end
		writer:write(entry.key .. " = " .. serialize(Etherbeep.settings[entry.key]) .. "\r\n")
	end

	writer:close()
	Etherbeep.debug("wrote " .. Etherbeep.CONFIG_FILE)
	return true
end

--- Change one option and persist it.
function Etherbeep.setSetting(key, value)
	if not Etherbeep.getSchemaEntry(key) then
		Etherbeep.log("unknown option '" .. tostring(key) .. "'")
		return false
	end
	Etherbeep.settings[key] = Etherbeep.sanitize(key, value)
	Etherbeep.saveSettings()
	Etherbeep.debug(key .. " set to " .. serialize(Etherbeep.settings[key]))
	return true
end

local function onGameBoot()
	local existed = Etherbeep.loadSettings()
	if not existed then
		-- First run: leave the player a commented file they can edit.
		Etherbeep.saveSettings()
		Etherbeep.log("created " .. Etherbeep.CONFIG_FILE .. " with default settings")
	end
	Etherbeep.log("v" .. Etherbeep.VERSION .. " ready (sound="
		.. tostring(Etherbeep.settings.sound)
		.. ", volume=" .. tostring(Etherbeep.settings.volume)
		.. ", enabled=" .. serialize(Etherbeep.settings.enabled) .. ")")
end

-- Guarded: this file is both require'd by other Etherbeep files and loaded by
-- the game, so it can run twice. Only the first run registers the handler.
if not Etherbeep._settingsBootHandler then
	Etherbeep._settingsBootHandler = true
	Events.OnGameBoot.Add(onGameBoot)
end
