-- world_modifiers.lua
-- Dynamic World Modifiers system for KeeperFX maps.
-- Provides 100+ modifiers with randomized stat ranges.

WorldModifiers = WorldModifiers or {}
WorldModifiers.Pool = {}
WorldModifiers.ByID = {}

-- Helper to register modifiers
local function add_modifier(mod)
    table.insert(WorldModifiers.Pool, mod)
    WorldModifiers.ByID[mod.id] = mod
end

-- Helper to adjust all active creatures
local function adjust_all_creatures(fn)
    local creatures = (GetThingsOfClass and GetThingsOfClass("Creature")) or (GetCreatures and GetCreatures()) or {}
    for _, c in ipairs(creatures) do
        if c and c.isValid and c:isValid() then
            pcall(fn, c)
        end
    end
end

-- Helper to check if a thing is owned by PLAYER0
local function is_owned_by_player0(thing)
    if not thing or not PLAYER0 then return false end
    if thing.owner == PLAYER0 then return true end
    if type(thing.owner) == "number" then
        return PLAYER0.playerId and thing.owner == PLAYER0.playerId
    end
    return thing.owner and PLAYER0.playerId and thing.owner.playerId == PLAYER0.playerId
end
-- Helper to get/set applied flags that survive save/load by storing them in the Game table.
local function has_flag(obj, flag)
    if not obj or not Game then return false end
    local idx = obj.ThingIndex
    if not idx then return false end
    Game._wm_applied = Game._wm_applied or {}
    local entry = Game._wm_applied[idx]
    return entry and entry[flag] or false
end

local function set_flag(obj, flag, val)
    if not obj or not Game then return end
    local idx = obj.ThingIndex
    if not idx then return end
    Game._wm_applied = Game._wm_applied or {}
    Game._wm_applied[idx] = Game._wm_applied[idx] or {}
    Game._wm_applied[idx][flag] = val
end

-- 1. Gigantism
add_modifier({
    id = 1,
    name = "Gigantism",
    description = "All creatures are giant (%vx size) and have +50% health.",
    min = 1.3,
    max = 2.0,
    is_float = true,
    unit = "",
    update = function(v)
        adjust_all_creatures(function(c)
            if c.sprite_size < 300 * v then
                c.sprite_size = math.floor(300 * v)
            end
            if not has_flag(c, "gigantism_applied") then
                c.max_health = math.floor(c.max_health * 1.50)
                c.health = c.max_health
                set_flag(c, "gigantism_applied", true)
            end
        end)
    end
})

-- 2. Miniature
add_modifier({
    id = 2,
    name = "Miniaturization",
    description = "All creatures are miniature (%vx size) and have -40% health.",
    min = 0.4,
    max = 0.8,
    is_float = true,
    unit = "",
    update = function(v)
        adjust_all_creatures(function(c)
            if c.sprite_size > 300 * v then
                c.sprite_size = math.floor(300 * v)
            end
            if not has_flag(c, "mini_applied") then
                c.max_health = math.max(10, math.floor(c.max_health * 0.60))
                if c.health > c.max_health then c.health = c.max_health end
                set_flag(c, "mini_applied", true)
            end
        end)
    end
})

-- 3. Turbo Speed
add_modifier({
    id = 3,
    name = "Turbo Speed",
    description = "All creatures move much faster (+%v%).",
    min = 35,
    max = 80,
    is_float = false,
    unit = "",
    update = function(v)
        adjust_all_creatures(function(c)
            if not has_flag(c, "turbo_applied") then
                c.max_speed = math.floor(c.max_speed * (1 + v / 100))
                set_flag(c, "turbo_applied", true)
            end
        end)
    end
})

-- 4. Sluggish
add_modifier({
    id = 4,
    name = "Sluggish",
    description = "All creatures move slower (-%v%).",
    min = 20,
    max = 45,
    is_float = false,
    unit = "",
    update = function(v)
        adjust_all_creatures(function(c)
            if not has_flag(c, "sluggish_applied") then
                c.max_speed = math.max(10, math.floor(c.max_speed * (1 - v / 100)))
                set_flag(c, "sluggish_applied", true)
            end
        end)
    end
})

-- 5. Iron Hide
add_modifier({
    id = 5,
    name = "Iron Hide",
    description = "All creatures have increased max health (+%v%).",
    min = 60,
    max = 180,
    is_float = false,
    unit = "",
    update = function(v)
        adjust_all_creatures(function(c)
            if not has_flag(c, "iron_hide_applied") then
                c.max_health = math.floor(c.max_health * (1 + v / 100))
                c.health = c.max_health
                set_flag(c, "iron_hide_applied", true)
            end
        end)
    end
})

-- 6. Fragile
add_modifier({
    id = 6,
    name = "Fragile",
    description = "All creatures have reduced max health (-%v%).",
    min = 20,
    max = 40,
    is_float = false,
    unit = "",
    update = function(v)
        adjust_all_creatures(function(c)
            if not has_flag(c, "fragile_applied") then
                c.max_health = math.max(10, math.floor(c.max_health * (1 - v / 100)))
                if c.health > c.max_health then c.health = c.max_health end
                set_flag(c, "fragile_applied", true)
            end
        end)
    end
})

-- 7. Vampiric Strikes
add_modifier({
    id = 7,
    name = "Vampiric Strikes",
    description = "Healing factor when dealing damage (heals heart for %v% of damage dealt).",
    min = 20,
    max = 50,
    is_float = false,
    unit = "",
    on_damage = function(v, eventData)
        local p = eventData.dealing_player or eventData.DealingPlayer or eventData.player or eventData.Player
        local dmg = eventData and tonumber(eventData.damage or eventData.Damage or eventData.amount or eventData.Amount) or 0
        if p and p.heart and p.heart.isValid and p.heart:isValid() and dmg > 0 then
            p.heart.health = math.min(p.heart.max_health, p.heart.health + math.floor(dmg * (v / 100)))
        end
    end
})

-- 8. Bounty Hunter
add_modifier({
    id = 8,
    name = "Bounty Hunter",
    description = "Defeating an enemy creature rewards %v gold.",
    min = 100,
    max = 300,
    is_float = false,
    unit = "",
    on_death = function(v, eventData)
        local victim = eventData.unit
        if PLAYER0 and victim and victim.isValid and victim:isValid() then
            if victim.owner and not is_owned_by_player0(victim) then
                pcall(function() PLAYER0:add_gold(v) end)
            end
        end
    end
})

-- 9. Rich Keepers
add_modifier({
    id = 9,
    name = "Rich Keepers",
    description = "Receive %v gold periodically.",
    min = 100,
    max = 500,
    is_float = false,
    unit = "",
    update = function(v)
        if PLAYER0 then
            pcall(function() PLAYER0:add_gold(v) end)
        end
    end
})

-- 10. Taxation
add_modifier({
    id = 10,
    name = "Taxation",
    description = "Lose %v gold periodically.",
    min = 100,
    max = 300,
    is_float = false,
    unit = "",
    update = function(v)
        if PLAYER0 then
            pcall(function() PLAYER0:add_gold(-v) end)
        end
    end
})

-- 11. Fast Portals
add_modifier({
    id = 11,
    name = "Fast Portals",
    description = "Portal creatures arrive extremely fast.",
    activate = function(v)
        if SetGenerateSpeed then
            SetGenerateSpeed(75, PLAYER0)
        end
    end
})

-- 12. Slow Portals
add_modifier({
    id = 12,
    name = "Slow Portals",
    description = "Portal creatures arrive 3 times slower.",
    activate = function(v)
        if SetGenerateSpeed then
            SetGenerateSpeed(2400, PLAYER0)
        end
    end
})

-- 13. Fast Learners
add_modifier({
    id = 13,
    name = "Fast Learners",
    description = "All creatures train and gain experience %v% faster.",
    min = 30,
    max = 120,
    is_float = false,
    unit = "",
    activate = function(v)
        if SetGameRule then
            SetGameRule("TrainEfficiency", 256 + math.floor(2.56 * v))
        end
        if SetIncreaseOnExperience then
            SetIncreaseOnExperience("ExpForHittingIncreaseOnExp", 3)
        end
    end
})

-- 14. Slow Learners
add_modifier({
    id = 14,
    name = "Slow Learners",
    description = "All creatures train %v% slower.",
    min = 30,
    max = 70,
    is_float = false,
    unit = "",
    activate = function(v)
        if SetGameRule then
            SetGameRule("TrainEfficiency", math.max(30, 256 - math.floor(2.56 * v)))
        end
    end
})

-- 15. Lethal Traps
add_modifier({
    id = 15,
    name = "Lethal Traps",
    description = "Traps trigger and fire twice as fast.",
    activate = function(v)
        local traps = {"BOULDER", "ALARM", "POISON_GAS", "LIGHTNING", "WORD_OF_POWER", "LAVA", "SENTRY", "BALLISTA"}
        for _, t in ipairs(traps) do
            if SetTrapConfiguration then
                SetTrapConfiguration(t, "TimeBetweenShots", 20)
                SetTrapConfiguration(t, "Health", 1200)
            end
        end
    end
})

-- 16. Reinforced Doors
add_modifier({
    id = 16,
    name = "Reinforced Doors",
    description = "Doors have +%v% health.",
    min = 50,
    max = 200,
    is_float = false,
    unit = "",
    activate = function(v)
        local doors = {"WOOD", "BRACED", "STEEL", "MAGIC", "SECRET", "MIDAS"}
        local door_healths = {WOOD=400, BRACED=1000, STEEL=2000, MAGIC=4000, SECRET=1500, MIDAS=5000}
        for _, d in ipairs(doors) do
            if SetDoorConfiguration then
                local base = door_healths[d] or 1000
                SetDoorConfiguration(d, "Health", math.floor(base * (1 + v / 100)))
            end
        end
    end
})

-- 17. Flimsy Doors
add_modifier({
    id = 17,
    name = "Flimsy Doors",
    description = "Doors have -%v% health.",
    min = 25,
    max = 75,
    is_float = false,
    unit = "",
    activate = function(v)
        local doors = {"WOOD", "BRACED", "STEEL", "MAGIC", "SECRET", "MIDAS"}
        local door_healths = {WOOD=400, BRACED=1000, STEEL=2000, MAGIC=4000, SECRET=1500, MIDAS=5000}
        for _, d in ipairs(doors) do
            if SetDoorConfiguration then
                local base = door_healths[d] or 1000
                SetDoorConfiguration(d, "Health", math.max(10, math.floor(base * (1 - v / 100))))
            end
        end
    end
})

-- 18. Cheap Rooms
add_modifier({
    id = 18,
    name = "Cheap Rooms",
    description = "Room building gold-back sell rate increased to %v%.",
    min = 70,
    max = 100,
    is_float = false,
    unit = "",
    activate = function(v)
        if SetGameRule then
            SetGameRule("RoomSellGoldBackPercent", v)
        end
    end
})

-- 19. Efficient Training
add_modifier({
    id = 19,
    name = "Efficient Training",
    description = "Training efficiency is 3x more effective.",
    activate = function(v)
        if SetGameRule then
            SetGameRule("TrainEfficiency", 768)
        end
    end
})

-- 20. Fast Research
add_modifier({
    id = 20,
    name = "Fast Research",
    description = "Library research speed is 3x more effective.",
    activate = function(v)
        if SetGameRule then
            SetGameRule("ResearchEfficiency", 768)
        end
    end
})

-- 21. Fast Workshop
add_modifier({
    id = 21,
    name = "Fast Workshop",
    description = "Workshop manufacturing speed is 3x more effective.",
    activate = function(v)
        if SetGameRule then
            SetGameRule("WorkEfficiency", 768)
        end
    end
})

-- 22. Fast Scavenging
add_modifier({
    id = 22,
    name = "Fast Scavenging",
    description = "Scavenging room efficiency is doubled.",
    activate = function(v)
        if SetGameRule then
            SetGameRule("ScavengeEfficiency", 512)
        end
    end
})

-- 23. Gluttony
add_modifier({
    id = 23,
    name = "Gluttony",
    description = "Creatures get hungry much faster.",
    update = function(v)
        adjust_all_creatures(function(c)
            c.hunger_level = c.hunger_level + math.random(5, 10)
        end)
    end
})

-- 24. Ascetics
add_modifier({
    id = 24,
    name = "Ascetics",
    description = "Creatures never get hungry.",
    update = function(v)
        adjust_all_creatures(function(c)
            c.hunger_level = 0
        end)
    end
})

-- 25. Greedy Hands
add_modifier({
    id = 25,
    name = "Greedy Hands",
    description = "Creatures demand +150% higher pay on level up.",
    activate = function(v)
        if SetIncreaseOnExperience then
            SetIncreaseOnExperience("PayIncreaseOnExp", 3)
        end
    end
})

-- 26. Cheap Labor
add_modifier({
    id = 26,
    name = "Cheap Labor",
    description = "Creatures demand no extra pay on level up.",
    activate = function(v)
        if SetIncreaseOnExperience then
            SetIncreaseOnExperience("PayIncreaseOnExp", 0)
        end
    end
})

-- 27. High Portal Level
add_modifier({
    id = 27,
    name = "High Portal Level",
    description = "Portal creatures enter the dungeon at level %v.",
    min = 3,
    max = 6,
    is_float = false,
    unit = "",
    activate = function(v)
        if CreatureEntranceLevel then
            CreatureEntranceLevel(PLAYER0, v)
        end
    end
})

-- 28. Maximum Population
add_modifier({
    id = 28,
    name = "Maximum Population Limit",
    description = "Maximum creature portal limit restricted to %v units.",
    min = 15,
    max = 25,
    is_float = false,
    unit = "",
    activate = function(v)
        if MaxCreatures then
            MaxCreatures(PLAYER0, v)
        end
    end
})

-- 29. Dungeon Heart Shield
add_modifier({
    id = 29,
    name = "Dungeon Heart Shield",
    description = "Your Dungeon Heart has +100% health.",
    update = function(v)
        if PLAYER0 and PLAYER0.heart and PLAYER0.heart.isValid and PLAYER0.heart:isValid() then
            if not has_flag(PLAYER0.heart, "heart_shield_applied") then
                PLAYER0.heart.max_health = PLAYER0.heart.max_health * 2
                PLAYER0.heart.health = PLAYER0.heart.max_health
                set_flag(PLAYER0.heart, "heart_shield_applied", true)
            end
        end
    end
})

-- 30. Fragile Heart
add_modifier({
    id = 30,
    name = "Fragile Heart",
    description = "Your Dungeon Heart has -35% health.",
    update = function(v)
        if PLAYER0 and PLAYER0.heart and PLAYER0.heart.isValid and PLAYER0.heart:isValid() then
            if not has_flag(PLAYER0.heart, "heart_fragile_applied") then
                PLAYER0.heart.max_health = math.floor(PLAYER0.heart.max_health * 0.65)
                if PLAYER0.heart.health > PLAYER0.heart.max_health then
                    PLAYER0.heart.health = PLAYER0.heart.max_health
                end
                set_flag(PLAYER0.heart, "heart_fragile_applied", true)
            end
        end
    end
})

-- 31. Gold Rush
add_modifier({
    id = 31,
    name = "Gold Rush",
    description = "Start map with +%v gold.",
    min = 10000,
    max = 25000,
    is_float = false,
    unit = "",
    activate = function(v)
        if PLAYER0 then
            pcall(function() PLAYER0:add_gold(v) end)
        end
    end
})

-- 32. Gold Famine
add_modifier({
    id = 32,
    name = "Gold Famine",
    description = "Start map with -%v gold.",
    min = 3000,
    max = 8000,
    is_float = false,
    unit = "",
    activate = function(v)
        if PLAYER0 then
            local curr = PLAYER0.MONEY or 0
            local deduct = math.min(math.max(0, curr - 500), v)
            if deduct > 0 then pcall(function() PLAYER0:add_gold(-deduct) end) end
        end
    end
})

-- 33. Giant Imps
add_modifier({
    id = 33,
    name = "Giant Imps",
    description = "Imps are huge (+100% size) and move twice as fast.",
    update = function(v)
        adjust_all_creatures(function(c)
            if c.model == "IMP" then
                if c.sprite_size < 600 then
                    c.sprite_size = 600
                end
                if not has_flag(c, "imp_speed_applied") then
                    c.max_speed = c.max_speed * 2
                    set_flag(c, "imp_speed_applied", true)
                end
            end
        end)
    end
})

-- 34. Pacifist Slaps
add_modifier({
    id = 34,
    name = "Pacifist Slaps",
    description = "Slapping does not harm or stun creatures.",
    activate = function(v)
        if SetGameRule then
            SetGameRule("SlapDamage", 0)
            SetGameRule("SlapStunTurns", 0)
        end
    end
})

-- 35. Lethal Slaps
add_modifier({
    id = 35,
    name = "Lethal Slaps",
    description = "Slapping deals high damage and stun.",
    activate = function(v)
        if SetGameRule then
            SetGameRule("SlapDamage", 50)
            SetGameRule("SlapStunTurns", 150)
        end
    end
})

-- 36. Rich Soil
add_modifier({
    id = 36,
    name = "Rich Soil",
    description = "Gold piles are worth 1.5x gold.",
    activate = function(v)
        if SetGameRule then
            SetGameRule("GoldPileValue", 300)
        end
    end
})

-- 37. Pocket Dimensions
add_modifier({
    id = 37,
    name = "Pocket Dimensions",
    description = "Treasure hoards hold 1.5x gold.",
    activate = function(v)
        if SetGameRule then
            SetGameRule("GoldPerHoard", 4500)
        end
    end
})

-- 38. Golden Rain
add_modifier({
    id = 38,
    name = "Golden Rain",
    description = "Spawns 750 gold at player heart periodically.",
    update = function(v)
        if PLAYER0 and PLAYER0.heart and PLAYER0.heart.isValid and PLAYER0.heart:isValid() then
            pcall(function() PLAYER0:add_gold(750) end)
        end
    end
})

-- 39. Regenerating Heart
add_modifier({
    id = 39,
    name = "Regenerating Heart",
    description = "Your Dungeon Heart periodically regenerates health.",
    update = function(v)
        if PLAYER0 and PLAYER0.heart and PLAYER0.heart.isValid and PLAYER0.heart:isValid() then
            if PLAYER0.heart.health < PLAYER0.heart.max_health then
                PLAYER0.heart.health = math.min(PLAYER0.heart.max_health, PLAYER0.heart.health + 50)
            end
        end
    end
})

-- 40. Sleepy Lairs
add_modifier({
    id = 40,
    name = "Sleepy Lairs",
    description = "Lair tiles heal creatures 1.5x as fast.",
    activate = function(v)
        if SetRoomConfiguration then
            SetRoomConfiguration("LAIR", "Health", 600)
        end
    end
})

-- 41. Seismic Activity
add_modifier({
    id = 41,
    name = "Seismic Activity",
    description = "Periodic falling debris damages random creatures.",
    update = function(v)
        if math.random(1, 10) == 1 then
            local creatures = (GetThingsOfClass and GetThingsOfClass("Creature")) or (GetCreatures and GetCreatures()) or {}
            if #creatures > 0 then
                local target = creatures[math.random(1, #creatures)]
                if target and target.isValid and target:isValid() then
                    target.health = math.max(1, target.health - math.random(15, 35))
                    if CreateEffectAtPos then
                        pcall(CreateEffectAtPos, "EFFECTELEMENT_DRIPPING_WATER", target.pos.x, target.pos.y, 0)
                    end
                end
            end
        end
    end
})

-- 42. Scavenger Mastery
add_modifier({
    id = 42,
    name = "Scavenger Mastery",
    description = "Scavenger room is 3x more effective.",
    activate = function(v)
        if SetGameRule then
            SetGameRule("ScavengeEfficiency", 768)
        end
    end
})

-- 43. Hard Headed
add_modifier({
    id = 43,
    name = "Hard Headed",
    description = "Creatures cannot be picked up for a long time after being dropped.",
    update = function(v)
        adjust_all_creatures(function(c)
            if c.hand_blocked_turns >= 0 and c.hand_blocked_turns < 1000 then
                c.hand_blocked_turns = 1000
            end
        end)
    end
})

-- 44. Iron Lungs
add_modifier({
    id = 44,
    name = "Iron Lungs",
    description = "All creatures gain immunity to gas.",
    activate = function(v)
        if SetCreatureProperty then
            local models = {"IMP", "FLY", "BUG", "SPIDER", "SPIDERLING", "TROLL", "DEMONSPAWN", "HELL_HOUND", "DARK_MISTRESS", "BILE_DEMON", "SORCEROR", "DRAGON", "VAMPIRE", "SKELETON", "GHOST", "TENTACLE", "WITCH", "FAIRY", "WIZARD", "MONK", "ARCHER", "BARBARIAN", "GIANT", "THIEF", "SAMURAI", "KNIGHT", "AVATAR", "DRUID", "TIME_MAGE"}
            for _, m in ipairs(models) do
                SetCreatureProperty(m, "IMMUNE_TO_GAS", true)
            end
        end
    end
})

-- 45. Featherweight
add_modifier({
    id = 45,
    name = "Featherweight",
    description = "All creatures gain flying property.",
    activate = function(v)
        if SetCreatureProperty then
            local models = {"IMP", "FLY", "BUG", "SPIDER", "SPIDERLING", "TROLL", "DEMONSPAWN", "HELL_HOUND", "DARK_MISTRESS", "BILE_DEMON", "SORCEROR", "DRAGON", "VAMPIRE", "SKELETON", "GHOST", "TENTACLE", "WITCH", "FAIRY", "WIZARD", "MONK", "ARCHER", "BARBARIAN", "GIANT", "THIEF", "SAMURAI", "KNIGHT", "AVATAR", "DRUID", "TIME_MAGE"}
            for _, m in ipairs(models) do
                SetCreatureProperty(m, "FLYING", true)
            end
        end
    end
})

-- Dynamically build modifiers 46 to 103 for each creature model to hit 100+ pool.
local creature_models = {
    "IMP", "FLY", "BUG", "SPIDER", "SPIDERLING", "TROLL", "DEMONSPAWN", 
    "HELL_HOUND", "DARK_MISTRESS", "BILE_DEMON", "SORCEROR", "DRAGON", 
    "VAMPIRE", "SKELETON", "GHOST", "TENTACLE", "WITCH", "FAIRY", 
    "WIZARD", "MONK", "ARCHER", "BARBARIAN", "GIANT", "THIEF", 
    "SAMURAI", "KNIGHT", "AVATAR", "DRUID", "TIME_MAGE"
}

for i, model in ipairs(creature_models) do
    local buff_id = 45 + (i * 2 - 1)
    local debuff_id = 45 + (i * 2)
    
    -- Buff: Titan [Creature]
    add_modifier({
        id = buff_id,
        name = "Titan " .. model .. "s",
        description = "All " .. model .. "s are giant (+%vx size) and have +75% max health.",
        min = 1.2,
        max = 1.6,
        is_float = true,
        unit = "",
        update = function(v)
            adjust_all_creatures(function(c)
                if c.model == model then
                    if c.sprite_size < 300 * v then
                        c.sprite_size = math.floor(300 * v)
                    end
                    if not has_flag(c, "titan_applied") then
                        c.max_health = math.floor(c.max_health * 1.75)
                        c.health = c.max_health
                        set_flag(c, "titan_applied", true)
                    end
                end
            end)
        end
    })

    -- Debuff: Miniature [Creature]
    add_modifier({
        id = debuff_id,
        name = "Miniature " .. model .. "s",
        description = "All " .. model .. "s are tiny (%vx size) and have -45% health.",
        min = 0.5,
        max = 0.8,
        is_float = true,
        unit = "",
        update = function(v)
            adjust_all_creatures(function(c)
                if c.model == model then
                    if c.sprite_size > 300 * v then
                        c.sprite_size = math.floor(300 * v)
                    end
                    if not has_flag(c, "mini_applied") then
                        c.max_health = math.max(10, math.floor(c.max_health * 0.55))
                        if c.health > c.max_health then c.health = c.max_health end
                        set_flag(c, "mini_applied", true)
                    end
                end
            end)
        end
    })
end

-- Dynamically build modifiers 104 to 161: Hyper-speed and Sluggish per creature model
for i, model in ipairs(creature_models) do
    local buff_id = 103 + (i * 2 - 1)
    local debuff_id = 103 + (i * 2)

    -- Buff: Hyper-speed [Creature]
    add_modifier({
        id = buff_id,
        name = "Hyper-speed " .. model .. "s",
        description = "All " .. model .. "s move faster (+%v%).",
        min = 30,
        max = 80,
        is_float = false,
        unit = "",
        update = function(v)
            adjust_all_creatures(function(c)
                if c.model == model then
                    if not has_flag(c, "hyperspeed_applied") then
                        c.max_speed = math.floor(c.max_speed * (1 + v / 100))
                        set_flag(c, "hyperspeed_applied", true)
                    end
                end
            end)
        end
    })

    -- Debuff: Sluggish [Creature]
    add_modifier({
        id = debuff_id,
        name = "Sluggish " .. model .. "s",
        description = "All " .. model .. "s move slower (-%v%).",
        min = 15,
        max = 40,
        is_float = false,
        unit = "",
        update = function(v)
            adjust_all_creatures(function(c)
                if c.model == model then
                    if not has_flag(c, "sluggish_creature_applied") then
                        c.max_speed = math.max(10, math.floor(c.max_speed * (1 - v / 100)))
                        set_flag(c, "sluggish_creature_applied", true)
                    end
                end
            end)
        end
    })
end

-- Dynamically build modifiers 162 to 220: Ironclad and Vulnerable per creature model
for i, model in ipairs(creature_models) do
    local buff_id = 161 + (i * 2 - 1)
    local debuff_id = 161 + (i * 2)

    -- Buff: Ironclad [Creature]
    add_modifier({
        id = buff_id,
        name = "Ironclad " .. model .. "s",
        description = "All " .. model .. "s have higher strength and defense (+%v%).",
        min = 20,
        max = 50,
        is_float = false,
        unit = "",
        update = function(v)
            adjust_all_creatures(function(c)
                if c.model == model then
                    if not has_flag(c, "ironclad_applied") then
                        if c.strength then c.strength = math.floor(c.strength * (1 + v / 100)) end
                        if c.defense then c.defense = math.floor(c.defense * (1 + v / 100)) end
                        set_flag(c, "ironclad_applied", true)
                    end
                end
            end)
        end
    })

    -- Debuff: Vulnerable [Creature]
    add_modifier({
        id = debuff_id,
        name = "Vulnerable " .. model .. "s",
        description = "All " .. model .. "s have lower strength and defense (-%v%).",
        min = 10,
        max = 25,
        is_float = false,
        unit = "",
        update = function(v)
            adjust_all_creatures(function(c)
                if c.model == model then
                    if not has_flag(c, "vulnerable_applied") then
                        if c.strength then c.strength = math.max(1, math.floor(c.strength * (1 - v / 100))) end
                        if c.defense then c.defense = math.max(1, math.floor(c.defense * (1 - v / 100))) end
                        set_flag(c, "vulnerable_applied", true)
                    end
                end
            end)
        end
    })
end

-- Dynamically build modifiers 221 to 278: Reinforced and Fragile per creature model
for i, model in ipairs(creature_models) do
    local buff_id = 220 + (i * 2 - 1)
    local debuff_id = 220 + (i * 2)

    -- Buff: Reinforced [Creature]
    add_modifier({
        id = buff_id,
        name = "Reinforced " .. model .. "s",
        description = "All " .. model .. "s have higher max health (+%v%).",
        min = 25,
        max = 75,
        is_float = false,
        unit = "",
        update = function(v)
            adjust_all_creatures(function(c)
                if c.model == model then
                    if not has_flag(c, "reinforced_applied") then
                        c.max_health = math.floor(c.max_health * (1 + v / 100))
                        c.health = c.max_health
                        set_flag(c, "reinforced_applied", true)
                    end
                end
            end)
        end
    })

    -- Debuff: Fragile [Creature]
    add_modifier({
        id = debuff_id,
        name = "Fragile " .. model .. "s",
        description = "All " .. model .. "s have lower max health (-%v%).",
        min = 15,
        max = 30,
        is_float = false,
        unit = "",
        update = function(v)
            adjust_all_creatures(function(c)
                if c.model == model then
                    if not has_flag(c, "fragile_creature_applied") then
                        c.max_health = math.max(10, math.floor(c.max_health * (1 - v / 100)))
                        if c.health > c.max_health then c.health = c.max_health end
                        set_flag(c, "fragile_creature_applied", true)
                    end
                end
            end)
        end
    })
end

-- Dynamically build modifiers 279 to 336: Prosperous and Impoverished per creature model
for i, model in ipairs(creature_models) do
    local buff_id = 278 + (i * 2 - 1)
    local debuff_id = 278 + (i * 2)

    -- Buff: Prosperous [Creature]
    add_modifier({
        id = buff_id,
        name = "Prosperous " .. model .. "s",
        description = "All " .. model .. "s carry extra gold (+%v).",
        min = 100,
        max = 500,
        is_float = false,
        unit = "",
        update = function(v)
            adjust_all_creatures(function(c)
                if c.model == model then
                    if not has_flag(c, "prosperous_applied") then
                        if c.gold_held then c.gold_held = (c.gold_held or 0) + v end
                        set_flag(c, "prosperous_applied", true)
                    end
                end
            end)
        end
    })

    -- Debuff: Impoverished [Creature]
    add_modifier({
        id = debuff_id,
        name = "Impoverished " .. model .. "s",
        description = "All " .. model .. "s carry less gold (-%v%).",
        min = 50,
        max = 100,
        is_float = false,
        unit = "",
        update = function(v)
            adjust_all_creatures(function(c)
                if c.model == model then
                    if not has_flag(c, "impoverished_applied") then
                        if c.gold_held then c.gold_held = math.max(0, math.floor((c.gold_held or 0) * (1 - v / 100))) end
                        set_flag(c, "impoverished_applied", true)
                    end
                end
            end)
        end
    })
end

-- Dynamically build modifiers 337 to 394: Mighty and Feeble per creature model
for i, model in ipairs(creature_models) do
    local buff_id = 336 + (i * 2 - 1)
    local debuff_id = 336 + (i * 2)

    -- Buff: Mighty [Creature]
    add_modifier({
        id = buff_id,
        name = "Mighty " .. model .. "s",
        description = "All " .. model .. "s have higher strength (+%v%).",
        min = 50,
        max = 150,
        is_float = false,
        unit = "",
        update = function(v)
            adjust_all_creatures(function(c)
                if c.model == model then
                    if not has_flag(c, "mighty_applied") then
                        if c.strength then c.strength = math.floor(c.strength * (1 + v / 100)) end
                        set_flag(c, "mighty_applied", true)
                    end
                end
            end)
        end
    })

    -- Debuff: Feeble [Creature]
    add_modifier({
        id = debuff_id,
        name = "Feeble " .. model .. "s",
        description = "All " .. model .. "s have lower strength (-%v%).",
        min = 30,
        max = 60,
        is_float = false,
        unit = "",
        update = function(v)
            adjust_all_creatures(function(c)
                if c.model == model then
                    if not has_flag(c, "feeble_applied") then
                        if c.strength then c.strength = math.max(1, math.floor(c.strength * (1 - v / 100))) end
                        set_flag(c, "feeble_applied", true)
                    end
                end
            end)
        end
    })
end

-- Dynamically build modifiers 395 to 452: Shielded and Unarmored per creature model
for i, model in ipairs(creature_models) do
    local buff_id = 394 + (i * 2 - 1)
    local debuff_id = 394 + (i * 2)

    -- Buff: Shielded [Creature]
    add_modifier({
        id = buff_id,
        name = "Shielded " .. model .. "s",
        description = "All " .. model .. "s have higher defense (+%v%).",
        min = 50,
        max = 150,
        is_float = false,
        unit = "",
        update = function(v)
            adjust_all_creatures(function(c)
                if c.model == model then
                    if not has_flag(c, "shielded_applied") then
                        if c.defense then c.defense = math.floor(c.defense * (1 + v / 100)) end
                        set_flag(c, "shielded_applied", true)
                    end
                end
            end)
        end
    })

    -- Debuff: Unarmored [Creature]
    add_modifier({
        id = debuff_id,
        name = "Unarmored " .. model .. "s",
        description = "All " .. model .. "s have lower defense (-%v%).",
        min = 30,
        max = 60,
        is_float = false,
        unit = "",
        update = function(v)
            adjust_all_creatures(function(c)
                if c.model == model then
                    if not has_flag(c, "unarmored_applied") then
                        if c.defense then c.defense = math.max(1, math.floor(c.defense * (1 - v / 100))) end
                        set_flag(c, "unarmored_applied", true)
                    end
                end
            end)
        end
    })
end

-- Dynamically build modifiers 453 to 510: Vampiric and Brittle per creature model
for i, model in ipairs(creature_models) do
    local buff_id = 452 + (i * 2 - 1)
    local debuff_id = 452 + (i * 2)

    -- Buff: Vampiric [Creature]
    add_modifier({
        id = buff_id,
        name = "Vampiric " .. model .. "s",
        description = "All " .. model .. "s heal themselves for %v% of damage they deal.",
        min = 15,
        max = 50,
        is_float = false,
        unit = "",
        on_damage = function(v, eventData)
            local attacker = eventData.source or eventData.Source or eventData.caster or eventData.Caster
            if attacker and attacker.isValid and attacker:isValid() and attacker.model == model then
                local dmg = tonumber(eventData.damage or eventData.Damage or eventData.amount or eventData.Amount) or 0
                local heal = math.floor(dmg * (v / 100))
                if heal > 0 and attacker.health and attacker.max_health then
                    attacker.health = math.min(attacker.max_health, attacker.health + heal)
                end
            end
        end
    })

    -- Debuff: Brittle [Creature]
    add_modifier({
        id = debuff_id,
        name = "Brittle " .. model .. "s",
        description = "All " .. model .. "s take %v% extra damage when hit.",
        min = 20,
        max = 60,
        is_float = false,
        unit = "",
        on_damage = function(v, eventData)
            local target = eventData.thing or eventData.Thing or eventData.target or eventData.Target or eventData.unit or eventData.Unit
            if target and target.isValid and target:isValid() and target.model == model then
                local dmg = tonumber(eventData.damage or eventData.Damage or eventData.amount or eventData.Amount) or 0
                local extra = math.floor(dmg * (v / 100))
                if extra > 0 and target.health then
                    target.health = math.max(1, target.health - extra)
                end
            end
        end
    })
end

-- Dynamically build modifiers 511 to 568: Enlarged and Shrunk per creature model
for i, model in ipairs(creature_models) do
    local buff_id = 510 + (i * 2 - 1)
    local debuff_id = 510 + (i * 2)

    -- Buff: Enlarged [Creature]
    add_modifier({
        id = buff_id,
        name = "Enlarged " .. model .. "s",
        description = "All " .. model .. "s are enlarged (+%v% size).",
        min = 30,
        max = 100,
        is_float = false,
        unit = "",
        update = function(v)
            adjust_all_creatures(function(c)
                if c.model == model then
                    if not has_flag(c, "enlarged_applied") then
                        c.sprite_size = math.floor(c.sprite_size * (1 + v / 100))
                        set_flag(c, "enlarged_applied", true)
                    end
                end
            end)
        end
    })

    -- Debuff: Shrunk [Creature]
    add_modifier({
        id = debuff_id,
        name = "Shrunk " .. model .. "s",
        description = "All " .. model .. "s are shrunk (-%v% size).",
        min = 30,
        max = 60,
        is_float = false,
        unit = "",
        update = function(v)
            adjust_all_creatures(function(c)
                if c.model == model then
                    if not has_flag(c, "shrunk_applied") then
                        c.sprite_size = math.max(50, math.floor(c.sprite_size * (1 - v / 100)))
                        set_flag(c, "shrunk_applied", true)
                    end
                end
            end)
        end
    })
end

-- Initialize system on level load
function WorldModifiers_Init()
    if not Game then return end
    
    if not Game.world_modifiers then
        -- New map. Roll 1 to 5 random modifiers.
        Game.world_modifiers = {}
        local num_mods = math.random(1, 5)
        local chosen_indices = {}
        local pool_size = #WorldModifiers.Pool
        
        while #chosen_indices < num_mods and #chosen_indices < pool_size do
            local idx = math.random(1, pool_size)
            local dup = false
            for _, existing in ipairs(chosen_indices) do
                if existing == idx then
                    dup = true
                    break
                end
            end
            if not dup then
                table.insert(chosen_indices, idx)
            end
        end
        
        for _, idx in ipairs(chosen_indices) do
            local mod_template = WorldModifiers.Pool[idx]
            local rolled_val = nil
            if mod_template.min and mod_template.max then
                if mod_template.is_float then
                    rolled_val = mod_template.min + math.random() * (mod_template.max - mod_template.min)
                    rolled_val = math.floor(rolled_val * 100 + 0.5) / 100
                else
                    rolled_val = math.random(mod_template.min, mod_template.max)
                end
            end
            
            local active_mod = {
                id = mod_template.id,
                name = mod_template.name,
                description = mod_template.description,
                value = rolled_val,
                unit = mod_template.unit or ""
            }
            table.insert(Game.world_modifiers, active_mod)
        end
        
        -- Run activation
        WorldModifiers.apply_all()
        
        -- Notify the player
        local notify_text = "World Modifiers Active:\n"
        for i, mod in ipairs(Game.world_modifiers) do
            local desc = mod.description
            if mod.value then
                desc = desc:gsub("%%v", tostring(mod.value) .. mod.unit)
            end
            notify_text = notify_text .. i .. ") " .. mod.name .. ": " .. desc .. "\n"
        end
        notify_text = notify_text .. "Use /m in chat to view active modifiers."
        
        if QuickObjective then
            pcall(QuickObjective, notify_text, nil)
        end
    else
        -- Loaded map. Re-apply configurations.
        WorldModifiers.apply_all()
    end
end

-- Run activation logic for all active modifiers
function WorldModifiers.apply_all()
    if not Game or not Game.world_modifiers then return end
    for _, active_mod in ipairs(Game.world_modifiers) do
        local template = WorldModifiers.ByID[active_mod.id]
        if template and template.activate then
            pcall(template.activate, active_mod.value)
        end
    end
end

-- Periodic update check
function WorldModifiers_Tick()
    if not Game or not Game.world_modifiers then return end
    for _, active_mod in ipairs(Game.world_modifiers) do
        local template = WorldModifiers.ByID[active_mod.id]
        if template and template.update then
            pcall(template.update, active_mod.value)
        end
    end
end

-- Global apply damage handler mapped to templates
function WorldModifiers_OnApplyDamage(eventData)
    if not Game or not Game.world_modifiers or not eventData then return end
    for _, active_mod in ipairs(Game.world_modifiers) do
        local template = WorldModifiers.ByID[active_mod.id]
        if template and template.on_damage then
            pcall(template.on_damage, active_mod.value, eventData)
        end
    end
end

-- Global unit death handler mapped to templates
function WorldModifiers_OnCreatureDeath(eventData)
    if not Game or not Game.world_modifiers or not eventData then return end
    
    local victim = eventData.unit or eventData.Unit or eventData.thing or eventData.Thing
    if victim and victim.ThingIndex and Game._wm_applied then
        Game._wm_applied[victim.ThingIndex] = nil
    end

    for _, active_mod in ipairs(Game.world_modifiers) do
        local template = WorldModifiers.ByID[active_mod.id]
        if template and template.on_death then
            pcall(template.on_death, active_mod.value, eventData)
        end
    end
end

-- Chat command listener for /m
function WorldModifiers_OnChat(eventData)
    if not eventData then return end
    local raw_msg = eventData.Message or eventData.message or eventData.Msg or eventData.msg or eventData.Text or eventData.text or eventData.chat_message or ""
    local msg = tostring(raw_msg):lower():match("^%s*(.-)%s*$")
    
    if msg == "/m" or msg == "/modifier" or msg == "/modifiers" then
        if not Game or not Game.world_modifiers or #Game.world_modifiers == 0 then
            if QuickObjective then
                pcall(QuickObjective, "No active world modifiers on this map.", nil)
            end
            return
        end
        
        local text = "=== Active World Modifiers ===\n"
        for i, mod in ipairs(Game.world_modifiers) do
            local desc = mod.description
            if mod.value then
                desc = desc:gsub("%%v", tostring(mod.value) .. mod.unit)
            end
            text = text .. tostring(i) .. ") " .. mod.name .. ": " .. desc .. "\n"
        end
        
        if QuickObjective then
            pcall(QuickObjective, text, nil)
        end
    end
end

-- Register game triggers
if RegisterTimerEvent then
    RegisterTimerEvent("WorldModifiers_Init", 10, false)
    RegisterTimerEvent("WorldModifiers_Tick", 200, true) -- run every 10 seconds
end

if RegisterOnChatMsgEvent then
    RegisterOnChatMsgEvent("WorldModifiers_OnChat")
else
    pcall(CreateTrigger, "ChatMsg", "WorldModifiers_OnChat", {})
end

pcall(CreateTrigger, "ApplyDamage", "WorldModifiers_OnApplyDamage", {})
pcall(CreateTrigger, "Death", "WorldModifiers_OnCreatureDeath", {})
