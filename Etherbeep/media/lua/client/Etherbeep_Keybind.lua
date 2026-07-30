--[[ Etherbeep - optional key binding that previews the configured sound.

	Unbound by default, so it cannot fire while you are typing in chat. Bind it
	under Options > Key Bindings > [Etherbeep] if you want it.
]]

require "Etherbeep_Config"
require "Etherbeep_Sound"

local TEST_BINDING = "Etherbeep: Test sound"

-- keyBinding is the global table vanilla builds the key bindings screen from.
-- Guarded so a second execution of this file cannot add the entry twice.
if not Etherbeep._keybindRegistered then
	Etherbeep._keybindRegistered = true
	if keyBinding then
		local none = (Keyboard and Keyboard.KEY_NONE) or 0
		table.insert(keyBinding, { value = "[Etherbeep]" })
		table.insert(keyBinding, { value = TEST_BINDING, key = none })
	else
		Etherbeep.log("key binding table not found, the test hotkey is unavailable")
	end
end

local function onKeyPressed(key)
	local bound = getCore():getKey(TEST_BINDING)
	if not bound or bound == 0 or key ~= bound then
		return
	end
	Etherbeep.test()
end

if not Etherbeep._keybindHandler then
	Etherbeep._keybindHandler = true
	Events.OnKeyPressed.Add(onKeyPressed)
end
