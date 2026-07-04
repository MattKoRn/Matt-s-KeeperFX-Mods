--[[
AutoCamera Improved Edition
Patch notes:
- Safer target location handling for room/center positions that only expose val_x/val_y.
- Interrupt queue coalescing so repeated events at the same spot do not spam the camera.
- fight_anchor_lock toggle now actually controls battle locking.
- Priority fight pre-check now scores targets before choosing a battle.
- Chat command UX expanded: help, status, stable/combat/cinematic/balanced shortcuts, quiet/cinematic toggles.
- Added safer pcall wrappers around tick and registration paths.
Continue Pass 2:
- Added error tolerance: AutoCam now counts consecutive tick errors before disabling itself.
- Added /autocam debug, /autocam reset, /autocam lock, and /autocam queue commands.
- Added soft label-streak protection so quiet cycling does not show the same kind of target forever.
- Hardened scenic room scans behind pcall/type guards for maps or builds without room helper APIs.
- Added a tiny heartbeat/status helper for easier in-game troubleshooting.
]]

AutoCamera = AutoCamera or {}
AutoCamera.enabled = false
AutoCamera.cycle_interval_turns = 150
AutoCamera.max_targets = 48
AutoCamera.player = PLAYER0
AutoCamera.chat_command = "/autocam"
AutoCamera.cinematic = false
AutoCamera.fight_interrupt_cooldown_turns = 90
AutoCamera.fight_same_target_grace_turns = 150
AutoCamera.fight_retarget_distance_sq = 3072 * 3072
AutoCamera.max_interrupt_queue = 6
AutoCamera.cinematic_orbit_amp = 150
AutoCamera.cinematic_orbit_speed_x = 0.040
AutoCamera.cinematic_orbit_speed_y = 0.032
AutoCamera.micro_pan_strength = 0.24
AutoCamera.proximity_limit_normal_sq = 2304 * 2304
AutoCamera.proximity_limit_cinematic_sq = 4608 * 4608
AutoCamera.anti_pingpong_distance_sq = 896 * 896
AutoCamera.active_profile = "balanced"
AutoCamera.max_map_scan_slabs = 255
AutoCamera.sweep_pad_stl = 8          -- Subtile padding when sweeping across the map during quiet periods
AutoCamera.sweep_speed_turns = 360    -- Turns it takes to complete one full sweep pass
AutoCamera.breach_emergency_hp = 0.30 -- Door HP ratio threshold for breach (idea 47) — 30% = heavy damage
AutoCamera.bankruptcy_threshold = 2500 -- Gold amount below which bankruptcy warning triggers
AutoCamera.prison_overcrowd_threshold = 6 -- Prisoner count threshold for prison warning
AutoCamera.gold_milestone_interval = 1000 -- Gold mined between milestone interrupts
AutoCamera.treasury_full_threshold = 0.95 -- Trigger treasury warning when 95% full  -- Ratio of gold/capacity to trigger treasury full warning
AutoCamera.max_consecutive_tick_errors = 3 -- Consecutive script errors before AutoCam disables itself
AutoCamera.debug = false                 -- Extra chat diagnostics for troubleshooting
AutoCamera.label_streak_limit = 2         -- Soft cap before repeated low-priority labels get penalised
AutoCamera.label_streak_penalty = 80      -- Penalty applied to repeated low-priority labels
AutoCamera.low_priority_label_streak_cutoff = 250 -- Do not penalise urgent/combat targets

local function auto_camera_debug_message(msg)
    if AutoCamera.debug then
        print("AutoCam: " .. tostring(msg))
        if type(QuickMessage) == "function" then
            QuickMessage("AutoCam: " .. tostring(msg), "QUERY")
        end
    end
end


AutoCamera.profiles = {
    balanced = {
        cycle_interval_turns = 160,
        fight_interrupt_cooldown_turns = 110,
        fight_same_target_grace_turns = 170,
        fight_retarget_distance_sq = 3000 * 3000,
        max_interrupt_queue = 6,
        cinematic_orbit_amp = 150,
        cinematic_orbit_speed_x = 0.040,
        cinematic_orbit_speed_y = 0.032,
        micro_pan_strength = 0.24,
        proximity_limit_normal_sq = 2304 * 2304,
        proximity_limit_cinematic_sq = 4608 * 4608,
        anti_pingpong_distance_sq = 896 * 896,
    },
    combat = {
        cycle_interval_turns = 120,
        fight_interrupt_cooldown_turns = 70,
        fight_same_target_grace_turns = 220,
        fight_retarget_distance_sq = 2200 * 2200,
        max_interrupt_queue = 8,
        cinematic_orbit_amp = 130,
        cinematic_orbit_speed_x = 0.048,
        cinematic_orbit_speed_y = 0.038,
        micro_pan_strength = 0.20,
        proximity_limit_normal_sq = 2600 * 2600,
        proximity_limit_cinematic_sq = 5200 * 5200,
        anti_pingpong_distance_sq = 1024 * 1024,
    },
    cinematic = {
        cycle_interval_turns = 240,
        fight_interrupt_cooldown_turns = 105,
        fight_same_target_grace_turns = 180,
        fight_retarget_distance_sq = 3300 * 3300,
        max_interrupt_queue = 5,
        cinematic_orbit_amp = 240,
        cinematic_orbit_speed_x = 0.025,
        cinematic_orbit_speed_y = 0.020,
        micro_pan_strength = 0.35,
        proximity_limit_normal_sq = 2500 * 2500,
        proximity_limit_cinematic_sq = 5500 * 5500,
        anti_pingpong_distance_sq = 1500 * 1500,
    },
    stable = {
        cycle_interval_turns = 180,
        fight_interrupt_cooldown_turns = 140,
        fight_same_target_grace_turns = 240,
        fight_retarget_distance_sq = 3600 * 3600,
        max_interrupt_queue = 5,
        cinematic_orbit_amp = 110,
        cinematic_orbit_speed_x = 0.030,
        cinematic_orbit_speed_y = 0.024,
        micro_pan_strength = 0.16,
        proximity_limit_normal_sq = 3000 * 3000,
        proximity_limit_cinematic_sq = 5800 * 5800,
        anti_pingpong_distance_sq = 1200 * 1200,
    },
}

-- Feature toggles organised by category. Set to false to disable a feature.
AutoCamera.ideas = {
    -- Core cycle behaviour
    adaptive_cycle = true,            -- 1: Vary cycle speed based on current action intensity
    target_age_bonus = true,          -- 2: Boost priority for targets not seen recently
    label_cooldown = false,           -- 3: Penalise recently shown labels (disabled by default)
    anti_pingpong = true,             -- 4: Penalise targets too close to the last camera position
    hotzone_revisit = true,           -- 5: Boost priority for recently fought locations
    fight_anchor_lock = true,         -- 6: Lock camera on active battles until they end
    interrupt_queue = true,           -- 7: Queue high-priority events for immediate attention
    post_event_hold = true,           -- 8: Hold camera on major events before resuming cycle
    scenic_diversity = true,          -- 9: Show a variety of rooms during quiet periods
    formation_focus = true,           -- 10: Raise fight priority when many creatures are engaged
    threat_wave_bias = true,          -- 11: Boost heart_danger/breach/heart_panic targets
    recovery_focus = true,            -- 12: Boost wounded creature priority
    quiet_sweep = true,               -- 13: Gentle map panning when nothing important is happening
    adaptive_offset = true,           -- 14: Apply subtle screen position offsets
    cinematic_orbit = true,           -- 15: Orbit around targets in cinematic mode
    micro_pan = true,                 -- 16: Gentle oscillation when dwelling on the same target
    distance_budget = true,           -- 17: Penalise non-critical targets far from the current view
    priority_smoothing = true,        -- 18: Smooth priority values for stable adaptive cycling
    deterministic_variety = true,     -- 19: Rotate through equally-good targets deterministically
    chat_presets = true,              -- 20: Support chat commands for presets

    -- Event-driven focus features
    epic_moment_focus = true,         -- 21: Boost priority for Horny/Avatar/large fights
    spell_focus = true,               -- 22: Interrupt when spells are cast (merged with spell_cast_focus)
    dig_focus = true,                 -- 23: Interrupt when walls are dug
    claim_focus = true,               -- 24: Interrupt when territory is claimed
    trap_focus = true,                -- 25: Interrupt when traps are placed
    gold_carrying_focus = true,       -- 26: Highlight creatures carrying lots of gold
    rebirth_focus = true,             -- 27: Interrupt on creature rebirth
    dungeon_destroyed_focus = true,   -- 28: Interrupt when dungeon is destroyed
    door_destroyed_focus = true,      -- 29: Interrupt when doors are destroyed
    major_damage_focus = true,        -- 30: Interrupt when creatures take heavy damage
    room_construction_focus = true,   -- 31: Interrupt when rooms are built
    gold_milestone_focus = true,      -- 32: Interrupt on gold mining milestones
    combat_training_focus = true,     -- 33: Prioritise combat training rooms with trainees
    gold_mining_focus = true,         -- 34: Highlight areas where imps are actively mining gold
    follow_creature = true,           -- 35: Follow creatures between camera cycles
    eyes_mode = true,                 -- 36: First-person follow mode
    imp_swarm = true,                 -- 37: Highlight groups of active imps
    drop_focus = true,                -- 38: Focus on creatures that were just dropped
    workshop_focus = true,            -- 39: Prioritise workshop rooms with workers
    rebellion_focus = true,           -- 40: Interrupt on creature rebellion
    torture_climax = true,            -- 41: Boost torture priority as health drops
    first_blood = true,               -- 42: Extra boost for the first fight in a hotspot
    barracks_focus = true,            -- 43: Prioritise barracks/guardroom rooms with defenders
    scenic_tour = true,               -- 44: Tour rooms during quiet sweeps
    bankruptcy_warning = true,        -- 45: Warn when gold is critically low
    post_possession = true,           -- 46: Track creatures after possession ends
    door_breach = true,               -- 47: Interrupt when doors take heavy damage
    fleeing_focus = true,             -- 48: Highlight fleeing creatures
    trap_trigger = true,              -- 49: Interrupt on trap detonation
    prison_warning = true,            -- 50: Warn when prison is overcrowded
    temple_sacrifice = true,          -- 51: Highlight temple sacrifices
    hunger_warning = true,            -- 52: Highlight hungry creatures
    library_focus = true,             -- 53: Prioritise library rooms with workers
    party_focus = true,               -- 54: Highlight creatures partying/celebrating in lair
    spell_cast_focus = true,          -- 55: Lower-priority interrupt for spell casts
    slap_reaction = true,             -- 56: Highlight slapped creatures
    victory_cheer = true,             -- 57: Highlight cheering creatures
    payday_anger = true,              -- 58: Highlight creatures angry about not being paid
    scavenge_focus = true,            -- 59: Prioritise scavenge rooms with workers
    treasury_warning = true,          -- 60: Warn when treasury is completely full
    eyes_mode_cycle = true,           -- 61: Automatically cycle possession between creatures in eyes mode
    label_streak_guard = true,        -- 62: Avoid quiet-mode repeats of the same target type
}

local function auto_camera_state()
    Game = Game or {}
    Game.AutoCamera = Game.AutoCamera or {
        enabled = false,
        cinematic = false,
        eyes_mode = false,
        last_cycle_turn = -9999,
        last_target_index = 0,
        last_target_key = nil,
        follow_thing_idx = nil,
        interrupt_queue = {},
        target_seen_turn = {},
        label_seen_turn = {},
        orbit_phase = 0,
        hold_until_turn = -9999,
        smoothed_priority = 0,
        heatmap = {},
        unit_boosts = {},
        last_heart_health = nil,
        last_gold_mined = 0,
        sweep_phase = 0,
        locked_battle = nil,
        was_picked_up = {},
        dropped_turns = {},
        last_view_type = 1,
        possessed_idx = nil,
        -- Cooldown timestamps for event throttling
        last_dig_turn = -9999,
        last_const_turn = -9999,
        last_major_dmg_turn = -9999,
        last_door_dmg_turn = -9999,
        last_spell_turn = -9999,
        last_trap_trig_turn = -9999,
        last_claim_turn = -9999,
        last_heart_panic_turn = -9999,
        last_eyes_cycle_turn = -9999,
        last_spell_high_turn = -9999,   -- For spell_focus (idea 22) cooldown
        last_spell_low_turn = -9999,    -- For spell_cast_focus (idea 55) cooldown
        heart_check_turn = -9999,       -- Heart health polling cooldown
        last_interrupt_turn = -9999,    -- Interrupt queue cooldown
        interrupt_active = false,       -- Whether the camera is currently serving an interrupt
        force_next_target = false,      -- /autocam next forces a target switch
        fight_grace_last_key = nil,     -- Same-target grace period key
        fight_grace_turn = -9999,       -- Same-target grace period start turn
        last_priority = 0,              -- Priority of the last viewed target
        last_location = nil,            -- Last camera location for anti-pingpong/distance-budget
        last_label = nil,               -- Label of the last viewed target
        map_bounds = nil,               -- Cached map bounds (computed lazily)
        quiet_sweep_progress = nil,     -- Sweep progress table for quiet_sweep
        sweep_path_cache = nil,         -- Cached sweep path for quiet_sweep
        adaptive_phase = 0,             -- Phase accumulator for adaptive_offset
        last_gold_mining_turn = -9999,  -- Throttle for gold_mining_focus (idea 34)
        has_toured = {},                -- Rooms already visited on this scenic_tour pass
        last_party_turn = -9999,        -- Throttle for party_focus (idea 54)
        consecutive_tick_errors = 0, -- Error tolerance for AutoCameraTick wrapper
        last_tick_error = nil,        -- Last script error text for /autocam status
        debug_last_summary = nil,     -- Compact target summary for /autocam debug
        label_streak_label = nil,     -- Last repeated label tracked by label_streak_guard
        label_streak_count = 0,       -- Number of consecutive low-priority selections for the label
    }
    return Game.AutoCamera
end

local function auto_camera_queue_count()
    local state = auto_camera_state()
    return state.interrupt_queue and #state.interrupt_queue or 0
end

local function auto_camera_soft_reset_runtime()
    local state = auto_camera_state()
    state.last_cycle_turn = -9999
    state.last_target_index = 0
    state.last_target_key = nil
    state.follow_thing_idx = nil
    state.interrupt_queue = {}
    state.target_seen_turn = {}
    state.label_seen_turn = {}
    state.orbit_phase = 0
    state.hold_until_turn = -9999
    state.smoothed_priority = 0
    state.heatmap = {}
    state.unit_boosts = {}
    state.last_heart_health = nil
    state.last_gold_mined = 0
    state.sweep_phase = 0
    state.locked_battle = nil
    state.was_picked_up = {}
    state.dropped_turns = {}
    state.last_view_type = 1
    state.possessed_idx = nil
    state.last_dig_turn = -9999
    state.last_const_turn = -9999
    state.last_major_dmg_turn = -9999
    state.last_door_dmg_turn = -9999
    state.last_spell_turn = -9999
    state.last_trap_trig_turn = -9999
    state.last_claim_turn = -9999
    state.last_heart_panic_turn = -9999
    state.last_eyes_cycle_turn = -9999
    state.last_spell_high_turn = -9999
    state.last_spell_low_turn = -9999
    state.heart_check_turn = -9999
    state.last_interrupt_turn = -9999
    state.interrupt_active = false
    state.force_next_target = false
    state.fight_grace_last_key = nil
    state.fight_grace_turn = -9999
    state.last_priority = 0
    state.last_location = nil
    state.last_label = nil
    state.map_bounds = nil
    state.quiet_sweep_progress = nil
    state.sweep_path_cache = nil
    state.adaptive_phase = 0
    state.last_gold_mining_turn = -9999
    state.has_toured = {}
    state.last_party_turn = -9999
    state.consecutive_tick_errors = 0
    state.last_tick_error = nil
    state.debug_last_summary = nil
    state.label_streak_label = nil
    state.label_streak_count = 0
end

local function safe_is_valid(thing)
    if not thing then return false end
    local is_room = false
    local ok_r = pcall(function() if thing.room_idx then is_room = true end end)
    if ok_r and is_room then return true end
    local ok, valid = pcall(function()
        if type(thing.isValid) == "function" then return thing:isValid() end
        return true
    end)
    return ok and (valid == true)
end

local function auto_camera_has_non_imp(player, creatures_list)
    if not player then return false end
    for _, cr in ipairs(creatures_list or GetCreaturesOfPlayer(player) or {}) do
        if cr.model ~= "IMP" and safe_is_valid(cr) and (cr.health or 1) > 0 then
            return true
        end
    end
    return false
end

local function auto_camera_clamp(value, min_value, max_value)
    if value < min_value then return min_value end
    if value > max_value then return max_value end
    return value
end

local function auto_camera_is_valid_slab(slb_x, slb_y)
    local ok, slab = pcall(function() return GetSlab(slb_x, slb_y) end)
    return ok and slab ~= nil
end

local function auto_camera_get_map_bounds()
    local state = auto_camera_state()
    if state.map_bounds then return state.map_bounds end
    local max_slab_x = 0
    while max_slab_x < AutoCamera.max_map_scan_slabs and auto_camera_is_valid_slab(max_slab_x + 1, 0) do max_slab_x = max_slab_x + 1 end
    local max_slab_y = 0
    while max_slab_y < AutoCamera.max_map_scan_slabs and auto_camera_is_valid_slab(0, max_slab_y + 1) do max_slab_y = max_slab_y + 1 end
    state.map_bounds = {
        min_stl_x = 1, min_stl_y = 1,
        max_stl_x = math.max(1, ((max_slab_x + 1) * 3) - 2),
        max_stl_y = math.max(1, ((max_slab_y + 1) * 3) - 2),
    }
    return state.map_bounds
end

local function auto_camera_sanitize_location(location, pad_subtiles)
    if not location or (not location.val_x and location.stl_x == nil) or (not location.val_y and location.stl_y == nil) then return nil end
    local bounds = auto_camera_get_map_bounds()
    local pad = math.max(0, pad_subtiles or 0)
    local min_stl_x = math.min(bounds.min_stl_x + pad, bounds.max_stl_x)
    local min_stl_y = math.min(bounds.min_stl_y + pad, bounds.max_stl_y)
    local max_stl_x = math.max(min_stl_x, bounds.max_stl_x - pad)
    local max_stl_y = math.max(min_stl_y, bounds.max_stl_y - pad)
    local stl_x = location.stl_x or math.floor(location.val_x / 256)
    local stl_y = location.stl_y or math.floor(location.val_y / 256)
    stl_x = auto_camera_clamp(stl_x, min_stl_x, max_stl_x)
    stl_y = auto_camera_clamp(stl_y, min_stl_y, max_stl_y)
    return {
        val_x = auto_camera_clamp(location.val_x or (stl_x * 256), min_stl_x * 256, max_stl_x * 256),
        val_y = auto_camera_clamp(location.val_y or (stl_y * 256), min_stl_y * 256, max_stl_y * 256),
        val_z = location.val_z, stl_x = stl_x, stl_y = stl_y,
    }
end

local function auto_camera_zoom_to_location(player, location, pad_subtiles)
    local safe_loc = auto_camera_sanitize_location(location, pad_subtiles)
    if safe_loc then
        local ok = pcall(function() ZoomToLocation(player, safe_loc) end)
        if not ok then return nil end
    end
    return safe_loc
end

local function auto_camera_dist_sq(loc1, loc2)
    if not loc1 or not loc2 or not loc1.val_x or not loc1.val_y or not loc2.val_x or not loc2.val_y then return 99999999 end
    local dx, dy = loc1.val_x - loc2.val_x, loc1.val_y - loc2.val_y
    return dx * dx + dy * dy
end

local function auto_camera_health_ratio(creature)
    if not creature or (creature.max_health or 0) <= 0 then return 1 end
    return auto_camera_clamp((creature.health or creature.max_health) / creature.max_health, 0, 1)
end

local function auto_camera_add_target(targets, seen, thing, location, priority, label, participants, is_eoi)
    if not location or not location.val_x or not location.val_y then return end
    label = tostring(label or "target")
    local sx = location.stl_x or math.floor((location.val_x or 0) / 256)
    local sy = location.stl_y or math.floor((location.val_y or 0) / 256)
    if not sx or not sy or sx <= 0 or sy <= 0 then return end
    location.stl_x, location.stl_y = sx, sy
    local thing_key = nil
    pcall(function() thing_key = thing and (thing.ThingIndex or thing.room_idx or thing.index) end)
    local key = label .. ":" .. tostring(thing_key or (sx .. "," .. sy))
    if seen[key] then return end
    seen[key] = true
    local orientation = nil
    pcall(function() orientation = thing and thing.orientation or nil end)
    targets[#targets + 1] = {
        key = key,
        location = location,
        priority = priority or 0,
        label = label,
        participants = participants or 1,
        orientation = orientation,
        is_eoi = is_eoi == true,
        thing_idx = thing_key,
    }
end

local function auto_camera_interrupt_priority(label)
    local urgent = { dungeon_destroyed = 2500, heart_strike = 2100, major_damage = 950, major_death = 900, victory_defeat = 800, elite_level_up = 600, special_found = 500, spell_cast = 450, rebirth = 400, door_destroyed = 350, room_capture = 250, fight = 300, gold_milestone = 200, trap_placed = 180, room_construction = 120, door_breach = 450, dig_focus = 110, claim_focus = 90, trap_triggered = 380, room_lost = 800 }
    return urgent[label] or 150
end

local function auto_camera_queue_interrupt(location, priority, label)
    local state = auto_camera_state()
    local player = AutoCamera.player or PLAYER0
    local turn = (player and player.GAME_TURN) or (PLAYER0 and PLAYER0.GAME_TURN) or 0
    local safe_loc = auto_camera_sanitize_location(location, 0)
    if not safe_loc then return false end
    priority = priority or auto_camera_interrupt_priority(label)
    label = tostring(label or "interrupt")
    state.interrupt_queue = state.interrupt_queue or {}

    -- Coalesce nearby duplicate interrupts. This prevents repeated damage/spell events
    -- from filling the queue with almost identical camera jumps.
    for _, item in ipairs(state.interrupt_queue) do
        if item.label == label and auto_camera_dist_sq(item.location, safe_loc) < (512 * 512) then
            item.priority = math.max(item.priority or 0, priority)
            item.turn = turn
            item.location = safe_loc
            table.sort(state.interrupt_queue, function(a, b)
                if a.priority ~= b.priority then return a.priority > b.priority end
                return (a.turn or 0) > (b.turn or 0)
            end)
            return true
        end
    end

    state.interrupt_queue[#state.interrupt_queue + 1] = { location = safe_loc, priority = priority, label = label, turn = turn }
    table.sort(state.interrupt_queue, function(a, b)
        if a.priority ~= b.priority then return a.priority > b.priority end
        return (a.turn or 0) > (b.turn or 0)
    end)
    while #state.interrupt_queue > AutoCamera.max_interrupt_queue do table.remove(state.interrupt_queue) end
    return true
end
local function auto_camera_try_flush_interrupt_queue(current_turn)
    local state = auto_camera_state()
    if not state.interrupt_queue or #state.interrupt_queue == 0 then return false end
    local item = state.interrupt_queue[1]
    -- Scale cooldown by priority: urgent interrupts fire faster, routine ones wait longer
    local wait = AutoCamera.fight_interrupt_cooldown_turns
    if item.priority >= 1000 then wait = math.max(3, math.floor(wait * 0.25))
    elseif item.priority >= 600 then wait = math.max(5, math.floor(wait * 0.5))
    elseif item.priority >= 300 then wait = math.floor(wait * 0.75)
    end
    if current_turn - (state.last_interrupt_turn or -9999) < wait then return false end
    
    -- Priority decay: penalise items that have been sitting in the queue too long
    local age = current_turn - (item.turn or current_turn)
    if age > 150 and item.priority < 1000 then
        item.priority = item.priority - math.floor(age / 5)
        if item.priority < 100 then
            table.remove(state.interrupt_queue, 1)
            return false
        end
    end

    table.remove(state.interrupt_queue, 1)
    local safe_loc = auto_camera_zoom_to_location(AutoCamera.player, item.location, 2)
    if not safe_loc then return false end
    state.last_cycle_turn, state.last_priority, state.last_location, state.last_interrupt_turn, state.last_label, state.interrupt_active = current_turn, item.priority, safe_loc, current_turn, item.label, true
    state.follow_thing_idx = nil
    if AutoCamera.ideas.post_event_hold and item.priority >= 500 then state.hold_until_turn = current_turn + 45 end
    return true
end

local function auto_camera_score_targets(targets)
    local state = auto_camera_state()
    local current_turn = PLAYER0.GAME_TURN or 0
    local prox_limit_sq = state.cinematic and AutoCamera.proximity_limit_cinematic_sq or AutoCamera.proximity_limit_normal_sq
    for _, t in ipairs(targets) do
        local bonus = 0
        local last_target_seen = state.target_seen_turn[t.key] or -9999
        local last_label_seen = state.label_seen_turn[t.label] or -9999
        if AutoCamera.ideas.target_age_bonus then bonus = bonus + auto_camera_clamp((current_turn - last_target_seen) / 8, 0, 120) end
        if AutoCamera.ideas.label_cooldown and (current_turn - last_label_seen) < 80 then bonus = bonus - auto_camera_clamp((80 - (current_turn - last_label_seen)), 0, 45) end
        if AutoCamera.ideas.formation_focus and t.label == "fight" then bonus = bonus + math.min((t.participants or 1) * 6, 90) end
        if AutoCamera.ideas.recovery_focus and t.label == "wounded" then bonus = bonus + 35 end
        if AutoCamera.ideas.threat_wave_bias and (t.label == "heart_danger" or t.label == "door_breach" or t.label == "heart_panic") then bonus = bonus + 50 end
        if AutoCamera.ideas.hotzone_revisit then
            -- hotzone_revisit: boost targets at recently fought locations using heatmap data
            if t.label == "fight" or t.label == "door_breach" or t.label == "heart_danger" or t.label == "heart_panic" then
                local hk = tostring(t.location.stl_x or 0) .. "," .. tostring(t.location.stl_y or 0)
                local heat = state.heatmap and state.heatmap[hk] or 0
                if heat > 0 then
                    bonus = bonus + math.floor(math.min(heat / 4, 60))
                end
            end
        end
        -- anti-pingpong: penalise targets very close to the last camera position
        if AutoCamera.ideas.anti_pingpong and state.last_location and t.key ~= state.last_target_key then
            local dsq = auto_camera_dist_sq(t.location, state.last_location)
            if dsq < AutoCamera.anti_pingpong_distance_sq then
                bonus = bonus - auto_camera_clamp(math.floor((1 - dsq / AutoCamera.anti_pingpong_distance_sq) * 60), 0, 60)
            end
        end
        -- distance budget: penalise non-critical targets that are far from the current view
        if AutoCamera.ideas.distance_budget and state.last_location and prox_limit_sq and prox_limit_sq > 0
            and t.label ~= "fight" and t.label ~= "door_breach" and t.label ~= "heart_danger" and t.label ~= "heart_panic" then
            local dsq = auto_camera_dist_sq(t.location, state.last_location)
            if dsq > prox_limit_sq then
                bonus = bonus - auto_camera_clamp(math.floor((dsq - prox_limit_sq) / (prox_limit_sq * 0.2)), 0, 80)
            end
        end
        if AutoCamera.ideas.label_streak_guard and state.label_streak_label == t.label and (state.label_streak_count or 0) >= AutoCamera.label_streak_limit and (t.priority or 0) < AutoCamera.low_priority_label_streak_cutoff then
            bonus = bonus - AutoCamera.label_streak_penalty
        end
        t.score = (t.priority or 0) + bonus
    end
    -- Sort: highest score first; if equal, stable by key
    table.sort(targets, function(a, b)
        local sa, sb = a.score or a.priority or 0, b.score or b.priority or 0
        if sa ~= sb then return sa > sb end
        return tostring(a.key) < tostring(b.key)
    end)
end

local function auto_camera_can_move_player(player)
    if not player then return false end
    local view_type = player.VIEW_TYPE
    if view_type == nil or view_type == 1 then return true end
    return false
end



local function auto_camera_remember_target(state, target, loc, current_turn)
    state.target_seen_turn = state.target_seen_turn or {}
    state.label_seen_turn = state.label_seen_turn or {}
    state.target_seen_turn[target.key] = current_turn
    state.label_seen_turn[target.label] = current_turn
    state.last_cycle_turn = current_turn
    state.last_target_key = target.key
    state.last_priority = target.priority
    state.last_location = loc
    state.last_label = target.label
    if AutoCamera.ideas.label_streak_guard and (target.priority or 0) < AutoCamera.low_priority_label_streak_cutoff then
        if state.label_streak_label == target.label then
            state.label_streak_count = (state.label_streak_count or 0) + 1
        else
            state.label_streak_label = target.label
            state.label_streak_count = 1
        end
    else
        state.label_streak_label = target.label
        state.label_streak_count = 1
    end
    state.debug_last_summary = tostring(target.label) .. " priority=" .. tostring(target.priority or 0) .. " score=" .. tostring(target.score or target.priority or 0)
    auto_camera_debug_message(state.debug_last_summary)
    -- priority smoothing: exponential moving average so adaptive_cycle has a stable signal
    if AutoCamera.ideas.priority_smoothing then
        state.smoothed_priority = (state.smoothed_priority or 0) * 0.75 + (target.priority or 0) * 0.25
    end
    -- heatmap recording: back the hotzone_revisit idea with real data
    if AutoCamera.ideas.hotzone_revisit and (target.label == "fight" or target.label == "door_breach" or target.label == "heart_danger" or target.label == "heart_panic") then
        state.heatmap = state.heatmap or {}
        local hk = tostring(loc.stl_x or 0) .. "," .. tostring(loc.stl_y or 0)
        state.heatmap[hk] = math.min((state.heatmap[hk] or 0) + 80, 800)
    end
    -- unit boost recording: creatures that got screen time earn a short revisit bonus
    if target.thing_idx then
        state.unit_boosts = state.unit_boosts or {}
        state.unit_boosts[target.thing_idx] = math.min((state.unit_boosts[target.thing_idx] or 0) + 30, 150)
        -- Deciding whether to follow from time to time
        if AutoCamera.ideas.follow_creature and math.random(1, 100) <= 35 then
            state.follow_thing_idx = target.thing_idx
        else
            state.follow_thing_idx = nil
        end
    else
        state.follow_thing_idx = nil
    end
end

local function auto_camera_pick_target(targets, force_new_target)
    if #targets <= 1 then return targets[1] end
    local state = auto_camera_state()
    local first = targets[1]
    if not force_new_target and first.key ~= state.last_target_key then return first end
    local best_score = first.score or first.priority or 0
    local score_floor = best_score - math.max(30, best_score * 0.25)
    local pool = {}
    for _, candidate in ipairs(targets) do
        local score = candidate.score or candidate.priority or 0
        if candidate.key ~= state.last_target_key and score >= score_floor then
            pool[#pool + 1] = candidate
        end
    end
    if #pool == 0 then return first end
    -- deterministic variety: rotate through equally-good candidates using the game turn
    if AutoCamera.ideas.deterministic_variety and #pool > 1 then
        local idx = ((PLAYER0.GAME_TURN or 0) % #pool) + 1
        return pool[idx]
    end
    return pool[1]
end

-- Sweep position table for quiet_sweep: defines a sequence of map positions to visit
-- during idle periods. This is computed lazily from map bounds and cached.
local function auto_camera_get_sweep_path()
    local state = auto_camera_state()
    if state.sweep_path_cache then return state.sweep_path_cache end
    local bounds = auto_camera_get_map_bounds()
    if not bounds then return {} end
    local pad = AutoCamera.sweep_pad_stl or 8
    local min_x = bounds.min_stl_x + pad
    local min_y = bounds.min_stl_y + pad
    local max_x = bounds.max_stl_x - pad
    local max_y = bounds.max_stl_y - pad
    if min_x >= max_x or min_y >= max_y then
        state.sweep_path_cache = { { stl_x = (min_x + max_x) / 2, stl_y = (min_y + max_y) / 2 } }
        return state.sweep_path_cache
    end
    local path = {}
    local mid_x = math.floor((min_x + max_x) / 2)
    local mid_y = math.floor((min_y + max_y) / 2)
    -- Define key vantage points: corners, edges, and center
    local points = {
        { stl_x = min_x, stl_y = min_y },
        { stl_x = max_x, stl_y = min_y },
        { stl_x = max_x, stl_y = max_y },
        { stl_x = min_x, stl_y = max_y },
        { stl_x = mid_x, stl_y = min_y },
        { stl_x = max_x, stl_y = mid_y },
        { stl_x = mid_x, stl_y = max_y },
        { stl_x = min_x, stl_y = mid_y },
        { stl_x = mid_x, stl_y = mid_y },
    }
    -- Zigzag pattern: start from one corner, sweep across the map
    for i = 1, #points do
        local p = points[i]
        path[#path + 1] = {
            val_x = p.stl_x * 256,
            val_y = p.stl_y * 256,
            stl_x = p.stl_x,
            stl_y = p.stl_y,
        }
    end
    state.sweep_path_cache = path
    return state.sweep_path_cache
end

-- Execute a quiet sweep step: move the camera along a precomputed path across the map
local function auto_camera_quiet_sweep_step()
    local state = auto_camera_state()
    local path = auto_camera_get_sweep_path()
    if #path == 0 then return end
    state.quiet_sweep_progress = state.quiet_sweep_progress or {
        index = 1,
        sub_tick = 0,
        max_sub_ticks = AutoCamera.sweep_speed_turns / math.max(1, #path),
    }
    local progress = state.quiet_sweep_progress
    progress.sub_tick = progress.sub_tick + 1
    if progress.sub_tick >= progress.max_sub_ticks then
        progress.sub_tick = 0
        progress.index = progress.index + 1
        if progress.index > #path then
            progress.index = 1
        end
    end
    local target = path[progress.index]
    if target then
        auto_camera_zoom_to_location(AutoCamera.player, target, AutoCamera.sweep_pad_stl)
    end
end

local function auto_camera_collect_targets()
    local targets, seen = {}, {}
    local state = auto_camera_state()
    local current_turn = PLAYER0 and PLAYER0.GAME_TURN or 0
    state.was_picked_up = state.was_picked_up or {}
    state.dropped_turns = state.dropped_turns or {}
    local active_imps = {}
    -- Track which rooms we've seen on this scenic_tour pass
    local scenic_tour_rooms = {}

    if AutoCamera.ideas.hotzone_revisit then
        if state.heatmap and (current_turn % 20 == 0) then
            for k, v in pairs(state.heatmap) do state.heatmap[k] = v * 0.8; if v < 5 then state.heatmap[k] = nil end end
        end
    end
    if state.unit_boosts and (current_turn % 10 == 0) then
        for k, v in pairs(state.unit_boosts) do state.unit_boosts[k] = v * 0.7; if v < 2 then state.unit_boosts[k] = nil end end
    end

    local player = PLAYER0
    if player then
        local creatures = GetCreaturesOfPlayer(player) or {}
        local has_non_imp = auto_camera_has_non_imp(player, creatures)
        local mining_avg_x, mining_avg_y, mining_count = 0, 0, 0

        -- AI decision boost: more aggressive/magical AI profiles increase camera priority
        local ai_boost = 0
        if AISupervisor and type(AISupervisor.GetAppliedDecisionProfile) == "function" then
            local profile, turn = AISupervisor.GetAppliedDecisionProfile(player)
            if profile and turn and (PLAYER0.GAME_TURN - turn) < 80 then
                ai_boost = math.floor((profile.aggression or 0.5) * 60 + (profile.magic or 0.5) * 30)
            end
        end

        -- HEART HEALTH MONITORING
        if player.heart and player.heart.health and player.heart.health > 0 then
            local heart_hp = player.heart.health
            local heart_max = player.heart.max_health or 1000
            if heart_max <= 0 then heart_max = 1000 end
            local ratio = heart_hp / heart_max
            if ratio < 0.20 then auto_camera_add_target(targets, seen, player.heart, player.heart.pos, 500 + math.floor((0.20 - ratio) * 2000) + ai_boost, "heart_panic")
            elseif ratio < 0.60 then auto_camera_add_target(targets, seen, player.heart, player.heart.pos, 150 + math.floor((0.60 - ratio) * 300) + ai_boost + 40, "heart_danger") end
        end

        -- CREATURE ITERATION: evaluate every creature for potential targets
        for _, creature in ipairs(creatures) do
            if safe_is_valid(creature) and creature.pos then
                local idx = creature.ThingIndex
                local is_picked_up = (creature.picked_up == true)

                if AutoCamera.ideas.drop_focus and idx then
                    if state.was_picked_up[idx] and not is_picked_up then
                        state.dropped_turns[idx] = current_turn
                    end
                    state.was_picked_up[idx] = is_picked_up
                end

                if not is_picked_up then
                    local is_imp = (creature.model == "IMP")
                    local state_lower = string.lower(tostring(creature.state or ""))
                    if AutoCamera.ideas.gold_mining_focus and is_imp and (string.find(state_lower, "mine") or string.find(state_lower, "dig")) then
                        mining_avg_x = mining_avg_x + creature.pos.val_x
                        mining_avg_y = mining_avg_y + creature.pos.val_y
                        mining_count = mining_count + 1
                    end

                    local is_digging = is_imp and (string.find(state_lower, "tunnel") or string.find(state_lower, "dig") or string.find(state_lower, "mine"))
                    local is_reinforcing = is_imp and string.find(state_lower, "reinforce")
                    local is_claiming = is_imp and (string.find(state_lower, "convert") or string.find(state_lower, "claim"))
                    local is_imp_active = is_digging or is_reinforcing or is_claiming

                    if is_imp_active then table.insert(active_imps, creature) end

                    if not (has_non_imp and is_imp and not is_imp_active) then
                        local drop_bonus = 0
                        if (AutoCamera.ideas.drop_focus or AutoCamera.ideas.post_possession) and idx and state.dropped_turns[idx] then
                            local turns_since_drop = current_turn - state.dropped_turns[idx]
                            if turns_since_drop < 80 then drop_bonus = 160 - turns_since_drop * 2 end
                        end
                        local health_ratio = auto_camera_health_ratio(creature)
                        local opponents = creature.opponents_count or 0
                        if opponents > 0 then
                            -- Only track human's creatures in the fight, no enemy averaging
                            local avg_x, avg_y, count = creature.pos.val_x, creature.pos.val_y, 1
                            for _, other in ipairs(creatures) do
                                if other ~= creature and safe_is_valid(other) and other.pos and auto_camera_dist_sq(creature.pos, other.pos) < (1536 * 1536) then
                                    avg_x, avg_y, count = avg_x + other.pos.val_x, avg_y + other.pos.val_y, count + 1
                                end
                            end
                            local battle_pos = { val_x = math.floor(avg_x / count), val_y = math.floor(avg_y / count), val_z = creature.pos.val_z, stl_x = math.floor((avg_x / count) / 256), stl_y = math.floor((avg_y / count) / 256) }
                            local heat_bonus = 0
                            local heat_val = 0  -- For first_blood check
                            if AutoCamera.ideas.hotzone_revisit then
                                local heat = state.heatmap and state.heatmap[battle_pos.stl_x .. "," .. battle_pos.stl_y] or 0
                                heat_bonus = math.floor(math.min(heat / 3, 200) * 2)
                                heat_val = heat
                            end
                            local fight_priority = 1000 + opponents * 60 + math.floor((1 - health_ratio) * 200) + ai_boost + heat_bonus

                            if AutoCamera.ideas.first_blood and heat_val < 5 then
                                fight_priority = fight_priority + 200
                            end

                            if AutoCamera.ideas.epic_moment_focus then
                                if creature.model == "HORNY" or creature.model == "AVATAR" or (creature.level or 1) == 10 then fight_priority = fight_priority + 500 end
                                fight_priority = fight_priority + (count * 25)
                                if count >= 6 then fight_priority = fight_priority + 200 end
                            end
                            auto_camera_add_target(targets, seen, creature, battle_pos, fight_priority, "fight", count)
                        elseif creature.state == "CreatureInTorture" or creature.state == "CreatureInScavenge" or (AutoCamera.ideas.temple_sacrifice and (string.find(state_lower, "sacrifice") or string.find(state_lower, "temple"))) then
                            local prio = 160 + math.floor(ai_boost * 0.5)
                            if AutoCamera.ideas.torture_climax and creature.state == "CreatureInTorture" then
                                prio = prio + math.floor((1 - health_ratio) * 150)
                            elseif AutoCamera.ideas.temple_sacrifice and string.find(state_lower, "sacrifice") then
                                prio = 200
                            end
                            auto_camera_add_target(targets, seen, creature, creature.pos, prio, "action")
                        elseif AutoCamera.ideas.rebellion_focus and (creature.state == "CreatureRebel" or creature.state == "CreatureLeaveDungeon") then
                            auto_camera_add_target(targets, seen, creature, creature.pos, 400, "rebellion")
                        elseif AutoCamera.ideas.payday_anger and string.find(state_lower, "angry") then
                            auto_camera_add_target(targets, seen, creature, creature.pos, 230, "payday_anger")
                        elseif AutoCamera.ideas.hunger_warning and string.find(state_lower, "hungry") then
                            auto_camera_add_target(targets, seen, creature, creature.pos, 220, "hunger_warning")
                        elseif AutoCamera.ideas.slap_reaction and string.find(state_lower, "slap") then
                            auto_camera_add_target(targets, seen, creature, creature.pos, 180, "slap_reaction")
                        elseif AutoCamera.ideas.victory_cheer and string.find(state_lower, "cheer") then
                            auto_camera_add_target(targets, seen, creature, creature.pos, 150, "victory_cheer")
                        elseif AutoCamera.ideas.party_focus and (string.find(state_lower, "party") or string.find(state_lower, "celebrate") or string.find(state_lower, "drink")) then
                            if current_turn - (state.last_party_turn or -9999) >= 60 then
                                state.last_party_turn = current_turn
                                auto_camera_add_target(targets, seen, creature, creature.pos, 65, "party")
                            end
                        elseif is_digging then
                            auto_camera_add_target(targets, seen, creature, creature.pos, 140 + math.floor(ai_boost * 0.5), "imp_dig")
                        elseif is_claiming then
                            auto_camera_add_target(targets, seen, creature, creature.pos, 130 + math.floor(ai_boost * 0.5), "imp_claim")
                        elseif is_reinforcing then
                            auto_camera_add_target(targets, seen, creature, creature.pos, 110 + math.floor(ai_boost * 0.4), "imp_reinforce")
                        elseif AutoCamera.ideas.gold_carrying_focus and (creature.gold_held or 0) >= 250 then
                            auto_camera_add_target(targets, seen, creature, creature.pos, 80 + math.min((creature.gold_held or 0) / 25, 100), "gold_carrying")
                        elseif creature.model == "IMP" and health_ratio < 0.70 then
                            auto_camera_add_target(targets, seen, creature, creature.pos, 100 + math.floor((1 - health_ratio) * 40), "imp")
                        elseif health_ratio < 0.45 then
                            auto_camera_add_target(targets, seen, creature, creature.pos, 90 + math.floor((1 - health_ratio) * 50) + math.floor(ai_boost * 0.3), "wounded")
                        elseif AutoCamera.ideas.fleeing_focus and (string.find(state_lower, "flee") or string.find(state_lower, "panic")) then
                            auto_camera_add_target(targets, seen, creature, creature.pos, 150 + (creature.level or 1) * 5, "fleeing")
                        elseif (creature.level or 1) >= 9 then
                            local is_eoi = (creature.model == "HORNY" or creature.model == "AVATAR")
                            auto_camera_add_target(targets, seen, creature, creature.pos, 75 + (creature.level or 1) + math.floor(ai_boost * 0.4) + (is_eoi and 50 or 0), "hero", 1, is_eoi)
                        else
                            local unit_boost = state.unit_boosts and creature.ThingIndex and state.unit_boosts[creature.ThingIndex] or 0
                            local activity_bonus = (creature.state ~= "CreatureDoingNothing") and 10 or 0
                            local is_training = (creature.workroom and creature.workroom.type == "TRAINING")
                                                or (creature.state == "CreatureTraining" or creature.state == "AtTrainingRoom" or creature.state == "CreatureAtTrainingRoom" or creature.state == "Training")
                            local base_prio = 15
                            if is_training then
                                base_prio = 2
                                activity_bonus = 0
                            end
                            auto_camera_add_target(targets, seen, creature, creature.pos, base_prio + (creature.level or 1) + unit_boost + activity_bonus, "creature")
                        end

                        if drop_bonus > 0 and targets[#targets] and targets[#targets].thing_idx == idx then
                            targets[#targets].priority = targets[#targets].priority + drop_bonus
                        end
                    end
                end
            end
        end

        -- GOLD MINING FOCUS (idea 34): highlight areas where imps are currently mining
        if AutoCamera.ideas.gold_mining_focus then
            if mining_count >= 3 and current_turn - (state.last_gold_mining_turn or -9999) >= 80 then
                state.last_gold_mining_turn = current_turn
                local mining_pos = {
                    val_x = math.floor(mining_avg_x / mining_count),
                    val_y = math.floor(mining_avg_y / mining_count),
                    stl_x = math.floor((mining_avg_x / mining_count) / 256),
                    stl_y = math.floor((mining_avg_y / mining_count) / 256),
                }
                auto_camera_add_target(targets, seen, nil, mining_pos, 130 + math.floor(ai_boost * 0.5), "gold_mining")
            end
        end

        -- IMP SWARM DETECTION (idea 37): cluster active imps and highlight large groups
        if AutoCamera.ideas.imp_swarm and #active_imps > 0 then
            local clusters = {}
            for _, imp in ipairs(active_imps) do
                local found = false
                for _, cluster in ipairs(clusters) do
                    if auto_camera_dist_sq(imp.pos, cluster.pos) < 1536 * 1536 then
                        cluster.count = cluster.count + 1
                        cluster.sum_x = cluster.sum_x + imp.pos.val_x
                        cluster.sum_y = cluster.sum_y + imp.pos.val_y
                        cluster.pos = {
                            val_x = math.floor(cluster.sum_x / cluster.count),
                            val_y = math.floor(cluster.sum_y / cluster.count),
                            stl_x = math.floor((cluster.sum_x / cluster.count) / 256),
                            stl_y = math.floor((cluster.sum_y / cluster.count) / 256)
                        }
                        found = true
                        break
                    end
                end
                if not found then table.insert(clusters, { count = 1, sum_x = imp.pos.val_x, sum_y = imp.pos.val_y, pos = imp.pos }) end
            end
            for _, cluster in ipairs(clusters) do
                if cluster.count >= 3 then
                    auto_camera_add_target(targets, seen, nil, cluster.pos, 150 + cluster.count * 10 + math.floor(ai_boost * 0.5), "imp_swarm", cluster.count)
                end
            end
        end

        -- BANKRUPTCY WARNING (Idea 45)
        if AutoCamera.ideas.bankruptcy_warning then
            local p_money = 0
            pcall(function() p_money = player.money end)
            if not p_money and type(GetPlayerMoney) == "function" then
                pcall(function() p_money = GetPlayerMoney(player) end)
            end
            if (p_money or 0) < AutoCamera.bankruptcy_threshold and #creatures > 10 and player.heart and player.heart.pos then
                auto_camera_add_target(targets, seen, player.heart, player.heart.pos, 180, "bankruptcy_warning")
            end
        end

        -- OVERCROWDED PRISON WARNING (Idea 50)
        if AutoCamera.ideas.prison_warning and type(GetRoomsOfPlayerAndType) == "function" and type(GetCreaturesInRoom) == "function" then
            pcall(function()
                for _, room in ipairs(GetRoomsOfPlayerAndType(player, "PRISON") or {}) do
                    local units = GetCreaturesInRoom(room) or {}
                    if #units > AutoCamera.prison_overcrowd_threshold and room.centerpos then
                        auto_camera_add_target(targets, seen, nil, room.centerpos, 190, "prison_warning")
                    end
                end
            end)
        end

        -- TREASURY WARNING (Idea 60)
        if AutoCamera.ideas.treasury_warning and type(GetRoomsOfPlayerAndType) == "function" then
            pcall(function()
                for _, room in ipairs(GetRoomsOfPlayerAndType(player, "TREASURE") or {}) do
                    if room.gold and room.capacity and room.gold >= room.capacity * AutoCamera.treasury_full_threshold and room.centerpos then
                        auto_camera_add_target(targets, seen, nil, room.centerpos, 185, "treasury_warning")
                    end
                end
            end)
        end

        -- PARTY FOCUS (Idea 54): Handled in main creature loop above

        -- COMBAT TRAINING FOCUS (Idea 33): prioritise training rooms with creatures training
        if AutoCamera.ideas.combat_training_focus and type(GetRoomsOfPlayerAndType) == "function" and type(GetCreaturesInRoom) == "function" then
            pcall(function()
                for _, room in ipairs(GetRoomsOfPlayerAndType(player, "TRAINING") or {}) do
                    local units = GetCreaturesInRoom(room) or {}
                    if #units >= 1 and room.centerpos then
                        auto_camera_add_target(targets, seen, nil, room.centerpos, 75 + math.min(#units * 6, 50), "combat_training", #units)
                    end
                end
            end)
        end

        -- BARRACKS FOCUS (Idea 43): highlight barracks/guardroom where creatures are stationed
        if AutoCamera.ideas.barracks_focus and type(GetRoomsOfPlayerAndType) == "function" and type(GetCreaturesInRoom) == "function" then
            pcall(function()
                for _, r_type in ipairs({"BARRACKS", "GUARDROOM"}) do
                    for _, room in ipairs(GetRoomsOfPlayerAndType(player, r_type) or {}) do
                        local units = GetCreaturesInRoom(room) or {}
                        if #units >= 1 and room.centerpos then
                            auto_camera_add_target(targets, seen, nil, room.centerpos, 60 + math.min(#units * 8, 60), "barracks", #units)
                        end
                    end
                end
            end)
        end
    end

    -- SCENIC ROOMS: show a variety of rooms during quiet periods (max_prio < 40)
    local max_prio = 0
    for _, t in ipairs(targets) do if t.priority > max_prio then max_prio = t.priority end end
    if max_prio < 40 then
        local found_scenic_room = false
        if player and type(GetRoomsOfPlayerAndType) == "function" then
            for _, r_type in ipairs({"TEMPLE", "RESEARCH", "TRAINING", "WORKSHOP", "GRAVEYARD", "PRISON", "SCAVENGER", "LIBRARY"}) do
                local ok_rooms, rooms = pcall(function() return GetRoomsOfPlayerAndType(player, r_type) end)
                if ok_rooms and rooms then
                    for _, room in ipairs(rooms) do
                        local ok, center = pcall(function() return room.centerpos end)
                        if ok and center then
                            found_scenic_room = true
                            local prio = 30
                            if r_type == "TRAINING" then
                                prio = 12
                            elseif r_type == "TEMPLE" then
                                prio = 35
                            elseif r_type == "LIBRARY" then
                                if type(GetCreaturesInRoom) == "function" then
                                    local ok_units, units = pcall(function() return GetCreaturesInRoom(room) end)
                                    units = (ok_units and units) or {}
                                    if #units > 0 then prio = 20 + #units * 5 end
                                end
                            elseif AutoCamera.ideas.workshop_focus and r_type == "WORKSHOP" then
                                if type(GetCreaturesInRoom) == "function" then
                                    local ok_units, units = pcall(function() return GetCreaturesInRoom(room) end)
                                    units = (ok_units and units) or {}
                                    if #units > 0 then prio = 45 + #units * 8 end
                                end
                            elseif AutoCamera.ideas.scavenge_focus and r_type == "SCAVENGER" then
                                if type(GetCreaturesInRoom) == "function" then
                                    local ok_units, units = pcall(function() return GetCreaturesInRoom(room) end)
                                    units = (ok_units and units) or {}
                                    if #units > 0 then prio = 40 + #units * 8 end
                                end
                            end
                            if (r_type == "PRISON" or r_type == "GRAVEYARD") and type(GetCreaturesInRoom) == "function" then
                                local ok_units, units = pcall(function() return GetCreaturesInRoom(room) end)
                                units = (ok_units and units) or {}
                                if #units > 0 then prio = prio + 15 + #units * 2 end
                            end
                            auto_camera_add_target(targets, seen, nil, center, prio, "scenic_room")
                            scenic_tour_rooms[#scenic_tour_rooms + 1] = { room = room, center = center, r_type = r_type }
                        end
                    end
                end
            end
        end
        if not found_scenic_room and player and player.heart and player.heart.pos then
            auto_camera_add_target(targets, seen, player.heart, player.heart.pos, 35, "scenic_heart")
        end

        -- scenic_tour (idea 44): add extra low-priority room targets for variety
        if AutoCamera.ideas.scenic_tour and found_scenic_room then
            for _, entry in ipairs(scenic_tour_rooms) do
                local room_key = nil
                pcall(function() room_key = entry.room and entry.room.room_idx end)
                local key = "scenic_tour:" .. tostring(entry.r_type) .. ":" .. tostring(room_key or (entry.center.stl_x or 0) .. "," .. (entry.center.stl_y or 0))
                if not seen[key] then
                    seen[key] = true
                    local tour_prio = 8 + math.random(1, 8) -- Small random spread to avoid monotony
                    targets[#targets + 1] = { key = key, location = entry.center, priority = tour_prio, label = "scenic_tour", participants = 1, thing_idx = nil }
                end
            end
        end
    end

    table.sort(targets, function(a, b) return a.priority > b.priority end)
    while #targets > AutoCamera.max_targets do table.remove(targets) end
    return targets
end

function AutoCamera.Toggle(enabled, cinematic)
    local state = auto_camera_state()
    state.enabled = (enabled == nil) and (not state.enabled) or (enabled == true)
    if cinematic ~= nil then state.cinematic = cinematic == true end
    AutoCamera.enabled, AutoCamera.cinematic = state.enabled, state.cinematic
    state.last_cycle_turn, state.last_target_index, state.last_target_key = -9999, 0, nil
    state.follow_thing_idx = nil
    state.locked_battle = nil
    state.quiet_sweep_progress = nil
    state.consecutive_tick_errors = 0
    state.last_tick_error = nil
    if type(QuickMessage) == "function" then
        local msg = state.enabled and "Auto camera enabled" or "Auto camera disabled"
        if state.enabled and state.cinematic then msg = msg .. " (Cinematic Mode)" end
        QuickMessage(msg, "QUERY")
    end
end

function AutoCamera.ApplyProfile(profile_name, announce)
    local name = string.lower(tostring(profile_name or "balanced"))
    local profile = AutoCamera.profiles[name]
    if not profile then return false end
    AutoCamera.active_profile = name
    AutoCamera.cycle_interval_turns = profile.cycle_interval_turns
    AutoCamera.fight_interrupt_cooldown_turns = profile.fight_interrupt_cooldown_turns
    AutoCamera.fight_same_target_grace_turns = profile.fight_same_target_grace_turns
    AutoCamera.fight_retarget_distance_sq = profile.fight_retarget_distance_sq
    AutoCamera.max_interrupt_queue = profile.max_interrupt_queue
    AutoCamera.cinematic_orbit_amp = profile.cinematic_orbit_amp
    AutoCamera.cinematic_orbit_speed_x = profile.cinematic_orbit_speed_x
    AutoCamera.cinematic_orbit_speed_y = profile.cinematic_orbit_speed_y
    AutoCamera.micro_pan_strength = profile.micro_pan_strength
    AutoCamera.proximity_limit_normal_sq = profile.proximity_limit_normal_sq
    AutoCamera.proximity_limit_cinematic_sq = profile.proximity_limit_cinematic_sq
    AutoCamera.anti_pingpong_distance_sq = profile.anti_pingpong_distance_sq
    if announce and type(QuickMessage) == "function" then QuickMessage("AutoCam profile: " .. AutoCamera.active_profile .. ".", "QUERY") end
    return true
end

function AutoCamera.Tick()
    local state = auto_camera_state()
    if not state.enabled then
        -- Clean up sweep state when disabled
        state.quiet_sweep_progress = nil
        return
    end
    AutoCamera.player = AutoCamera.player or PLAYER0
    local player = AutoCamera.player
    if not player then return end
    if not auto_camera_can_move_player(player) and not state.eyes_mode then return end

    local current_turn = player.GAME_TURN or 0

    if AutoCamera.ideas.post_possession then
        local view_type = player.VIEW_TYPE or 1
        -- Use last_view_type with nil-safe check: first tick after enable has last_view_type=1,
        -- so this won't fire until we've actually been in possession mode and then left it.
        if state.last_view_type and (state.last_view_type == 2 or state.last_view_type == 3) and (view_type == 1 or view_type == 0) then
            if state.possessed_idx then
                state.dropped_turns[state.possessed_idx] = current_turn
                state.possessed_idx = nil
            end
        elseif view_type == 2 or view_type == 3 then
            for _, cr in ipairs(GetCreaturesOfPlayer(player) or {}) do
                if safe_is_valid(cr) and string.find(string.lower(tostring(cr.state or "")), "possess") then
                    state.possessed_idx = cr.ThingIndex
                    break
                end
            end
        end
        state.last_view_type = view_type
    end

    if state.eyes_mode then
        local current_creature = nil
        if player.VIEW_TYPE == 2 and state.follow_thing_idx then
             current_creature = GetThingByIdx(state.follow_thing_idx)
             if not safe_is_valid(current_creature) or current_creature.owner ~= player or (current_creature.health or 1) <= 0 then
                 current_creature = nil
             end
        end

        local find_new = (current_creature == nil)
        if not find_new and AutoCamera.ideas.eyes_mode_cycle and current_turn - (state.last_eyes_cycle_turn or 0) > 400 then
            find_new = true
        end

        if not find_new and current_creature and current_creature.model == "IMP" then
            if auto_camera_has_non_imp(player) then
                find_new = true
            end
        end

        if find_new then
            local creatures = GetCreaturesOfPlayer(player) or {}
            local pool = {}
            local first_imp = nil
            for _, cr in ipairs(creatures) do
                if safe_is_valid(cr) and (cr.health or 1) > 0 and cr.picked_up ~= true then
                    if cr.model ~= "IMP" then
                        table.insert(pool, cr)
                    elseif not first_imp then
                        first_imp = cr
                    end
                end
            end

            local best = nil
            if #pool > 0 then
                -- Pick a random non-imp creature to cycle through the dungeon organically
                best = pool[math.random(1, #pool)]
            end
            best = best or first_imp

            if best then
                state.follow_thing_idx = best.ThingIndex
                state.last_eyes_cycle_turn = current_turn
                pcall(function() ControlCreaturePassenger(best) end)
                pcall(function() SetActiveLens(0) end)
            else
                state.eyes_mode = false
                player.VIEW_TYPE = 1
            end
        end
        return
    end

    -- BATTLE LOCK CHECK: Focus on one battle until it ends
    if AutoCamera.ideas.fight_anchor_lock and state.locked_battle then
        local has_critical_interrupt = false
        if state.interrupt_queue and #state.interrupt_queue > 0 then
            if state.interrupt_queue[1].priority >= 2000 then
                has_critical_interrupt = true
            end
        end

        local battle_duration = current_turn - (state.locked_battle.start_turn or current_turn)
        if has_critical_interrupt or battle_duration > 800 then
            state.locked_battle = nil
        else
            local creatures = GetCreaturesOfPlayer(player) or {}
            local has_non_imp = auto_camera_has_non_imp(player, creatures)
            local avg_x, avg_y, count = 0, 0, 0
            local battle_radius_sq = AutoCamera.fight_retarget_distance_sq

            for _, creature in ipairs(creatures) do
                if safe_is_valid(creature) and creature.pos and creature.picked_up ~= true and not (has_non_imp and creature.model == "IMP") then
                    local opponents = creature.opponents_count or 0
                    if opponents > 0 then
                        local dist_sq = auto_camera_dist_sq(creature.pos, state.locked_battle)
                        if dist_sq <= battle_radius_sq then
                            avg_x, avg_y, count = avg_x + creature.pos.val_x, avg_y + creature.pos.val_y, count + 1
                        end
                    end
                end
            end

            if count > 0 then
                local battle_pos = {
                    val_x = math.floor(avg_x / count),
                    val_y = math.floor(avg_y / count),
                    stl_x = math.floor((avg_x / count) / 256),
                    stl_y = math.floor((avg_y / count) / 256)
                }
                local base_loc = auto_camera_sanitize_location(battle_pos, 2)
                if base_loc then
                    local view_loc = { val_x = base_loc.val_x, val_y = base_loc.val_y, stl_x = base_loc.stl_x, stl_y = base_loc.stl_y }

                    if state.cinematic and AutoCamera.ideas.cinematic_orbit then
                        state.orbit_phase = (state.orbit_phase or 0) + 1
                        local speed_mod = 1.0
                        -- Composite wave for organic premium orbiting
                        local ox = math.floor((math.sin(state.orbit_phase * AutoCamera.cinematic_orbit_speed_x * speed_mod) + math.sin(state.orbit_phase * AutoCamera.cinematic_orbit_speed_x * 0.43 * speed_mod) * 0.4) * AutoCamera.cinematic_orbit_amp * 0.71)
                        local oy = math.floor((math.cos(state.orbit_phase * AutoCamera.cinematic_orbit_speed_y * speed_mod) + math.sin(state.orbit_phase * AutoCamera.cinematic_orbit_speed_y * 0.37 * speed_mod) * 0.4) * AutoCamera.cinematic_orbit_amp * 0.71)
                        view_loc.val_x = view_loc.val_x + ox
                        view_loc.val_y = view_loc.val_y + oy
                    end

                    if AutoCamera.ideas.micro_pan then
                        local pan_amp = math.floor(AutoCamera.micro_pan_strength * 256)
                        -- Organic multi-frequency handheld camera shake
                        local px = math.floor((math.sin(current_turn * 0.05) + math.sin(current_turn * 0.031) * 0.5) * pan_amp * 0.66)
                        local py = math.floor((math.cos(current_turn * 0.037) + math.sin(current_turn * 0.043) * 0.5) * pan_amp * 0.66)
                        view_loc.val_x = view_loc.val_x + px
                        view_loc.val_y = view_loc.val_y + py
                    end

                    -- adaptive_offset (idea 14): subtle screen position offsets based on battle composition
                    if AutoCamera.ideas.adaptive_offset then
                        state.adaptive_phase = (state.adaptive_phase or 0) + 1
                        local offset_amp = math.floor(AutoCamera.micro_pan_strength * 128)
                        local ox = math.floor(math.sin(state.adaptive_phase * 0.027 + count * 0.5) * offset_amp * 0.5)
                        local oy = math.floor(math.cos(state.adaptive_phase * 0.033 + count * 0.3) * offset_amp * 0.5)
                        view_loc.val_x = view_loc.val_x + ox
                        view_loc.val_y = view_loc.val_y + oy
                    end

                    view_loc = auto_camera_sanitize_location(view_loc, 2) or view_loc
                    auto_camera_zoom_to_location(player, view_loc, 2)

                    state.locked_battle.val_x = battle_pos.val_x
                    state.locked_battle.val_y = battle_pos.val_y
                    state.locked_battle.stl_x = battle_pos.stl_x
                    state.locked_battle.stl_y = battle_pos.stl_y

                    state.label_seen_turn = state.label_seen_turn or {}
                    state.label_seen_turn["fight"] = current_turn
                    if state.locked_battle.key then
                        state.target_seen_turn = state.target_seen_turn or {}
                        state.target_seen_turn[state.locked_battle.key] = current_turn
                    end

                    state.last_location = base_loc
                    state.last_cycle_turn = current_turn
                    state.last_label = "fight"
                    state.follow_thing_idx = nil

                    if AutoCamera.ideas.hotzone_revisit and state.heatmap and (current_turn % 20 == 0) then
                        local hk = tostring(battle_pos.stl_x) .. "," .. tostring(battle_pos.stl_y)
                        state.heatmap[hk] = math.min((state.heatmap[hk] or 0) + 80, 800)
                    end

                    return
                else
                    -- sanitize_location failed; clear the battle lock to avoid infinite loop
                    state.locked_battle = nil
                end
            else
                state.locked_battle = nil
            end
        end
    end

    -- HEART STRIKE DETECTION: detect sudden HP drops and queue a top-priority interrupt
    if player and player.heart and player.heart.health then
        local cur_hh = player.heart.health
        if not state.heart_check_turn or current_turn - state.heart_check_turn >= 10 then
            local last_hh = state.last_heart_health
            if last_hh and last_hh > 0 and cur_hh < last_hh - 20 and player.heart.pos then
                auto_camera_queue_interrupt(player.heart.pos, 2100, "heart_strike")
            elseif cur_hh < 200 and (current_turn - (state.last_heart_panic_turn or -9999)) >= 150 then
                state.last_heart_panic_turn = current_turn
                auto_camera_queue_interrupt(player.heart.pos, 500, "heart_panic")
            end
            state.last_heart_health = cur_hh
            state.heart_check_turn = current_turn
        end
    end

    -- GOLD MILESTONE DETECTION (idea 32)
    if player and AutoCamera.ideas.gold_milestone_focus and player.TOTAL_GOLD_MINED and not auto_camera_has_non_imp(player) then
        local cur_gold = player.TOTAL_GOLD_MINED
        if cur_gold > (state.last_gold_mined or 0) + AutoCamera.gold_milestone_interval then
            state.last_gold_mined = cur_gold
            -- Find an imp mining gold
            for _, cr in ipairs(GetCreaturesOfPlayer(player) or {}) do
                if cr.model == "IMP" and cr.state == "CreatureMining" then
                    auto_camera_queue_interrupt(cr.pos, 200, "gold_milestone")
                    break
                end
            end
        end
    end

    -- PRIORITY BATTLE CHECK: if we're not already watching a fight, check for new battles
    if state.last_label ~= "fight" or (current_turn % 10 == 0) then
        local raw = auto_camera_collect_targets()
        if #raw > 0 then
            auto_camera_score_targets(raw)
            local top = raw[1]
            if top.label == "fight" and ((state.last_label ~= "fight") or (top.key ~= state.last_target_key)) then
                -- Check fight same-target grace period: don't switch battles too soon
                if top.key ~= state.last_target_key and state.fight_grace_last_key == top.key and state.fight_grace_turn and current_turn - state.fight_grace_turn < AutoCamera.fight_same_target_grace_turns then
                    return
                end
                local loc = auto_camera_sanitize_location(top.location, 2)
                if loc then
                    auto_camera_zoom_to_location(AutoCamera.player, loc, 2)
                    auto_camera_remember_target(state, top, loc, current_turn)
                    state.fight_grace_last_key = top.key
                    state.fight_grace_turn = current_turn
                    if AutoCamera.ideas.fight_anchor_lock then
                        state.locked_battle = {
                            val_x = loc.val_x,
                        val_y = loc.val_y,
                        stl_x = loc.stl_x,
                        stl_y = loc.stl_y,
                        start_turn = current_turn,
                            key = top.key
                        }
                    end
                    return
                end
            end
        end
    end

    if AutoCamera.ideas.interrupt_queue and auto_camera_try_flush_interrupt_queue(current_turn) then return end

    -- POST-EVENT HOLD: lock camera on important events before resuming normal cycle
    if AutoCamera.ideas.post_event_hold and current_turn < (state.hold_until_turn or -9999) then return end

    -- ADAPTIVE CYCLE: shorten cycle when action is hot, lengthen during quiet periods
    local adaptive_factor = 1.0
    if AutoCamera.ideas.adaptive_cycle then
        local sp = state.smoothed_priority or 0
        -- Continuous smooth scaling: higher action intensity leads to smoothly faster camera cycles
        local intensity_ratio = math.min(1.0, math.max(0, sp / 800))
        adaptive_factor = 1.4 - (intensity_ratio * 0.8) -- Scales smoothly from 1.4 down to 0.6
    end
    local wait = AutoCamera.cycle_interval_turns * (state.cinematic and 1.8 or 1.0) * adaptive_factor

    if current_turn - (state.last_cycle_turn or -9999) < wait then
        -- We are in the wait period. Should we follow?
        if AutoCamera.ideas.follow_creature and state.follow_thing_idx then
            local thing = GetThingByIdx(state.follow_thing_idx)
            if safe_is_valid(thing) and thing.pos then
                -- Follow the creature by centering on it every tick
                auto_camera_zoom_to_location(AutoCamera.player, thing.pos, 2)
            else
                state.follow_thing_idx = nil
            end
        elseif state.last_location then
            local view_loc = { val_x = state.last_location.val_x, val_y = state.last_location.val_y, stl_x = state.last_location.stl_x, stl_y = state.last_location.stl_y }
            local moved = false
            
            if state.cinematic and AutoCamera.ideas.cinematic_orbit then
                state.orbit_phase = (state.orbit_phase or 0) + 1
                local speed_mod = 1.0 + ((state.last_priority or 0) / 1000)
                -- Organic composite orbit
                local ox = math.floor((math.sin(state.orbit_phase * AutoCamera.cinematic_orbit_speed_x * speed_mod) + math.sin(state.orbit_phase * AutoCamera.cinematic_orbit_speed_x * 0.43 * speed_mod) * 0.4) * AutoCamera.cinematic_orbit_amp * 0.71)
                local oy = math.floor((math.cos(state.orbit_phase * AutoCamera.cinematic_orbit_speed_y * speed_mod) + math.sin(state.orbit_phase * AutoCamera.cinematic_orbit_speed_y * 0.37 * speed_mod) * 0.4) * AutoCamera.cinematic_orbit_amp * 0.71)
                view_loc.val_x = view_loc.val_x + ox
                view_loc.val_y = view_loc.val_y + oy
                moved = true
            end

            if AutoCamera.ideas.micro_pan then
                local pan_amp = math.floor(AutoCamera.micro_pan_strength * 256)
                -- Organic handheld shake
                local px = math.floor((math.sin(current_turn * 0.05) + math.sin(current_turn * 0.031) * 0.5) * pan_amp * 0.66)
                local py = math.floor((math.cos(current_turn * 0.037) + math.sin(current_turn * 0.043) * 0.5) * pan_amp * 0.66)
                view_loc.val_x = view_loc.val_x + px
                view_loc.val_y = view_loc.val_y + py
                moved = true
            end

            -- adaptive_offset (idea 14): subtle organic drift when dwelling on the same target
            if AutoCamera.ideas.adaptive_offset then
                state.adaptive_phase = (state.adaptive_phase or 0) + 1
                local offset_amp = math.floor(AutoCamera.micro_pan_strength * 128)
                local ox = math.floor(math.sin(state.adaptive_phase * 0.021) * offset_amp * 0.5)
                local oy = math.floor(math.cos(state.adaptive_phase * 0.027) * offset_amp * 0.5)
                view_loc.val_x = view_loc.val_x + ox
                view_loc.val_y = view_loc.val_y + oy
                moved = true
            end

            if moved then
                view_loc = auto_camera_sanitize_location(view_loc, 2) or view_loc
                auto_camera_zoom_to_location(AutoCamera.player, view_loc, 2)
            end
        end
        return
    end

    state.interrupt_active = false
    local targets = auto_camera_collect_targets()
    if #targets <= 0 then
        -- No targets at all: if quiet_sweep is enabled, perform a sweep step instead of doing nothing
        if AutoCamera.ideas.quiet_sweep then
            auto_camera_quiet_sweep_step()
        end
        return
    end
    auto_camera_score_targets(targets)

    local target = auto_camera_pick_target(targets, state.force_next_target == true)
    state.force_next_target = false
    local base_loc = auto_camera_sanitize_location(target.location, 2)
    if not base_loc then
        -- Could not sanitize target location; try quiet sweep fallback
        if AutoCamera.ideas.quiet_sweep then
            auto_camera_quiet_sweep_step()
        end
        return
    end

    local view_loc = { val_x = base_loc.val_x, val_y = base_loc.val_y, stl_x = base_loc.stl_x, stl_y = base_loc.stl_y }

    if state.cinematic and AutoCamera.ideas.cinematic_orbit then
        state.orbit_phase = (state.orbit_phase or 0) + 1
        local speed_mod = 1.0 + (target.priority / 1000)
        -- Organic composite orbit
        local ox = math.floor((math.sin(state.orbit_phase * AutoCamera.cinematic_orbit_speed_x * speed_mod) + math.sin(state.orbit_phase * AutoCamera.cinematic_orbit_speed_x * 0.43 * speed_mod) * 0.4) * AutoCamera.cinematic_orbit_amp * 0.71)
        local oy = math.floor((math.cos(state.orbit_phase * AutoCamera.cinematic_orbit_speed_y * speed_mod) + math.sin(state.orbit_phase * AutoCamera.cinematic_orbit_speed_y * 0.37 * speed_mod) * 0.4) * AutoCamera.cinematic_orbit_amp * 0.71)
        view_loc.val_x = view_loc.val_x + ox
        view_loc.val_y = view_loc.val_y + oy
    end

    if AutoCamera.ideas.micro_pan and target.key == state.last_target_key then
        local pan_amp = math.floor(AutoCamera.micro_pan_strength * 256)
        -- Organic handheld shake
        local px = math.floor((math.sin(current_turn * 0.05) + math.sin(current_turn * 0.031) * 0.5) * pan_amp * 0.66)
        local py = math.floor((math.cos(current_turn * 0.037) + math.sin(current_turn * 0.043) * 0.5) * pan_amp * 0.66)
        view_loc.val_x = view_loc.val_x + px
        view_loc.val_y = view_loc.val_y + py
    end

    -- adaptive_offset (idea 14): subtle screen position offsets when zooming to a new target
    if AutoCamera.ideas.adaptive_offset then
        state.adaptive_phase = (state.adaptive_phase or 0) + 1
        local offset_amp = math.floor(AutoCamera.micro_pan_strength * 128)
        local ox = math.floor(math.sin(state.adaptive_phase * 0.023 + (target.priority or 0) * 0.0005) * offset_amp * 0.5)
        local oy = math.floor(math.cos(state.adaptive_phase * 0.029 + (target.priority or 0) * 0.0004) * offset_amp * 0.5)
        view_loc.val_x = view_loc.val_x + ox
        view_loc.val_y = view_loc.val_y + oy
    end

    view_loc = auto_camera_sanitize_location(view_loc, 2) or view_loc
    auto_camera_zoom_to_location(AutoCamera.player, view_loc, 2)
    auto_camera_remember_target(state, target, base_loc, current_turn)

    if target.label == "fight" and AutoCamera.ideas.fight_anchor_lock then
        state.locked_battle = {
            val_x = base_loc.val_x,
            val_y = base_loc.val_y,
            stl_x = base_loc.stl_x,
            stl_y = base_loc.stl_y,
            start_turn = current_turn,
            key = target.key
        }
        if AutoCamera.ideas.post_event_hold then
            state.hold_until_turn = current_turn + 15
        end
    else
        state.locked_battle = nil
    end

    -- Reset sweep progress when we actually show something meaningful
    if AutoCamera.ideas.quiet_sweep then
        state.quiet_sweep_progress = nil
    end
end

function AutoCamera.OnChat(eventData)
    local msg = string.lower(tostring(eventData and (eventData.Message or eventData.message) or ""))
    if msg == AutoCamera.chat_command or msg == "/autocamera" then AutoCamera.Toggle(nil)
    elseif msg == "/autocam on" then AutoCamera.Toggle(true)
    elseif msg == "/autocam off" then AutoCamera.Toggle(false)
    elseif msg == "/autocam next" or msg == "/autocam cycle" then
        local state = auto_camera_state()
        state.enabled, AutoCamera.enabled, state.force_next_target, state.last_cycle_turn = true, true, true, -9999
        state.locked_battle = nil
        AutoCamera.Tick()
    elseif msg == "/autocam cinematic" then
        AutoCamera.Toggle(true, not auto_camera_state().cinematic)
    elseif msg == "/autocam eyes" then
        local state = auto_camera_state()
        state.eyes_mode = not state.eyes_mode
        state.locked_battle = nil
        if state.eyes_mode then
            state.enabled, AutoCamera.enabled, state.force_next_target, state.last_cycle_turn = true, true, true, -9999
            AutoCamera.Tick()
        else
            if AutoCamera.player then AutoCamera.player.VIEW_TYPE = 1 end
            pcall(function() SetActiveLens(0) end)
        end
        if type(QuickMessage) == "function" then QuickMessage(state.eyes_mode and "Eyes mode enabled" or "Eyes mode disabled", "QUERY") end
    elseif string.sub(msg, 1, 17) == "/autocam profile " and #msg > 17 then
        AutoCamera.ApplyProfile(string.sub(msg, 18), true)
    elseif msg == "/autocam profile" then
        if type(QuickMessage) == "function" then QuickMessage("AutoCam current profile: " .. AutoCamera.active_profile, "QUERY") end
    elseif msg == "/autocam balanced" or msg == "/autocam combat" or msg == "/autocam stable" or msg == "/autocam film" then
        local profile = string.sub(msg, 10)
        if profile == "film" then profile = "cinematic" end
        AutoCamera.ApplyProfile(profile, true)
    elseif msg == "/autocam quiet" then
        AutoCamera.ideas.quiet_sweep = not AutoCamera.ideas.quiet_sweep
        if type(QuickMessage) == "function" then QuickMessage("AutoCam quiet sweep: " .. tostring(AutoCamera.ideas.quiet_sweep), "QUERY") end
    elseif msg == "/autocam status" then
        if type(QuickMessage) == "function" then
            local st = auto_camera_state()
            QuickMessage("AutoCam " .. (st.enabled and "on" or "off") .. ", profile=" .. AutoCamera.active_profile .. ", cinematic=" .. tostring(st.cinematic) .. ", eyes=" .. tostring(st.eyes_mode) .. ", queue=" .. tostring(auto_camera_queue_count()) .. ", errors=" .. tostring(st.consecutive_tick_errors or 0), "QUERY")
        end
    elseif msg == "/autocam debug" then
        AutoCamera.debug = not AutoCamera.debug
        if type(QuickMessage) == "function" then QuickMessage("AutoCam debug: " .. tostring(AutoCamera.debug), "QUERY") end
    elseif msg == "/autocam reset" then
        auto_camera_soft_reset_runtime()
        if type(QuickMessage) == "function" then QuickMessage("AutoCam runtime reset.", "QUERY") end
    elseif msg == "/autocam lock" then
        AutoCamera.ideas.fight_anchor_lock = not AutoCamera.ideas.fight_anchor_lock
        local state = auto_camera_state()
        if not AutoCamera.ideas.fight_anchor_lock then state.locked_battle = nil end
        if type(QuickMessage) == "function" then QuickMessage("AutoCam fight lock: " .. tostring(AutoCamera.ideas.fight_anchor_lock), "QUERY") end
    elseif msg == "/autocam queue" then
        if type(QuickMessage) == "function" then QuickMessage("AutoCam queue: " .. tostring(auto_camera_queue_count()) .. " pending.", "QUERY") end
    elseif msg == "/autocam help" then
        if type(QuickMessage) == "function" then QuickMessage("AutoCam: on/off, next, cinematic, eyes, status, queue, debug, reset, lock, profile <name>, balanced/combat/stable/film, quiet", "QUERY") end
    end
end

function AutoCameraTick()
    local ok, err = pcall(AutoCamera.Tick)
    local st = auto_camera_state()
    if ok then
        st.consecutive_tick_errors = 0
        st.last_tick_error = nil
        return
    end

    st.consecutive_tick_errors = (st.consecutive_tick_errors or 0) + 1
    st.last_tick_error = tostring(err)
    auto_camera_debug_message("tick error " .. tostring(st.consecutive_tick_errors) .. ": " .. tostring(err))

    if st.consecutive_tick_errors >= AutoCamera.max_consecutive_tick_errors then
        st.enabled = false
        AutoCamera.enabled = false
        if type(QuickMessage) == "function" then
            QuickMessage("AutoCam disabled after repeated errors. Use /autocam reset, then /autocam on.", "QUERY")
        end
    end
end
function AutoCameraOnChat(eventData) pcall(AutoCamera.OnChat, eventData) end
function AutoCameraOnDeath(eventData)
    if not PLAYER0 then return end
    local u = eventData and eventData.unit
    if safe_is_valid(u) and u.owner == PLAYER0 and (u.level or 1) >= 8 then
        if u.model == "IMP" and auto_camera_has_non_imp(PLAYER0) then return end
        if u.model == "HORNY" or u.model == "AVATAR" then
            AutoCamera.Interrupt(u.pos, 800, "victory_defeat")
        else
            AutoCamera.Interrupt(u.pos, 700, "major_death")
        end
    end
end

function AutoCameraOnLevelUp(eventData)
    if not PLAYER0 then return end
    local c = eventData and eventData.creature
    if safe_is_valid(c) and (c.level or 1) >= 8 and c.owner == PLAYER0 then
        if c.model == "IMP" and auto_camera_has_non_imp(PLAYER0) then return end
        AutoCamera.Interrupt(c.pos, 550, "elite_level_up")
    end
end

function AutoCamera.Interrupt(loc, prio, label)
    if not loc or not loc.val_x or not loc.val_y then return end
    auto_camera_queue_interrupt(loc, prio, label)
end

-- ROOM CAPTURE INTERRUPT: focus the camera when a room changes ownership
function AutoCameraOnRoomTaken(eventData)
    if not PLAYER0 then return end
    local room = eventData and (eventData.room or eventData.Room)
    local p = eventData and (eventData.player or eventData.Player or eventData.owner or eventData.Owner)
    local old_p = eventData and (eventData.old_player or eventData.old_owner)
    if room then
        local ok, center = pcall(function() return room.centerpos end)
        if ok and center then
            if room.owner == PLAYER0 or p == PLAYER0 then
                auto_camera_queue_interrupt(center, 250, "room_capture")
            elseif old_p == PLAYER0 then
                auto_camera_queue_interrupt(center, 800, "room_lost")
            end
        end
    end
end

-- SPECIAL FOUND INTERRUPT: focus the camera when a special box is used
function AutoCameraOnSpecialUsed(eventData)
    if not PLAYER0 then return end
    local loc = eventData and (eventData.pos or eventData.location or eventData.Position)
    local p = eventData and (eventData.player or eventData.Player)
    if loc and p == PLAYER0 then
        auto_camera_queue_interrupt(loc, 500, "special_found")
    end
end

-- SPELL FOCUS (combined from ideas 22 & 55): focus on where spells are cast.
-- spell_focus (idea 22): high-priority interrupt (450). spell_cast_focus (idea 55): lower priority (200).
-- Both use the same trigger; check each idea's toggle independently.
function AutoCameraOnPowerCast(eventData)
    if not PLAYER0 then return end
    local loc = eventData and (eventData.pos or eventData.location or eventData.Position)
    if not loc or eventData.player ~= PLAYER0 then return end
    local state = auto_camera_state()
    local current_turn = PLAYER0.GAME_TURN or 0

    -- spell_focus (idea 22): higher priority for dramatic spell casts (e.g. lightning, earthquake)
    if AutoCamera.ideas.spell_focus then
        if current_turn - (state.last_spell_high_turn or -9999) >= 60 then
            state.last_spell_high_turn = current_turn
            auto_camera_queue_interrupt(loc, 450, "spell_cast")
            return
        end
    end

    -- spell_cast_focus (idea 55): lower-priority interrupt for all keeper spells
    if AutoCamera.ideas.spell_cast_focus then
        if current_turn - (state.last_spell_low_turn or -9999) >= 40 then
            state.last_spell_low_turn = current_turn
            auto_camera_queue_interrupt(loc, 200, "spell_cast")
        end
    end
end

-- EXCAVATION AND CONSTRUCTION FOCUS (ideas 23 & 31): focus on wall digging and room building
function AutoCameraOnSlabChanged(eventData)
    if not PLAYER0 then return end
    local state = auto_camera_state()
    local current_turn = PLAYER0.GAME_TURN or 0
    local slab = eventData and (eventData.slab or eventData.Slab)
    if not slab then return end
    local slb_x = slab.slb_x
    local slb_y = slab.slb_y
    if not slb_x or not slb_y then return end

    if AutoCamera.ideas.dig_focus and eventData.old_slab_kind and string.find(tostring(eventData.old_slab_kind), "WALL") then
        if current_turn - (state.last_dig_turn or -9999) < 60 then return end
        -- Only focus if a human Imp dug it
        local is_human_dig = false
        local target_x = slb_x * 3 * 256 + 384
        local target_y = slb_y * 3 * 256 + 384
        for _, cr in ipairs(GetCreaturesOfPlayer(PLAYER0) or {}) do
            if cr.model == "IMP" and safe_is_valid(cr) and cr.pos then
                local dx = cr.pos.val_x - target_x
                local dy = cr.pos.val_y - target_y
                if dx * dx + dy * dy < 1536 * 1536 then
                    is_human_dig = true
                    break
                end
            end
        end
        if not is_human_dig then return end

        state.last_dig_turn = current_turn
        local loc = { val_x = target_x, val_y = target_y, stl_x = slb_x * 3 + 1, stl_y = slb_y * 3 + 1 }
        auto_camera_queue_interrupt(loc, 110, "dig_focus")
    elseif AutoCamera.ideas.room_construction_focus and slab.kind and slab.owner == PLAYER0 then
        local k = tostring(slab.kind)
        if k ~= "FLOOR" and k ~= "PATH" and k ~= "PRETTY_PATH" and not string.find(k, "WALL") then
            if current_turn - (state.last_const_turn or -9999) < 100 then return end
            state.last_const_turn = current_turn
            local loc = { val_x = slb_x * 3 * 256 + 384, val_y = slb_y * 3 * 256 + 384, stl_x = slb_x * 3 + 1, stl_y = slb_y * 3 + 1 }
            auto_camera_queue_interrupt(loc, 120, "room_construction")
        end
    end
end

-- MAJOR DAMAGE FOCUS (idea 30) and IMPENDING BREACH / DOOR_BREACH (idea 47): focus on units or doors taking huge hits
-- DOOR_BREACH label is used for all heavy-damage-on-door events (both here and in AutoCameraOnObjectDestroyed)
function AutoCameraOnApplyDamage(eventData)
    if not PLAYER0 then return end
    local u = eventData and eventData.thing
    local dmg = eventData and eventData.damage or 0
    if not safe_is_valid(u) or dmg <= 0 then return end

    if u.owner == PLAYER0 and u.thing_class == "CREATURE" and AutoCamera.ideas.major_damage_focus then
        if u.model == "IMP" and auto_camera_has_non_imp(PLAYER0) then return end
        local threshold = (u.max_health or 100) * 0.30
        if dmg >= threshold and dmg > 50 then
            local state = auto_camera_state()
            local current_turn = PLAYER0.GAME_TURN or 0
            if current_turn - (state.last_major_dmg_turn or -9999) < 150 then return end
            state.last_major_dmg_turn = current_turn
            auto_camera_queue_interrupt(u.pos, 950, "major_damage")
        end
    elseif AutoCamera.ideas.door_breach and u.model and string.find(tostring(u.model), "DOOR") and u.owner == PLAYER0 then
        local threshold = (u.max_health or 500) * AutoCamera.breach_emergency_hp
        if dmg >= threshold and dmg > 80 then
            local state = auto_camera_state()
            local current_turn = PLAYER0.GAME_TURN or 0
            if current_turn - (state.last_door_dmg_turn or -9999) < 100 then return end
            state.last_door_dmg_turn = current_turn
            auto_camera_queue_interrupt(u.pos, 450, "door_breach")
        end
    end
end

-- TRAP PLACED INTERRUPT (idea 25): focus on new trap construction
function AutoCameraOnTrapPlaced(eventData)
    if not PLAYER0 then return end
    if not AutoCamera.ideas.trap_focus then return end
    local trap = eventData and (eventData.trap or eventData.Trap)
    if trap and trap.owner == PLAYER0 then
        auto_camera_queue_interrupt(trap.pos, 180, "trap_placed")
    end
end

-- TRAP TRIGGER / CARNAGE FOCUS (idea 49): focus on traps detonating or rolling
function AutoCameraOnTrapTriggered(eventData)
    if not PLAYER0 then return end
    if not AutoCamera.ideas.trap_trigger then return end
    local trap = eventData and (eventData.trap or eventData.Trap or eventData.thing or eventData.object)
    if safe_is_valid(trap) and trap.owner == PLAYER0 then
        local state = auto_camera_state()
        local current_turn = PLAYER0.GAME_TURN or 0
        if current_turn - (state.last_trap_trig_turn or -9999) < 60 then return end
        state.last_trap_trig_turn = current_turn
        auto_camera_queue_interrupt(trap.pos, 380, "trap_triggered")
    end
end

-- EXPANSION FOCUS (idea 24): focus on territory claiming
function AutoCameraOnSlabOwnerChanged(eventData)
    if not PLAYER0 then return end
    if not AutoCamera.ideas.claim_focus then return end
    local slab = eventData and (eventData.slab or eventData.Slab)
    if slab and slab.owner == PLAYER0 and slab.slb_x and slab.slb_y then
        local state = auto_camera_state()
        local current_turn = PLAYER0.GAME_TURN or 0
        if current_turn - (state.last_claim_turn or -9999) < 80 then return end
        state.last_claim_turn = current_turn
        local loc = { val_x = slab.slb_x * 3 * 256 + 384, val_y = slab.slb_y * 3 * 256 + 384, stl_x = slab.slb_x * 3 + 1, stl_y = slab.slb_y * 3 + 1 }
        auto_camera_queue_interrupt(loc, 90, "claim_focus")
    end
end

-- REBIRTH FOCUS (idea 27): focus on undead rising
function AutoCameraOnRebirth(eventData)
    if not PLAYER0 then return end
    if not AutoCamera.ideas.rebirth_focus then return end
    local u = eventData and (eventData.unit or eventData.Unit)
    if safe_is_valid(u) and u.owner == PLAYER0 then
        auto_camera_queue_interrupt(u.pos, 400, "rebirth")
    end
end

-- DUNGEON DESTROYED FOCUS (idea 28): focus on defeated keepers
function AutoCameraOnDungeonDestroyed(eventData)
    if not PLAYER0 then return end
    if not AutoCamera.ideas.dungeon_destroyed_focus then return end
    local p = eventData and (eventData.player or eventData.Player)
    if p and p == PLAYER0 and p.heart and p.heart.pos then
        auto_camera_queue_interrupt(p.heart.pos, 2500, "dungeon_destroyed")
    end
end

-- DOOR DESTROYED FOCUS (idea 29): focus on broken doors as strategic breaches
-- Uses label "door_breach" to consolidate breach alerts under one label for heatmap/scoring
function AutoCameraOnObjectDestroyed(eventData)
    if not PLAYER0 then return end
    if not AutoCamera.ideas.door_destroyed_focus then return end
    local obj = eventData and (eventData.unit or eventData.Unit or eventData.object)
    if safe_is_valid(obj) and obj.model and string.find(tostring(obj.model), "DOOR") then
        if obj.owner == PLAYER0 then
            auto_camera_queue_interrupt(obj.pos, 350, "door_breach")
        end
    end
end

AutoCamera.ApplyProfile("balanced", false)
pcall(function() RegisterTimerEvent("AutoCameraTick", 10, true) end)
pcall(function() CreateTrigger("ChatMsg", "AutoCameraOnChat", {}) end)
pcall(function() CreateTrigger("Death", "AutoCameraOnDeath", {}) end)
pcall(function() CreateTrigger("LevelUp", "AutoCameraOnLevelUp", {}) end)
pcall(function() CreateTrigger("Rebirth", "AutoCameraOnRebirth", {}) end)
pcall(function() CreateTrigger("DungeonDestroyed", "AutoCameraOnDungeonDestroyed", {}) end)
pcall(function() CreateTrigger("Destroyed", "AutoCameraOnObjectDestroyed", {}) end)
pcall(function() CreateTrigger("RoomOwnerChange", "AutoCameraOnRoomTaken", {}) end)
pcall(function() CreateTrigger("SpecialActivated", "AutoCameraOnSpecialUsed", {}) end)
pcall(function() CreateTrigger("PowerCast", "AutoCameraOnPowerCast", {}) end)
pcall(function() CreateTrigger("ApplyDamage", "AutoCameraOnApplyDamage", {}) end)
pcall(function() CreateTrigger("SlabKindChange", "AutoCameraOnSlabChanged", {}) end)
pcall(function() CreateTrigger("SlabOwnerChange", "AutoCameraOnSlabOwnerChanged", {}) end)
pcall(function() CreateTrigger("TrapPlaced", "AutoCameraOnTrapPlaced", {}) end)
pcall(function() CreateTrigger("TrapTriggered", "AutoCameraOnTrapTriggered", {}) end)
pcall(function() CreateTrigger("TrapActivated", "AutoCameraOnTrapTriggered", {}) end)