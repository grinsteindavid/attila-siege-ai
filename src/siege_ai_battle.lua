-------------------------------------------------------------------------------
-- Siege AI, step 1d (test build): a mod script that runs in every battle.
--
-- Orders are the same as 1c: 60 seconds after deployment ends, every AI unit gets
-- its OWN attack order: go for the player unit nearest to it
-- (script_ai_planner:attack_force, which re-aims every 15 seconds and when its
-- target routs). Every 20 seconds after that, units that arrived since
-- (reinforcements) get their own order too.
--
-- New in 1d: a log file, siege_ai_log.txt, recording whether the script loaded,
-- every order given, where every AI unit stands every 20 s and how far it is from
-- the nearest player unit, and any Lua error. CA's own scripts never write files,
-- so every logging step may fail; the battle script carries on without it.
--
-- History: step 1 grabbed units once and missed reinforcements (fixed in 1b).
-- Steps 1 and 1b used ONE planner for the whole army; attack_force picks a single
-- target for a planner, so the whole army walked to one player unit and queued (1c).
--
-- Not for real play when YOU attack: it also pushes AI defenders out of their cities.
-------------------------------------------------------------------------------

local PUSH_DELAY_MS = 60000
local RESCAN_MS = 20000
local LOG_NAME = "siege_ai_log.txt"
local MAX_ERRORS = 5

-- the battle script library expects this path (see lua_scripts/battle_script_header.lua)
package.path = package.path .. ";data/?.lua"
require "lua_scripts.Battle_Script_Header"

local bm = battle_manager:new(empire_battle:new())

-------------------------------------------------------------------------------
-- log file
-------------------------------------------------------------------------------

local log_file, log_path = nil, nil

local function open_log()
	local candidates = {}
	local ok_home, home = pcall(function() return os.getenv("HOME") end)
	if ok_home and type(home) == "string" and home ~= "" then
		table.insert(candidates, home .. "/Library/Application Support/Feral Interactive/Total War ATTILA/" .. LOG_NAME)
		table.insert(candidates, home .. "/" .. LOG_NAME)
	end
	table.insert(candidates, LOG_NAME)
	for _, path in ipairs(candidates) do
		local ok, f = pcall(function() return io.open(path, "a") end)
		if ok and f then
			log_file, log_path = f, path
			return
		end
	end
end
open_log()

local function log(msg)
	bm:out("[siege_ai] " .. msg)
	if log_file then
		pcall(function()
			log_file:write("<" .. tostring(timestamp_tick) .. "ms> " .. msg .. "\n")
			log_file:flush()
		end)
	end
end

-------------------------------------------------------------------------------
-- units
-------------------------------------------------------------------------------

-- never take over units in multiplayer, where the other side is a human
-- returns: is_multiplayer, whether the check itself could run
local function is_multiplayer()
	local ok, result = pcall(function() return bm.battle:is_multiplayer() end)
	return ok and result == true, ok
end

-- script units are created once per unit and cached, so rescans don't pile up controllers
local sunit_cache = {}

-- every unit of an alliance, including reinforcements (same as CA's generated_army:build_sunits)
-- returns a list of { key = "alliance_army_unit", su = script_unit }
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

local function describe(su)
	local ok, text = pcall(function()
		local p = su.unit:position()
		local state = is_routing_or_dead(su.unit) and " ROUTING/DEAD" or ""
		return string.format("%s at (%.0f, %.0f)%s", tostring(su.name), p:get_x(), p:get_z(), state)
	end)
	return ok and text or (tostring(su and su.name) .. " (position unavailable)")
end

local function battle_summary()
	local ok, text = pcall(function()
		local parts = {}
		local alliances = bm:alliances()
		for i = 1, alliances:count() do
			local armies = alliances:item(i):armies()
			local units, reinforcing = 0, 0
			for a = 1, armies:count() do
				local army = armies:item(a)
				units = units + army:units():count()
				local r_units = army:get_reinforcement_units()
				if is_units(r_units) then
					reinforcing = reinforcing + r_units:count()
				end
			end
			table.insert(parts, string.format("alliance %d: %d armies, %d units + %d reinforcing", i, armies:count(), units, reinforcing))
		end
		return "local alliance " .. tostring(bm:local_alliance()) .. "; " .. table.concat(parts, "; ")
	end)
	return ok and text or ("battle summary unavailable: " .. tostring(text))
end

-------------------------------------------------------------------------------
-- the push
-------------------------------------------------------------------------------

local planners = {}        -- one planner per AI unit, by key
local player_targets = {}  -- shared target list; planners keep a reference, so new player units appear for all
local targeted = {}

local function nearest_target_distance(su)
	local best = nil
	for _, target in ipairs(player_targets) do
		if not is_routing_or_dead(target.unit) then
			local d = su.unit:position():distance(target.unit:position())
			if best == nil or d < best then
				best = d
			end
		end
	end
	return best
end

local function log_status(ai_entries)
	local standing = 0
	for _, entry in ipairs(ai_entries) do
		if not is_routing_or_dead(entry.su.unit) then
			standing = standing + 1
		end
	end
	log(string.format("status: %d AI units, %d standing; %d player targets", #ai_entries, standing, #player_targets))
	for _, entry in ipairs(ai_entries) do
		local planner = planners[entry.key]
		local target = planner and planner.current_target
		local ok, d = pcall(nearest_target_distance, entry.su)
		log(string.format("  %s %s | nearest player %s | target %s",
			entry.key, describe(entry.su),
			(ok and d) and string.format("%.0f m", d) or "n/a",
			target and tostring(target.name) or "none"))
	end
end

-- returns false to stop rescanning
local function push_ai()
	local mp, mp_check_ran = is_multiplayer()
	if mp then
		log("multiplayer battle, doing nothing")
		return false
	end
	local player_num = bm:local_alliance()
	local ai_num = (player_num == 1) and 2 or 1

	for _, entry in ipairs(units_of(player_num)) do
		if not targeted[entry.key] then
			targeted[entry.key] = true
			table.insert(player_targets, entry.su)
		end
	end

	local ai_entries = units_of(ai_num)
	if #player_targets > 0 then
		for _, entry in ipairs(ai_entries) do
			if planners[entry.key] == nil then
				local planner = script_ai_planner:new("siege_ai_" .. entry.key, { entry.su })
				planners[entry.key] = planner or false
				if planner then
					planner:attack_force(player_targets)
					local target = planner.current_target
					log("order: " .. entry.key .. " " .. describe(entry.su) .. " -> " .. (target and describe(target) or "no target"))
				else
					log("order FAILED: could not create planner for " .. entry.key .. " " .. describe(entry.su))
				end
			end
		end
	end
	log_status(ai_entries)
	if not mp_check_ran then
		log("note: multiplayer check could not run in this battle")
	end
	return true
end

local error_count = 0

local function push_ai_safe()
	local ok, result = pcall(push_ai)
	if not ok then
		error_count = error_count + 1
		log("ERROR " .. error_count .. "/" .. MAX_ERRORS .. ": " .. tostring(result))
		if error_count >= MAX_ERRORS then
			log("too many errors, stopping")
			return
		end
	elseif result == false then
		return
	end
	bm:callback(push_ai_safe, RESCAN_MS, "siege_ai_rescan")
end

bm:register_phase_change_callback("Deployment", function()
	log("phase: Deployment")
end)

bm:register_phase_change_callback("Deployed", function()
	log("phase: Deployed; first push in " .. PUSH_DELAY_MS / 1000 .. " s; " .. battle_summary())
	bm:callback(push_ai_safe, PUSH_DELAY_MS, "siege_ai_push")
end)

log("==== step 1d loaded; log file: " .. tostring(log_path) .. "; " .. battle_summary())
