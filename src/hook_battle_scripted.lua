

-- [siege_ai] Added by the Siege AI mod: load our battle script in every battle.
-- pcall keeps the game's own battle script working even if ours fails to load.
local siege_ai_ok, siege_ai_err = pcall(require, "data.script.siege_ai.siege_ai_battle")
if not siege_ai_ok then
	print("[siege_ai] failed to load: " .. tostring(siege_ai_err))
end
