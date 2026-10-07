-------------------------------------------------------------------------------
-- Siege AI, step 1 (test build): prove that a mod script runs in every battle.
--
-- 60 seconds after deployment ends, every AI unit is handed to the game's own AI
-- planner with one order: attack the player's army. script_ai_planner:attack_force
-- re-aims at the nearest player unit every 15 seconds.
--
-- Visible test: in a custom siege where the AI DEFENDS, its units leave the city and
-- come at you about one minute in. Unmodded Attila defenders hold the city centre.
-- Not for real play: it also pushes AI defenders out of their cities.
-------------------------------------------------------------------------------

local PUSH_DELAY_MS = 60000

-- the battle script library expects this path (see lua_scripts/battle_script_header.lua)
package.path = package.path .. ";data/?.lua"
require "lua_scripts.Battle_Script_Header"

local bm = battle_manager:new(empire_battle:new())

-- never take over units in multiplayer, where the other side is a human
local function is_multiplayer()
	local ok, result = pcall(function() return bm.battle:is_multiplayer() end)
	return ok and result == true
end

local function sunits_of(alliance)
	local list = {}
	local armies = alliance:armies()
	for a = 1, armies:count() do
		local army = armies:item(a)
		for u = 1, army:units():count() do
			local su = script_unit:new(army, u)
			if is_scriptunit(su) then
				table.insert(list, su)
			end
		end
	end
	return list
end

local function push_ai()
	if is_multiplayer() then
		bm:out("[siege_ai] multiplayer battle, doing nothing")
		return
	end
	local alliances = bm:alliances()
	local player_num = bm:local_alliance()
	local ai_num = (player_num == 1) and 2 or 1
	local ai_units = sunits_of(alliances:item(ai_num))
	local player_units = sunits_of(alliances:item(player_num))
	bm:out("[siege_ai] pushing " .. #ai_units .. " AI units at " .. #player_units .. " player units")
	if #ai_units == 0 or #player_units == 0 then
		return
	end
	local planner = script_ai_planner:new("siege_ai_push", ai_units)
	if planner then
		planner:attack_force(player_units)
	end
end

bm:register_phase_change_callback("Deployed", function()
	bm:callback(push_ai, PUSH_DELAY_MS, "siege_ai_push")
end)

bm:out("[siege_ai] step 1 loaded: AI pushes " .. PUSH_DELAY_MS / 1000 .. " s after deployment")
