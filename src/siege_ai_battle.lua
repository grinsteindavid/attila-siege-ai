-------------------------------------------------------------------------------
-- Siege AI, step 1b (test build): a mod script that runs in every battle.
--
-- 60 seconds after deployment ends, every AI unit is handed to the game's own AI
-- planner with one order: attack the player's army. script_ai_planner:attack_force
-- re-aims at the nearest player unit every 15 seconds.
-- Every 20 seconds after that, units that arrived since (reinforcements) are added
-- and the order is given again. Step 1 grabbed units once and missed reinforcements.
--
-- Not for real play when YOU attack: it also pushes AI defenders out of their cities.
-------------------------------------------------------------------------------

local PUSH_DELAY_MS = 60000
local RESCAN_MS = 20000

-- the battle script library expects this path (see lua_scripts/battle_script_header.lua)
package.path = package.path .. ";data/?.lua"
require "lua_scripts.Battle_Script_Header"

local bm = battle_manager:new(empire_battle:new())

-- never take over units in multiplayer, where the other side is a human
local function is_multiplayer()
	local ok, result = pcall(function() return bm.battle:is_multiplayer() end)
	return ok and result == true
end

-- script units are created once per unit and cached, so rescans don't pile up controllers
local sunit_cache = {}

-- every unit of an alliance, including reinforcements (same as CA's generated_army:build_sunits)
local function sunits_of(alliance_num)
	local list = {}
	local armies = bm:alliances():item(alliance_num):armies()
	for a = 1, armies:count() do
		local army = armies:item(a)
		local count = army:units():count()
		local r_units = army:get_reinforcement_units()
		if is_units(r_units) then
			count = count + r_units:count()
		end
		for u = 1, count do
			local key = alliance_num .. ":" .. a .. ":" .. u
			if sunit_cache[key] == nil then
				local su = script_unit:new(army, u)
				sunit_cache[key] = is_scriptunit(su) and su or false
			end
			if sunit_cache[key] then
				table.insert(list, sunit_cache[key])
			end
		end
	end
	return list
end

local planner = nil

local function push_ai()
	if is_multiplayer() then
		bm:out("[siege_ai] multiplayer battle, doing nothing")
		return
	end
	local player_num = bm:local_alliance()
	local ai_num = (player_num == 1) and 2 or 1
	local ai_units = sunits_of(ai_num)
	local player_units = sunits_of(player_num)
	if #ai_units == 0 or #player_units == 0 then
		return
	end
	local joined = 0
	if planner == nil then
		planner = script_ai_planner:new("siege_ai_push", ai_units)
		if not planner then
			return
		end
		joined = #planner.sunit_list
	else
		local before = #planner.sunit_list
		planner:add_sunits(ai_units)  -- skips units it already controls
		joined = #planner.sunit_list - before
	end
	-- re-order only when units joined, so units already climbing aren't interrupted;
	-- the planner re-aims everyone at the nearest player unit every 15 s on its own
	if joined > 0 then
		bm:out("[siege_ai] " .. joined .. " AI units joined, ordering attack on " .. #player_units .. " player units")
		planner:attack_force(player_units)
	end
	bm:callback(push_ai, RESCAN_MS, "siege_ai_rescan")
end

bm:register_phase_change_callback("Deployed", function()
	bm:callback(push_ai, PUSH_DELAY_MS, "siege_ai_push")
end)

bm:out("[siege_ai] step 1b loaded: AI pushes " .. PUSH_DELAY_MS / 1000 .. " s after deployment, rescans every " .. RESCAN_MS / 1000 .. " s")
