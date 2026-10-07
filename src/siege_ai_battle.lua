-------------------------------------------------------------------------------
-- Siege AI, step 1c (test build): a mod script that runs in every battle.
--
-- 60 seconds after deployment ends, every AI unit gets its OWN attack order: go for
-- the player unit nearest to it (script_ai_planner:attack_force, which re-aims every
-- 15 seconds and when its target routs). Every 20 seconds after that, units that
-- arrived since (reinforcements) get their own order too.
--
-- History: step 1 grabbed units once and missed reinforcements (fixed in 1b).
-- Steps 1 and 1b used ONE planner for the whole army; attack_force picks a single
-- target for a planner, so the whole army walked to one player unit and queued (1c).
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
-- returns a list of { key = "alliance:army:unit", su = script_unit }
local function units_of(alliance_num)
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
			local key = alliance_num .. "_" .. a .. "_" .. u
			if sunit_cache[key] == nil then
				local su = script_unit:new(army, u)
				sunit_cache[key] = is_scriptunit(su) and su or false
			end
			if sunit_cache[key] then
				table.insert(list, { key = key, su = sunit_cache[key] })
			end
		end
	end
	return list
end

local planners = {}        -- one planner per AI unit, by key
local player_targets = {}  -- shared target list; planners keep a reference, so new player units appear for all
local targeted = {}

local function push_ai()
	if is_multiplayer() then
		bm:out("[siege_ai] multiplayer battle, doing nothing")
		return
	end
	local player_num = bm:local_alliance()
	local ai_num = (player_num == 1) and 2 or 1

	for _, entry in ipairs(units_of(player_num)) do
		if not targeted[entry.key] then
			targeted[entry.key] = true
			table.insert(player_targets, entry.su)
		end
	end
	if #player_targets == 0 then
		return
	end

	local joined = 0
	for _, entry in ipairs(units_of(ai_num)) do
		if planners[entry.key] == nil then
			local planner = script_ai_planner:new("siege_ai_" .. entry.key, { entry.su })
			planners[entry.key] = planner or false
			if planner then
				planner:attack_force(player_targets)
				joined = joined + 1
			end
		end
	end
	if joined > 0 then
		bm:out("[siege_ai] " .. joined .. " AI units given their own attack order")
	end
	bm:callback(push_ai, RESCAN_MS, "siege_ai_rescan")
end

bm:register_phase_change_callback("Deployed", function()
	bm:callback(push_ai, PUSH_DELAY_MS, "siege_ai_push")
end)

bm:out("[siege_ai] step 1c loaded: per-unit attack orders " .. PUSH_DELAY_MS / 1000 .. " s after deployment, rescans every " .. RESCAN_MS / 1000 .. " s")
