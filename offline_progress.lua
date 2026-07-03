
-- offline_progress.lua
-- offline_progress.lua
-- Handles offline Upgrade Gold income and standard gold checkpointing across maps.
-- Optimized to prevent lag by reducing map-wide iterations.

OfflineProgress = OfflineProgress or {}
OfflineProgress.log_path = "offline_progress.log"
OfflineProgress.data_path = "offline_progress.dat"
OfflineProgress.base_rate = 5.0
OfflineProgress.creature_bonus = 0.05
OfflineProgress.area_bonus = 0.002
OfflineProgress.idle_refresh_seconds = 60 -- Save every minute if idle
OfflineProgress.save_interval_ticks = 1200 -- Check for changes every 60 seconds (1200 ticks)
OfflineProgress.gold_mirror_interval_ticks = 20 -- Mirror live gold gains into Upgrade Gold quickly
OfflineProgress.enabled = true
OfflineProgress.initial_gold_applied = false
OfflineProgress.offline_award_pending = false

-- State variables for initialization
OfflineProgress.target_upgrade_gold = nil
OfflineProgress.last_saved_gold = -1 
OfflineProgress.last_mirrored_gold = -1
OfflineProgress.last_saved_timestamp = 0
OfflineProgress.last_saved_rate = 1.0
OfflineProgress.offline_earned_display = 0
OfflineProgress.rate_to_use_display = 0
OfflineProgress.time_gone_display = 0
OfflineProgress.bonus_multiplier_display = 1.0
OfflineProgress.timer_registered = false
OfflineProgress.gold_mirror_registered = false
OfflineProgress.session_watch_registered = false
OfflineProgress.max_offline_days = 14
OfflineProgress.number_suffixes = {"", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc", "Ud", "Dd", "Td", "Qad", "Qid", "Sxd", "Spd", "Ocd", "Nod", "Vg", "Uvg", "Dvg", "Tvg", "Qavg", "Qivg", "Sxvg", "Spvg", "Ocvg", "Novg"}

OfflineProgress.session_id = os.time()
OfflineProgress.last_seen_turn = -1
OfflineProgress.last_reinit_turn = -1
OfflineProgress.init_cycle = 0
OfflineProgress.last_message_cycle = -1

function OfflineProgress.should_reinitialize(current_turn)
    if not Game then
        return false
    end

    if Game.offline_progress_last_session_id ~= OfflineProgress.session_id then
        return true
    end

    -- Loading a save in the same runtime rewinds GAME_TURN. Detect that and re-init.
    if OfflineProgress.last_seen_turn >= 0 and current_turn + 200 < OfflineProgress.last_seen_turn then
        return true
    end

    -- Starting a map/save from menu commonly begins near turn 0 after having progressed before.
    if OfflineProgress.last_seen_turn > 200 and current_turn <= 20 then
        return true
    end

    return false
end

function OfflineProgress.on_game_tick(eventData)
    if not OfflineProgress.enabled or not PLAYER0 or not Game then 
        return 
    end

    local current_turn = PLAYER0.GAME_TURN or 0
    if OfflineProgress.should_reinitialize(current_turn) and OfflineProgress.last_reinit_turn ~= current_turn then
        Game.offline_progress_last_session_id = OfflineProgress.session_id
        OfflineProgress.last_reinit_turn = current_turn
        OfflineProgress.init()
    end

    OfflineProgress.last_seen_turn = current_turn
end

function OfflineProgress_OnGameTick(eventData)
    if OfflineProgress and OfflineProgress.on_game_tick then
        OfflineProgress.on_game_tick(eventData)
    end
end

function OfflineProgress.format_number(value)
    local amount = tonumber(value) or 0
    local negative = amount < 0
    amount = math.abs(amount)
    local suffix_index = 1
    while amount >= 1000 and suffix_index < #OfflineProgress.number_suffixes do
        amount = amount / 1000
        suffix_index = suffix_index + 1
    end
    local formatted
    if suffix_index == 1 then
        formatted = tostring(math.floor(amount))
    else
        local str = string.format("%.2f", amount)
        str = string.gsub(str, "0+$", "")
        str = string.gsub(str, "%.$", "")
        formatted = str .. OfflineProgress.number_suffixes[suffix_index]
    end
    if negative then
        return "-" .. formatted
    end
    return formatted
end

function OfflineProgress.log_message(msg)
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local f = io.open(OfflineProgress.log_path, "a")
    if f then
        f:write("[" .. timestamp .. "] " .. msg .. "\n")
        f:close()
    end
end

function OfflineProgress.format_duration(seconds)
    if seconds < 60 then
        return seconds .. "s"
    elseif seconds < 3600 then
        return math.floor(seconds / 60) .. "m " .. (seconds % 60) .. "s"
    elseif seconds < 86400 then
        local hours = math.floor(seconds / 3600)
        local mins = math.floor((seconds % 3600) / 60)
        return hours .. "h " .. mins .. "m"
    else
        local days = math.floor(seconds / 86400)
        local hours = math.floor((seconds % 86400) / 3600)
        return days .. "d " .. hours .. "h"
    end
end

function OfflineProgress.show_message(message)
    if type(QuickMessage) == "function" then
        pcall(QuickMessage, message, "SPELL")
    else
        print("OfflineProgress: " .. tostring(message))
    end
end

function OfflineProgress.ensure_directory(path)
    if type(path) ~= "string" then return false end
    local dir = path:match("^(.*)[/\\]")
    if not dir or dir == "" then return true end
    local ok = pcall(function()
        os.execute('mkdir "' .. string.gsub(dir, "/", "\\") .. '" 2>nul')
    end)
    return ok
end

function OfflineProgress.save_data(gold, timestamp, rate)
    OfflineProgress.ensure_directory(OfflineProgress.data_path)
    local f = io.open(OfflineProgress.data_path, "w")
    if f then
        f:write(tostring(gold) .. "," .. tostring(timestamp) .. "," .. tostring(rate or OfflineProgress.base_rate))
        f:close()
    else
        OfflineProgress.log_message("Failed to save offline progress to " .. tostring(OfflineProgress.data_path))
    end
end

function OfflineProgress.load_data()
    local f = io.open(OfflineProgress.data_path, "r")
    if f then
        local content = f:read("*all")
        f:close()
        if content then
            local gold, timestamp, rate = content:match("([^,]+),([^,]+),([^,]+)")
            if gold and timestamp and rate then
                return tonumber(gold), tonumber(timestamp), tonumber(rate)
            elseif gold and timestamp then
                return tonumber(gold), tonumber(timestamp), OfflineProgress.base_rate
            end
        end
    end
    return nil, nil, nil
end

function OfflineProgress.calculate_current_rate()
    if not PLAYER0 then return OfflineProgress.base_rate end
    
    local creatures = PLAYER0.TOTAL_CREATURES or 0
    local area = PLAYER0.TOTAL_AREA or 0
    local research = PLAYER0.TOTAL_RESEARCH or 0
    local score = PLAYER0.SCORE or 0
    
    local unique_rooms = 0
    local room_types = {"TREASURE", "RESEARCH", "PRISON", "TORTURE", "TRAINING", "WORKSHOP", "SCAVENGER", "TEMPLE", "GRAVEYARD", "BARRACKS", "GARDEN", "LAIR", "GUARD_POST"}
    for _, rt in ipairs(room_types) do
        if (PLAYER0[rt] or 0) > 0 then unique_rooms = unique_rooms + 1 end
    end
    
    local total_level = 0
    local cr_count = 0
    if GetCreaturesOfPlayer then
        local crs = GetCreaturesOfPlayer(PLAYER0)
        if crs then
            cr_count = #crs
            for _, cr in ipairs(crs) do total_level = total_level + (cr.level or 1) end
        end
    end
    local avg_level = cr_count > 0 and (total_level / cr_count) or 1
    
    local rate = OfflineProgress.base_rate 
               + (creatures * OfflineProgress.creature_bonus) 
               + (area * OfflineProgress.area_bonus)
               + (unique_rooms * 0.50)
               + ((avg_level - 1) * 0.40)
               + math.min(research / 5000, 8.0)
               + math.min(score / 3000, 6.0)
               
    if Upgrades and Upgrades.offline_income_flat_bonus then
        rate = rate + Upgrades.offline_income_flat_bonus()
    end

    if rate > 150.0 then rate = 150.0 end
    if Upgrades and Upgrades.offline_income_multiplier then
        rate = rate * Upgrades.offline_income_multiplier()
    end
    return rate
end

local BASE_TRAINING_COSTS = {
    ARCHER = 8, AVATAR = 100, BARBARIAN = 40, BILE_DEMON = 38, BIRD = 7, BUG = 8,
    DARK_MISTRESS = 24, DEMONSPAWN = 15, DRAGON = 40, DRUID = 32, DWARFA = 5, FAIRY = 4,
    FLOATING_SPIRIT = 0, FLY = 5, GHOST = 20, GIANT = 35, HELL_HOUND = 14, HORNY = 150,
    IMP = 10, KNIGHT = 40, MAIDEN = 20, MONK = 12, ORC = 15, SAMURAI = 50, SKELETON = 20,
    SORCEROR = 30, SPIDER = 18, SPIDERLING = 10, TENTACLE = 14, THIEF = 12, TIME_MAGE = 30,
    TROLL = 12, TUNNELLER = 10, VAMPIRE = 50, WITCH = 16, WIZARD = 30
}

function OfflineProgress.get_creature_training_cost(cr)
    if not cr then return 5 end
    local ok, cost = pcall(function() return cr.training_cost end)
    if ok and cost then
        local num = tonumber(cost)
        if num then return num end
    end
    local model_key = tostring(cr.model or ""):upper():gsub("%s+", "_")
    local base_cost = BASE_TRAINING_COSTS[model_key] or 20
    local reduction = 0
    if Upgrades and Upgrades.effective_owned_rank then
        local rank = Upgrades.effective_owned_rank(6) or 0
        local per_rank = 5
        local scaled_val = math.max(1, math.floor(100 - rank * per_rank + 0.5))
        reduction = math.max(0, 100 - scaled_val)
    end
    return math.max(1, base_cost - reduction)
end

function OfflineProgress.simulate_training(time_diff)
    if not PLAYER0 or not GetCreaturesOfPlayer then return 0, 0, 0 end
    local max_level = 1
    if Upgrades and Upgrades.get_rank then
        max_level = math.min(10, 1 + math.floor(Upgrades.get_rank(17) / 10))
    end
    if max_level <= 1 then return 0, 0, 0 end

    local speed_mult = 1.0
    if Upgrades and Upgrades.offline_training_speed_multiplier then
        speed_mult = Upgrades.offline_training_speed_multiplier()
    end
    
    local ticks_offline = math.max(0, time_diff * 20 * speed_mult)
    local gold_spent = 0
    local levels_gained = 0
    local expeditions = 0

    local creatures = GetCreaturesOfPlayer(PLAYER0) or {}
    for _, cr in ipairs(creatures) do
        local cr_level = tonumber(cr.level) or 1
        if cr_level < max_level then
            local cost_per_tick = OfflineProgress.get_creature_training_cost(cr)
            local available_ticks = ticks_offline
            while cr_level < max_level and available_ticks > 2500 * cr_level do
                local required_ticks = 2500 * cr_level
                local required_gold = math.floor(required_ticks * cost_per_tick / 20)
                
                local current_gold = (PLAYER0.MONEY or 0) - gold_spent
                if current_gold < required_gold then break end
                
                gold_spent = gold_spent + required_gold
                available_ticks = available_ticks - required_ticks
                cr_level = cr_level + 1
                levels_gained = levels_gained + 1
                if cr.level_up then
                    if Upgrades then Upgrades._bonus_leveling = true end
                    pcall(function() cr:level_up(1) end)
                    if Upgrades then Upgrades._bonus_leveling = false end
                end
            end
        end
        if cr_level >= 10 then
            expeditions = expeditions + math.floor(time_diff / 28800) -- 8 hours instead of 12
        end
    end
    
    if gold_spent > 0 then
        pcall(function() PLAYER0:add_gold(-gold_spent) end)
    end
    
    return levels_gained, gold_spent, expeditions
end

function OfflineProgress.get_offline_bonus_multiplier(seconds_away)
    local seconds = math.max(0, tonumber(seconds_away) or 0)
    if seconds <= 3600 then return 1.2
    elseif seconds <= 21600 then return 1.5
    elseif seconds <= 86400 then return 2.0
    elseif seconds <= 604800 then return 3.0 end
    return 4.0
end

function OfflineProgress_PeriodicSave()
    if OfflineProgress and OfflineProgress.periodic_save then OfflineProgress.periodic_save() end
end

function OfflineProgress_MirrorGoldGains()
    if OfflineProgress and OfflineProgress.mirror_gold_gains then OfflineProgress.mirror_gold_gains() end
end

function OfflineProgress_ApplyInitialGold()
    if OfflineProgress and OfflineProgress.apply_initial_gold then OfflineProgress.apply_initial_gold() end
end

function OfflineProgress_OnDungeonDestroyed(eventData)
    if not OfflineProgress or not PLAYER0 then return end

    if OfflineProgress.offline_award_pending and not OfflineProgress.initial_gold_applied then
        OfflineProgress.log_message("Dungeon destroyed save skipped while offline award is pending.")
        return
    end

    if eventData.player == PLAYER0 then
        OfflineProgress.periodic_save()
    end
end

function OfflineProgress.init()
    if not OfflineProgress.enabled or not PLAYER0 then return end

    if OfflineProgress.offline_award_pending and not OfflineProgress.initial_gold_applied then
        OfflineProgress.log_message("Init skipped while offline award is pending.")
        return
    end

    OfflineProgress.init_cycle = OfflineProgress.init_cycle + 1
    OfflineProgress.initial_gold_applied = false
    local saved_gold, last_timestamp, saved_rate = OfflineProgress.load_data()
    local current_time = os.time()
    OfflineProgress.last_mirrored_gold = PLAYER0.MONEY or 0
    
    if saved_gold and last_timestamp then
        local time_diff = math.min(current_time - last_timestamp, OfflineProgress.max_offline_days * 86400)
        if time_diff < 0 then time_diff = 0 end
        
        local current_rate = OfflineProgress.calculate_current_rate()
        local rate_to_use = math.max(saved_rate or OfflineProgress.base_rate, current_rate)
        local bonus_multiplier = OfflineProgress.get_offline_bonus_multiplier(time_diff)
        local offline_earned = math.floor(time_diff * rate_to_use * bonus_multiplier)
        
        OfflineProgress.target_upgrade_gold = offline_earned
        OfflineProgress.offline_earned_display = offline_earned
        OfflineProgress.rate_to_use_display = rate_to_use * bonus_multiplier
        OfflineProgress.time_gone_display = time_diff
        OfflineProgress.offline_award_pending = true
        
        OfflineProgress.log_message("Init. Earned: " .. offline_earned .. " over " .. time_diff .. "s")
        OfflineProgress.pending_training_time = time_diff
    else
        OfflineProgress.target_upgrade_gold = nil
        OfflineProgress.offline_earned_display = 0
        OfflineProgress.rate_to_use_display = 0
        OfflineProgress.time_gone_display = 0
        OfflineProgress.offline_award_pending = false
        OfflineProgress.pending_training_time = 0
    end

    if RegisterTimerEvent then
        RegisterTimerEvent("OfflineProgress_ApplyInitialGold", 5, false)
        RegisterTimerEvent("OfflineProgress_ApplyInitialGold", 20, false)
        RegisterTimerEvent("OfflineProgress_ApplyInitialGold", 100, false)
    end
    
    if RegisterDungeonDestroyedEvent then RegisterDungeonDestroyedEvent("OfflineProgress_OnDungeonDestroyed") end
end

function OfflineProgress.apply_initial_gold()
    if not PLAYER0 or OfflineProgress.initial_gold_applied then return end
    
    if OfflineProgress.target_upgrade_gold == nil then
        local current_gold = PLAYER0.MONEY or 0
        if current_gold > 0 or PLAYER0.GAME_TURN > 40 then
            OfflineProgress.target_upgrade_gold = 0
            OfflineProgress.initial_gold_applied = true
            OfflineProgress.periodic_save()
            OfflineProgress.ensure_periodic_save_registered()
            OfflineProgress.ensure_gold_mirror_registered()
        end
        return
    end

    if OfflineProgress.target_upgrade_gold > 0 and Upgrades and Upgrades.add_upgrade_gold then
        Upgrades.add_upgrade_gold(OfflineProgress.target_upgrade_gold)
        if Upgrades.save then
            pcall(Upgrades.save)
        end
    end
    
    OfflineProgress.initial_gold_applied = true
    OfflineProgress.offline_award_pending = false
    OfflineProgress.periodic_save()
    
    if OfflineProgress.offline_earned_display > 0 or (Upgrades and Upgrades.upgrade_gold_granted and Upgrades.upgrade_gold_granted > 0) then
        if OfflineProgress.last_message_cycle ~= OfflineProgress.init_cycle then
            local upgrade_gold = 0
            if Upgrades and Upgrades.consume_upgrade_gold then
                upgrade_gold = Upgrades.consume_upgrade_gold()
            end
            
            local levels_gained, gold_spent, expeditions = 0, 0, 0
            if OfflineProgress.pending_training_time and OfflineProgress.pending_training_time > 0 then
                levels_gained, gold_spent, expeditions = OfflineProgress.simulate_training(OfflineProgress.pending_training_time)
                OfflineProgress.pending_training_time = 0
            end

            if expeditions > 0 and Upgrades and Upgrades.add_upgrade_gold then
                -- Expedition reward: 50000 Upgrade Gold per expedition!
                local exp_reward = expeditions * 50000
                Upgrades.add_upgrade_gold(exp_reward)
                upgrade_gold = upgrade_gold + exp_reward
                if Upgrades.save then pcall(Upgrades.save) end
            end
            
            local dur = OfflineProgress.format_duration(OfflineProgress.time_gone_display)
            local upgrade_gold_display = OfflineProgress.format_number(upgrade_gold)
            
            local parts = { "Offline " .. dur .. ": " .. upgrade_gold_display .. " Upgrade Gold" }
            if levels_gained > 0 then
                parts[#parts+1] = levels_gained .. " lvls (-" .. OfflineProgress.format_number(gold_spent) .. " Gold)"
            end
            if expeditions > 0 then
                parts[#parts+1] = expeditions .. " artifacts"
            end

            OfflineProgress.show_message(table.concat(parts, ", ") .. ".")
            OfflineProgress.last_message_cycle = OfflineProgress.init_cycle
        end
    end
    
    OfflineProgress.ensure_periodic_save_registered()
    OfflineProgress.ensure_gold_mirror_registered()
end

function OfflineProgress.ensure_periodic_save_registered()
    if OfflineProgress.timer_registered or not RegisterTimerEvent then return end
    RegisterTimerEvent("OfflineProgress_PeriodicSave", OfflineProgress.save_interval_ticks, true)
    OfflineProgress.timer_registered = true
end

function OfflineProgress.ensure_gold_mirror_registered()
    if OfflineProgress.gold_mirror_registered or not RegisterTimerEvent then return end
    RegisterTimerEvent("OfflineProgress_MirrorGoldGains", OfflineProgress.gold_mirror_interval_ticks, true)
    OfflineProgress.gold_mirror_registered = true
end

function OfflineProgress.ensure_session_watch_registered()
    if OfflineProgress.session_watch_registered or not RegisterTimerEvent then return end
    RegisterTimerEvent("OfflineProgress_OnGameTick", 20, true)
    OfflineProgress.session_watch_registered = true
end

function OfflineProgress.mirror_gold_gains()
    if not PLAYER0 or not Upgrades or not Upgrades.add_upgrade_gold then return end

    local current_gold = PLAYER0.MONEY or 0
    if OfflineProgress.last_mirrored_gold < 0 then
        OfflineProgress.last_mirrored_gold = current_gold
        return
    end

    if current_gold > OfflineProgress.last_mirrored_gold then
        Upgrades.add_upgrade_gold(current_gold - OfflineProgress.last_mirrored_gold)
        OfflineProgress.last_mirrored_gold = current_gold
        -- Removed forced save; Upgrades._dirty is set internally and saved periodically by Upgrades_SilentSave
    end
end

function OfflineProgress.periodic_save()
    if not PLAYER0 then return end
    local current_time = os.time()
    local current_gold = PLAYER0.MONEY or 0
    
    -- Fast exit: No changes and not enough time passed
    if current_gold == OfflineProgress.last_saved_gold and (current_time - OfflineProgress.last_saved_timestamp) < OfflineProgress.idle_refresh_seconds then
        return
    end

    -- Heavy work ONLY when actually saving
    local current_rate = OfflineProgress.calculate_current_rate()
    OfflineProgress.last_saved_gold = current_gold
    OfflineProgress.last_saved_timestamp = current_time
    OfflineProgress.last_saved_rate = current_rate
    OfflineProgress.save_data(current_gold, current_time, current_rate)
end

function OfflineProgress.rebind_after_game_loaded()
    -- Save loading replaces Game state (including triggers). Re-register offline hooks.
    OfflineProgress.timer_registered = false
    OfflineProgress.gold_mirror_registered = false
    OfflineProgress.session_watch_registered = false
    OfflineProgress.initial_gold_applied = false
    OfflineProgress.offline_award_pending = false
    OfflineProgress.last_reinit_turn = -1
    OfflineProgress.last_seen_turn = (PLAYER0 and PLAYER0.GAME_TURN) or -1
    OfflineProgress.last_mirrored_gold = (PLAYER0 and PLAYER0.MONEY) or -1

    if Game then
        Game.offline_progress_last_session_id = OfflineProgress.session_id
    end

    OfflineProgress.ensure_session_watch_registered()
    OfflineProgress.init()
end

_G.OfflineProgress = OfflineProgress
OfflineProgress.ensure_session_watch_registered()
OfflineProgress.ensure_gold_mirror_registered()
if RegisterTimerEvent then
    RegisterTimerEvent(function() if OfflineProgress and OfflineProgress.init then OfflineProgress.init() end end, 5, false)
end
return OfflineProgress
