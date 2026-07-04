-- upgrades.lua
-- V17 training-contract polish pass: blocks bonus-level reward loops, clamps objective progress, and improves streak safety.
-- Persistent upgrade shop opened via the /upgrades chat command.
-- Upgrades are permanent, infinite-stacking, cross-map persistent.
-- Purchases spend Upgrade Gold, a secondary currency mirrored from gold gains.
-- Navigation: /upgrades             → show tab list
--             /upgrades <tab>       → list upgrades in tab (1-6 or name)
--             /upgrades <tab> <sub> → list sub-tab upgrades (a or b)
--             /upgrades info <id>   → show upgrade details
--             /upgrades buy <id>    → purchase one rank of upgrade <id>
--             /upgrades buymax      → manually buy max efficient upgrades
--             /upgrades status      → show owned upgrades summary
-- All purchased effects are re-applied every time a map loads.

Game = Game or {}
Upgrades = Upgrades or {}
Upgrades.data_path   = "upgrades.dat"
Upgrades.price_scale = 1.20       -- adjusted for slightly smoother early/mid progression; inflation still protects late-rank balance
Upgrades.timer_registered = Upgrades.timer_registered or false
Upgrades.trigger_registered = Upgrades.trigger_registered or false
Upgrades.upgrade_gold_granted = Upgrades.upgrade_gold_granted or 0  -- tracks gold granted by upgrades in current session
Upgrades.upgrade_currency = Upgrades.upgrade_currency or 0
Upgrades.currency_label = "Upgrade Gold"
Upgrades.version = "v17-training-contract-polish"
-- Auto Buy Max spends Upgrade Gold on the highest-ROI affordable upgrades.
Upgrades.buymax_auto_enabled = true
Upgrades.buymax_auto_min_roi = 0 -- Auto Buy should continue as long as there's a benefit
Upgrades.buymax_auto_last_turn = Upgrades.buymax_auto_last_turn or 0
Upgrades.buymax_auto_interval = 6000 -- 5 minutes at 20 ticks/sec
Upgrades.buymax_auto_announced_turn = Upgrades.buymax_auto_announced_turn or -1
Upgrades.buymax_auto_startup_skip_announcement = (Upgrades.buymax_auto_startup_skip_announcement or 2)
Upgrades.buymax_auto_block_until_turn = math.huge
Upgrades.rival_roll_session_id = Upgrades.rival_roll_session_id or os.time()
Upgrades.automation_profile = Upgrades.automation_profile or "auto"
-- DNC learning rate; how quickly DNC memory shapes the mortality score
Upgrades.dnc_learning_rate = Upgrades.dnc_learning_rate or 0.25
Upgrades.dnc_memory = Upgrades.dnc_memory or {}
Upgrades.awakenings = Upgrades.awakenings or {}
Upgrades.bounty_contract = Upgrades.bounty_contract or nil
Upgrades.bounty_contract_streak = Upgrades.bounty_contract_streak or 0

local MAX_SAFE_COST = 10 ^ 300

-- Forward declarations for helpers referenced by earlier closures.
-- Lua locals are only visible after declaration, so these prevent runtime
-- fallbacks to nil globals when rival profiles/contracts are generated.
local BOUNTY_CONTRACTS
local hydrate_bounty_contract
local contract_reward_for
local bounty_streak_bonus_multiplier
local clamp_bounty_streak
local player_to_idx
local clamp
local analyze_dnc_pattern
local adaptive_game_state
local analyze_player_upgrade_profile
local get_counter_build_multipliers
local get_kill_method_multipliers
local ai_buy_max
local get_player_game_state
local determine_ai_tactical_mode
local apply_tactical_mode_bias
local get_ai_roster_profile


-- Global tuning knobs. These preserve progression, but make stacked ranks less map-breaking.
local EFFECT_POWER = 0.75
local ECONOMY_POWER = 0.75
local COMBAT_POWER = 0.95
local UTILITY_POWER = 0.80
local RIVAL_POWER = 1.75          -- strong rivals, but slightly less spike-prone than v7
local RIVAL_KEEPER_SCORE_MULT = 1.85
local RIVAL_HERO_SCORE_MULT = 2.45
local RIVAL_BASE_SCORE = 80
local RIVAL_KEEPER_CREATURE_CAP = 30
local RIVAL_HERO_CREATURE_CAP = 55
local PROGRESS_REWARD_SCALE = 0.11
local KILL_REWARD_SCALE = 0.08
local LIQUIDATOR_RATE = 0.025
local LIQUIDATOR_UPGRADE_GOLD_RATIO = 0.25
local MAX_EFFECTIVE_UTILITY_RANK = 28
-- Economy/reward upgrades are intentionally uncapped in v7.
-- The remaining caps below are safety caps for speed, healing/refund loops, hidden synergy spikes,
-- command/creature limits, and numeric overflow protection.
local MAX_POWER_REFUND = 60
local MAX_POWER_HEAL = 80
local MAX_HEAL_BACK_PERCENT = 35
local MAX_HEAL_BACK_FLAT = 60
local MAX_JUGGERNAUT_BONUS = 60
local MAX_BULK_BUY_RANKS = 500
local MAX_BOUNTY_PROGRESS_PER_EVENT = 4

-- ─────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────

local function safe_call(fn, ...)
    if type(fn) ~= "function" then return false end
    local ok, err = pcall(fn, ...)
    if not ok then
        print("Upgrades: " .. tostring(err))
    end
    return ok
end

clamp_bounty_streak = function(value)
    return math.max(0, math.min(10, math.floor(tonumber(value) or 0)))
end

local NON_WRITABLE_FIELDS = {}
local FAILED_CONFIG_FIELDS = {}

local function set_live_field(obj, field, value)
    if not obj or NON_WRITABLE_FIELDS[field] then return false end
    local ok = pcall(function() obj[field] = value end)
    if not ok then
        NON_WRITABLE_FIELDS[field] = true
        return false
    end
    return true
end

local function get_live_field(obj, field)
    if not obj or NON_WRITABLE_FIELDS[field] then return nil end
    local ok, value = pcall(function() return obj[field] end)
    if not ok then
        NON_WRITABLE_FIELDS[field] = true
        return nil
    end
    return value
end

local function set_config_field(setter, thing_type, field, value)
    local key = tostring(thing_type) .. "." .. tostring(field)
    if FAILED_CONFIG_FIELDS[key] then return false end
    local ok, err = pcall(setter, thing_type, field, value)
    if not ok then
        FAILED_CONFIG_FIELDS[key] = true
        print("Upgrades: " .. tostring(err))
        return false
    end
    return true
end

local function is_upgrade_unlocked(u)
    if not u then return false end
    if type(u.hidden) ~= "function" then return true end
    local ok, locked = pcall(u.hidden)
    if not ok then
        print("Upgrades: hidden check failed for #" .. tostring(u.id) .. ": " .. tostring(locked))
        return false
    end
    return not locked
end

local function event_player(eventData)
    if not eventData then return nil end
    return eventData.Player or eventData.player or eventData.Owner or eventData.owner or
           eventData.Caster or eventData.caster or eventData.DealingPlayer or eventData.dealing_player
end

local function event_subject(eventData)
    if not eventData then return nil end
    return eventData.Thing or eventData.thing or eventData.Target or eventData.target or
           eventData.Unit or eventData.unit or eventData.Creature or eventData.creature or
           eventData.Source or eventData.source
end

-- Correct number suffixes: SI/short scale, then AA, AB, ...
-- Uses adaptive precision: more decimals for smaller values, fewer for huge ones.
local function format_gold(n)
    n = tonumber(n) or 0
    if n ~= n then return "0" end
    if n == math.huge or n >= MAX_SAFE_COST then return "MAX" end
    n = math.floor(math.max(0, n))
    if n < 1000 then return tostring(n) end
    -- Short scale suffixes (up to 10^303)
    local suffixes = {
        "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", -- 10^0 to 10^33
        "Dc", "Ud", "Dd", "Td", "Qad", "Qid", "Sxd", "Spd", "Ocd", "Nod", -- 10^36 to 10^63
        "Vg", "Uvg", "Dvg", "Tvg", "Qavg", "Qivg", "Sxvg", "Spvg", "Ocvg", "Novg", -- 10^66 to 10^93
        "Tg", "Utg", "Dtg", "Ttg", "Qatg", "Qitg", "Sxtg", "Sptg", "Octg", "Notg", -- 10^96 to 10^123
        "Qag", "Uqag", "Dqag", "Tqag", "Qaqag", "Qiqag", "Sxqag", "Spqag", "Ocqag", "Noqag", -- 10^126 to 10^153
        "Qig", "Uqig", "Dqig", "Tqig", "Qaqig", "Qiqig", "Sxqig", "Spqig", "Ocqig", "Noqig", -- 10^156 to 10^183
        "Sxg", "Usxg", "Dsxg", "Tsxg", "Qasxg", "Qisxg", "Sxsxg", "Spsxg", "Ocsxg", "Nosxg", -- 10^186 to 10^213
        "Spg", "Uspg", "Dspg", "Tspg", "Qaspg", "Qispg", "Sxspg", "Spspg", "Ocspg", "Nospg", -- 10^216 to 10^243
        "Ocg", "Uocg", "Docg", "Tocg", "Qaocg", "Qiocg", "Sxocg", "Spocg", "Ococg", "Noocg", -- 10^246 to 10^273
        "Nog", "Unog", "Dnog", "Tnog", "Qanog", "Qinog", "Sxnog", "Spnog", "Ocnog", "Nonog"  -- 10^276 to 10^303
    }
    local idx = math.floor(math.log(n) / math.log(1000))
    local divisor = 1000 ^ idx
    local value = n / divisor

    -- Adaptive precision: 2 decimals for small (K-M), 1 for large (B-Qi), 0 for huge
    local decimals
    if idx <= 1 then
        decimals = 2  -- K
    elseif idx <= 3 then
        decimals = 1  -- M, B
    else
        decimals = 0  -- T and beyond
    end

    -- Clamp to rounded display value and promote cleanly at suffix boundaries.
    -- Without this, values like 999,950 could display as 999.95K instead of 1M.
    local precision_unit = 1 / (10 ^ decimals)
    value = math.floor(value * (10 ^ decimals) + 0.5) / (10 ^ decimals)

    if value >= (1000 - (precision_unit * 0.5)) and idx + 1 < #suffixes then
        idx = idx + 1
        divisor = 1000 ^ idx
        value = n / divisor
        if idx <= 1 then
            decimals = 2
        elseif idx <= 3 then
            decimals = 1
        else
            decimals = 0
        end
        value = math.floor(value * (10 ^ decimals) + 0.5) / (10 ^ decimals)
    end

    if idx < #suffixes then
        if decimals > 0 then
            local str = string.format("%." .. decimals .. "f", value)
            str = string.gsub(str, "0+$", "")
            str = string.gsub(str, "%.$", "")
            return str .. suffixes[idx + 1]
        end
        return math.floor(value + 0.5) .. suffixes[idx + 1]
    end

    -- Beyond: 2-letter alpha suffixes AA, AB, AC, ... ZZ
    local extra = idx - (#suffixes - 1)
    local function alpha_suffix(num)
        -- Spreadsheet-style suffixes: AA..ZZ, AAA..ZZZ, etc.
        -- This avoids wrapping back to AA at extreme ranks.
        num = math.max(1, math.floor(tonumber(num) or 1)) + 26
        local chars = {}
        while num > 0 do
            num = num - 1
            table.insert(chars, 1, string.char(65 + (num % 26)))
            num = math.floor(num / 26)
        end
        return table.concat(chars)
    end
    if decimals > 0 then
        return string.format("%." .. decimals .. "f%s", value, alpha_suffix(extra))
    end
    return math.floor(value + 0.5) .. alpha_suffix(extra)
end

function Upgrades.get_upgrade_gold()
    return math.max(0, math.floor(tonumber(Upgrades.upgrade_currency) or 0))
end

function Upgrades.add_upgrade_gold(amount)
    amount = tonumber(amount) or 0
    -- Work in raw floating value first to avoid precision loss from multiple floors
    local raw = (tonumber(Upgrades.upgrade_currency) or 0) + amount
    if raw <= 0 then
        Upgrades.upgrade_currency = 0
        Upgrades._dirty = true
        return 0
    end
    -- Only floor at the final storage step; no intermediate get_upgrade_gold() call
    Upgrades.upgrade_currency = math.min(MAX_SAFE_COST, math.floor(raw + 0.5))
    -- track granted gold using the full positive amount, not the truncated self-check
    if amount > 0 then
        Upgrades.upgrade_gold_granted = (Upgrades.upgrade_gold_granted or 0) + math.floor(amount)
    end
    Upgrades._dirty = true
    return Upgrades.upgrade_currency
end

local function upgrade_gold()
    return Upgrades.get_upgrade_gold()
end

local function deduct_upgrade_gold(amount)
    Upgrades.add_upgrade_gold(-amount)
end

function Upgrades.get_ai_upgrade_gold(player_idx)
    Game.upgrades_ai_gold = Game.upgrades_ai_gold or {}
    return math.max(0, math.floor(tonumber(Game.upgrades_ai_gold[player_idx]) or 0))
end

function Upgrades.add_ai_upgrade_gold(player_idx, amount)
    Game.upgrades_ai_gold = Game.upgrades_ai_gold or {}
    amount = tonumber(amount) or 0
    local raw = (tonumber(Game.upgrades_ai_gold[player_idx]) or 0) + amount
    if raw <= 0 then
        Game.upgrades_ai_gold[player_idx] = 0
        return 0
    end
    Game.upgrades_ai_gold[player_idx] = math.min(MAX_SAFE_COST, math.floor(raw + 0.5))
    return Game.upgrades_ai_gold[player_idx]
end

local function deduct_ai_upgrade_gold(player_idx, amount)
    Upgrades.add_ai_upgrade_gold(player_idx, -amount)
end

local function all_creature_types()
    return {
        "ARCHER","AVATAR","BARBARIAN","BILE_DEMON","BIRD","BUG",
        "DARK_MISTRESS","DEMONSPAWN","DRAGON","DRUID","DWARFA","FAIRY",
        "FLOATING_SPIRIT","FLY","GHOST","GIANT","HELL_HOUND","HORNY",
        "IMP","KNIGHT","MAIDEN","MONK","ORC","SAMURAI","SKELETON",
        "SORCEROR","SPIDER","SPIDERLING","TENTACLE","THIEF","TIME_MAGE",
        "TROLL","TUNNELLER","VAMPIRE","WITCH","WIZARD"
    }
end

local CREATURE_BASE_CONFIG = {
    ARCHER = { Health = 300, Strength = 20, Dexterity = 100, Defence = 90, BaseSpeed = 48, GoldHold = 250, Pay = 63, TrainingCost = 8 },
    AVATAR = { Health = 3000, Strength = 150, Dexterity = 160, Defence = 165, BaseSpeed = 48, GoldHold = 1000, Pay = 1200, TrainingCost = 100 },
    BARBARIAN = { Health = 700, Strength = 60, Dexterity = 70, Defence = 90, BaseSpeed = 48, GoldHold = 1500, Pay = 95, TrainingCost = 40 },
    BILE_DEMON = { Health = 1400, Strength = 80, Dexterity = 40, Defence = 60, BaseSpeed = 48, GoldHold = 3000, Pay = 98, TrainingCost = 38 },
    BIRD = { Health = 275, Strength = 20, Dexterity = 55, Defence = 45, BaseSpeed = 132, GoldHold = 75, Pay = 0, TrainingCost = 7 },
    BUG = { Health = 250, Strength = 25, Dexterity = 55, Defence = 60, BaseSpeed = 48, GoldHold = 300, Pay = 18, TrainingCost = 8 },
    DARK_MISTRESS = { Health = 700, Strength = 75, Dexterity = 70, Defence = 35, BaseSpeed = 72, GoldHold = 750, Pay = 175, TrainingCost = 24 },
    DEMONSPAWN = { Health = 325, Strength = 50, Dexterity = 70, Defence = 75, BaseSpeed = 48, GoldHold = 250, Pay = 70, TrainingCost = 15 },
    DRAGON = { Health = 1100, Strength = 90, Dexterity = 60, Defence = 75, BaseSpeed = 32, GoldHold = 5000, Pay = 350, TrainingCost = 40 },
    DRUID = { Health = 400, Strength = 24, Dexterity = 90, Defence = 35, BaseSpeed = 48, GoldHold = 260, Pay = 135, TrainingCost = 32 },
    DWARFA = { Health = 500, Strength = 50, Dexterity = 55, Defence = 45, BaseSpeed = 80, GoldHold = 500, Pay = 35, TrainingCost = 5 },
    FAIRY = { Health = 150, Strength = 10, Dexterity = 70, Defence = 45, BaseSpeed = 96, GoldHold = 250, Pay = 59, TrainingCost = 4 },
    FLOATING_SPIRIT = { Health = 1, Strength = 1, Dexterity = 1, Defence = 1, BaseSpeed = 128, GoldHold = 0, Pay = 0, TrainingCost = 0 },
    FLY = { Health = 150, Strength = 10, Dexterity = 50, Defence = 45, BaseSpeed = 128, GoldHold = 50, Pay = 5, TrainingCost = 5 },
    GHOST = { Health = 200, Strength = 20, Dexterity = 90, Defence = 90, BaseSpeed = 64, GoldHold = 1000, Pay = 20, TrainingCost = 20 },
    GIANT = { Health = 650, Strength = 100, Dexterity = 60, Defence = 45, BaseSpeed = 32, GoldHold = 1000, Pay = 43, TrainingCost = 35 },
    HELL_HOUND = { Health = 600, Strength = 55, Dexterity = 70, Defence = 75, BaseSpeed = 96, GoldHold = 500, Pay = 67, TrainingCost = 14 },
    HORNY = { Health = 2000, Strength = 110, Dexterity = 140, Defence = 105, BaseSpeed = 96, GoldHold = 2500, Pay = 950, TrainingCost = 150 },
    IMP = { Health = 75, Strength = 5, Dexterity = 60, Defence = 7, BaseSpeed = 112, GoldHold = 500, Pay = 0, TrainingCost = 10 },
    KNIGHT = { Health = 950, Strength = 80, Dexterity = 150, Defence = 45, BaseSpeed = 40, GoldHold = 600, Pay = 540, TrainingCost = 40 },
    MAIDEN = { Health = 800, Strength = 55, Dexterity = 60, Defence = 40, BaseSpeed = 48, GoldHold = 800, Pay = 133, TrainingCost = 20 },
    MONK = { Health = 325, Strength = 40, Dexterity = 80, Defence = 120, BaseSpeed = 32, GoldHold = 750, Pay = 75, TrainingCost = 12 },
    ORC = { Health = 700, Strength = 65, Dexterity = 60, Defence = 100, BaseSpeed = 48, GoldHold = 600, Pay = 95, TrainingCost = 15 },
    SAMURAI = { Health = 700, Strength = 80, Dexterity = 90, Defence = 105, BaseSpeed = 64, GoldHold = 750, Pay = 195, TrainingCost = 50 },
    SKELETON = { Health = 500, Strength = 55, Dexterity = 70, Defence = 75, BaseSpeed = 64, GoldHold = 500, Pay = 70, TrainingCost = 20 },
    SORCEROR = { Health = 350, Strength = 20, Dexterity = 100, Defence = 45, BaseSpeed = 32, GoldHold = 400, Pay = 120, TrainingCost = 30 },
    SPIDER = { Health = 400, Strength = 40, Dexterity = 60, Defence = 75, BaseSpeed = 48, GoldHold = 250, Pay = 25, TrainingCost = 18 },
    SPIDERLING = { Health = 200, Strength = 20, Dexterity = 30, Defence = 40, BaseSpeed = 54, GoldHold = 75, Pay = 0, TrainingCost = 10 },
    TENTACLE = { Health = 700, Strength = 50, Dexterity = 65, Defence = 75, BaseSpeed = 32, GoldHold = 500, Pay = 45, TrainingCost = 14 },
    THIEF = { Health = 250, Strength = 30, Dexterity = 120, Defence = 120, BaseSpeed = 48, GoldHold = 1750, Pay = 57, TrainingCost = 12 },
    TIME_MAGE = { Health = 470, Strength = 30, Dexterity = 100, Defence = 30, BaseSpeed = 32, GoldHold = 500, Pay = 165, TrainingCost = 30 },
    TROLL = { Health = 450, Strength = 40, Dexterity = 50, Defence = 75, BaseSpeed = 48, GoldHold = 500, Pay = 50, TrainingCost = 12 },
    TUNNELLER = { Health = 350, Strength = 40, Dexterity = 40, Defence = 60, BaseSpeed = 48, GoldHold = 1500, Pay = 50, TrainingCost = 10 },
    VAMPIRE = { Health = 1100, Strength = 90, Dexterity = 80, Defence = 120, BaseSpeed = 56, GoldHold = 4000, Pay = 750, TrainingCost = 50 },
    WITCH = { Health = 300, Strength = 20, Dexterity = 80, Defence = 45, BaseSpeed = 48, GoldHold = 400, Pay = 75, TrainingCost = 16 },
    WIZARD = { Health = 450, Strength = 20, Dexterity = 120, Defence = 45, BaseSpeed = 32, GoldHold = 500, Pay = 125, TrainingCost = 30 },
}

local function creature_type_key(value)
    local key = tostring(value or ""):upper()
    return key:gsub("%s+", "_")
end

local function base_creature_health(value)
    local base = CREATURE_BASE_CONFIG[creature_type_key(value)]
    return base and base.Health
end

local function base_creature_config(value)
    return CREATURE_BASE_CONFIG[creature_type_key(value)]
end

local player_creature_cap_value

local function enforce_player_creature_cap()
    safe_call(MaxCreatures, PLAYER0, player_creature_cap_value and player_creature_cap_value() or 30)
end

local function computer_player_list()
    local players = {}
    for _, ref in ipairs({PLAYER1, PLAYER2, PLAYER3, PLAYER4, PLAYER5, PLAYER6, PLAYER_GOOD}) do
        if ref ~= nil and (type(ref) == "table" or type(ref) == "userdata") then
            players[#players + 1] = ref
        end
    end
    return players
end

local function enforce_computer_creature_caps()
    for _, p in ipairs(computer_player_list()) do
        safe_call(MaxCreatures, p, p == PLAYER_GOOD and RIVAL_HERO_CREATURE_CAP or RIVAL_KEEPER_CREATURE_CAP)
    end
end

-- ─────────────────────────────────────────────
-- Upgrade definitions
-- ─────────────────────────────────────────────
-- Each entry: id, tab(1-6), subtab(1-2), name, desc, base_cost, apply(rank)
-- tab names: 1=Economy, 2=Combat, 3=Creatures, 4=Magic, 5=Dungeon
-- subtab names per tab given in Upgrades.tab_info below

local UPGRADES = {
    -- ═══════════════════════════════ TAB 1: ECONOMY ══════════════════════════════
    -- Sub-tab 1-A: Income
    {id= 2, tab=1, sub=1, name="Royal Tribute",
     desc="Each rank increases periodic in-match gold tribute.",
     base=300,
     apply=function(rank) end},

    {id= 3, tab=1, sub=1, name="Blood Money",
     desc="Each rank boosts creature loyalty by 2. (Game mechanic applied.)",
     base=180,
     apply=function(rank) end},

    {id=31, tab=1, sub=1, name="Tribute Network",
     desc="Each rank increases periodic in-match tribute.",
     base=600,
     apply=function(rank) end},

    {id=37, tab=1, sub=1, name="Silent Tithe",
     desc="Each rank adds 8 offline income scaling and 3 in-match tithe scaling.",
     base=650,
     apply=function(rank) end},

    {id=38, tab=1, sub=1, name="Vault Interest",
     desc="Each rank adds +2 base offline Upgrade Gold income per second and periodic in-match interest.",
     base=750,
     apply=function(rank) end},

    {id=42, tab=1, sub=1, name="Arcane Vault (Synergy)",
     desc="Hidden Synergy: Rank 50 Vault Interest & Ancient Tomes + 1M Gold Hoarded. Unused mana boosts offline gold.",
     base=6000,
     hidden=function() return Upgrades.get_rank(42) == 0 and (Upgrades.get_rank(38) < 50 or Upgrades.get_rank(22) < 50 or (Upgrades.awakenings.gold_hoarded or 0) < 1000000) end,
     apply=function(rank) end},

    {id=44, tab=1, sub=2, name="Vault of Souls",
     desc="Each rank permanently increases the physical storage capacity of your Treasury rooms.",
     base=900,
     apply=function(rank) end},
     
    {id= 6, tab=1, sub=2, name="Pay Reduction",
     desc="Each rank lowers the training wage cost number. (Game mechanic applied.)",
     base=450,
     apply=function(rank) end},

    -- ═══════════════════════════════ TAB 2: COMBAT ═══════════════════════════════
    -- Sub-tab 2-A: Offense
    {id= 7, tab=2, sub=1, name="Battle Fury",
     desc="Each rank increases all creature strength by 2. Your minions have been hitting the gym.",
     base=300,
     apply=function(rank) end},

    {id= 8, tab=2, sub=1, name="Predator's Edge",
     desc="Each rank increases all creature dexterity by 2. They're getting flexible.",
     base=280,
     apply=function(rank) end},

    {id= 9, tab=2, sub=1, name="Soul Fire",
     desc="Each rank increases spell damage by 2. (Game mechanic applied.)",
     base=350,
     apply=function(rank) end},

    {id=33, tab=2, sub=1, name="Arc Bolts",
     desc="Each rank adds +1 extra spell damage. (Game mechanic applied.)",
     base=400,
     apply=function(rank) end},

    -- Sub-tab 2-B: Defense
    {id=10, tab=2, sub=2, name="Iron Skin",
     desc="Each rank increases all creature health by 2. Thick skin, thicker skulls.",
     base=320,
     apply=function(rank) end},

    {id=11, tab=2, sub=2, name="Plate Hides",
     desc="Each rank increases all creature defense by 2. Nothing gets through. Not even love.",
     base=300,
     apply=function(rank) end},

    {id=12, tab=2, sub=2, name="Battle Scars",
     desc="Each rank adds 3 living creature HP scaling. (Game mechanic applied.)",
     base=400,
     apply=function(rank) end},

    -- ══════════════════════════ TAB 3: CREATURES ═════════════════════════════════
    -- Sub-tab 3-A: Recruitment
    {id=13, tab=3, sub=1, name="Open Gates",
     desc="Creature cap stays 30. Each rank increases hand command capacity by 2.",
     base=450,
     apply=function(rank)
         enforce_player_creature_cap()
     end},

    {id=14, tab=3, sub=1, name="Dark Reputation",
     desc="Creature cap stays 30. Each rank increases hand command capacity by 1.",
     base=550,
     apply=function(rank)
         enforce_player_creature_cap()
     end},

    {id=15, tab=3, sub=1, name="Rally Standards",
     desc="Each rank improves creature loyalty and living creature HP. (Game mechanic applied.)",
     base=400,
     apply=function(rank) end},

    -- Sub-tab 3-B: Growth
    {id=16, tab=3, sub=2, name="Veteran Corps",
     desc="Creature cap stays 30. Each rank increases hand command capacity by 2.",
     base=650,
     apply=function(rank)
         enforce_player_creature_cap()
     end},

    {id=17, tab=3, sub=2, name="Veteran Drills",
     desc="Each rank improves creature strength and defense. (Game mechanic applied.)",
     base=360,
     apply=function(rank) end},

    {id=18, tab=3, sub=2, name="War Economy",
     desc="Each rank lowers the scavenging cost number. (Game mechanic applied.)",
     base=320,
     apply=function(rank) end},

    {id=35, tab=3, sub=2, name="Brood Pits",
     desc="Creature cap stays 30. Each rank increases hand command capacity by 3.",
     base=800,
     apply=function(rank)
         enforce_player_creature_cap()
     end},

    -- ════════════════════════════ TAB 4: MAGIC ═══════════════════════════════════
    -- Sub-tab 4-A: Spells
    {id=19, tab=4, sub=1, name="Arcane Mastery",
     desc="Each rank increases spell range by 2. (Game mechanic applied.)",
     base=360,
     apply=function(rank) end},

    {id=21, tab=4, sub=1, name="Swift Hex",
     desc="Each rank lowers the spell cast pay number. (Game mechanic applied.)",
     base=320,
     apply=function(rank) end},

    {id=43, tab=4, sub=1, name="Blood Magic (Synergy)",
     desc="Hidden Synergy: Rank 50 Soul Fire & Swift Hex + 500 Spells Cast. Spells drain health when gold is empty.",
     base=4500,
     hidden=function() return Upgrades.get_rank(43) == 0 and (Upgrades.get_rank(9) < 50 or Upgrades.get_rank(21) < 50 or (Upgrades.awakenings.spells_cast or 0) < 500) end,
     apply=function(rank) end},

    -- Sub-tab 4-B: Research
    {id=22, tab=4, sub=2, name="Ancient Tomes",
     desc="Each rank adds 5 Research room efficiency and rewards research progress. (Game mechanic applied.)",
     base=420,
     apply=function(rank) end},

    {id=23, tab=4, sub=2, name="Workshop Mastery",
     desc="Each rank adds 5 Workshop room efficiency and rewards manufacture progress. (Game mechanic applied.)",
     base=420,
     apply=function(rank) end},

    {id=24, tab=4, sub=2, name="Dark Scholarship",
     desc="Each rank adds 5 Training room efficiency and can grant bonus level-ups. (Game mechanic applied.)",
     base=380,
     apply=function(rank) end},

    {id=34, tab=4, sub=2, name="Library Annex",
     desc="Each rank adds 5 extra Research efficiency and rewards research progress. (Game mechanic applied.)",
     base=450,
     apply=function(rank) end},

    -- ════════════════════════════ TAB 5: DUNGEON ═════════════════════════════════
    -- Sub-tab 5-A: Infrastructure
    {id=26, tab=5, sub=1, name="Fortified Walls",
     desc="Each rank adds 10 door health scaling to wood, braced, and steel doors. (Game mechanic applied.)",
     base=400,
     apply=function(rank) end},

    {id=27, tab=5, sub=1, name="Hellish Furnace",
     desc="Each rank adds 5 Scavenger room efficiency and rewards scavenging gains. (Game mechanic applied.)",
     base=360,
     apply=function(rank) end},

    {id=36, tab=5, sub=1, name="Iron Carcasses",
     desc="Each rank adds 8 extra door health scaling to wood, braced, and steel doors. (Game mechanic applied.)",
     base=520,
     apply=function(rank) end},

    {id=40, tab=5, sub=1, name="Juggernaut (Synergy)",
     desc="Hidden Synergy: Requires Battle Fury & Iron Skin Rank 50. Massive strength & defense scaling.",
     base=2000,
     hidden=function() return Upgrades.get_rank(40) == 0 and (Upgrades.get_rank(7) < 50 or Upgrades.get_rank(10) < 50) end,
     apply=function(rank) end},

    {id=41, tab=5, sub=1, name="The Training Dummy",
     desc="Each rank increases offline training speed by 10% (max 200%).",
     base=500,
     apply=function(rank) end},

    -- Sub-tab 5-B: Warband
    {id=28, tab=5, sub=2, name="War Banners",
     desc="Creature cap stays 30. Each rank increases hand command capacity by 1.",
     base=1200,
     apply=function(rank) end},

    -- ─────────────────────────────────────────────
    -- Tab 6: Traps & Doors
    -- ─────────────────────────────────────────────
    -- Sub-tab 6-A: Lethality
    {id=45, tab=6, sub=1, name="Trap Mechanisms",
     desc="Enhances trap reliability. (Future mechanics planned for trigger speed.)",
     base=600,
     apply=function(rank) end},

    -- Sub-tab 6-B: Resilience
    {id=46, tab=6, sub=2, name="Reinforced Hinges",
     desc="Adds structural reinforcement to your doors, allowing minor self-repair over time.",
     base=700,
     apply=function(rank) end},

    -- V8 Fun-Balance additions
    {id=47, tab=2, sub=1, name="Bounty Board",
     desc="Unlocks rotating bounty contracts and increases Upgrade Gold earned from kills. Aggressive, varied, and capped to avoid snowballing.",
     base=720,
     apply=function(rank) end},

    {id=48, tab=2, sub=2, name="Comeback Pact",
     desc="Each rank grants a small capped Upgrade Gold refund when one of your creatures dies. Helps recovery, not snowballing.",
     base=760,
     apply=function(rank) end},

    {id=49, tab=3, sub=2, name="Momentum Drills",
     desc="Each rank adds a small capped Upgrade Gold reward when your creatures level up. Rewards active training and survival.",
     base=680,
     apply=function(rank) end},

    {id=50, tab=6, sub=1, name="Rival Contracts",
     desc="Each rank slightly strengthens rival scaling but also improves kill bounties. Pick this when you want spicier maps.",
     base=900,
     apply=function(rank) end},
}

-- -----------------------------------------------------------------------------
-- Balance pass (applies to all upgrades)
-- -----------------------------------------------------------------------------

local BALANCE_COST_TAB = {
    [1] = 0.90,  -- Economy even cheaper early
    [2] = 1.00,  -- Combat baseline
    [3] = 0.95,  -- Creature line cheaper
    [4] = 1.00,  -- Magic baseline (was 1.03, reduced so it's not penalized)
    [5] = 1.00,  -- Dungeon baseline
    [6] = 1.00,  -- Traps baseline
}

local BALANCE_COST_ID = {
    [2]=0.95, [3]=0.92, [6]=1.02,
    [7]=1.05, [8]=1.06, [9]=1.08, [10]=1.05, [11]=1.05, [12]=1.08,
    [13]=0.65, [14]=0.65, [15]=1.05, [16]=0.65, [17]=1.05, [18]=0.95,
    [19]=1.06, [21]=1.00, [22]=1.00, [23]=1.00, [24]=0.98,
    [26]=1.05, [27]=0.95, [28]=0.65,
    [31]=1.02, [33]=1.05, [34]=1.00, [35]=0.65, [36]=1.05,
    [37]=1.00, [38]=1.04, [40]=1.15,
    [47]=1.04, [48]=0.98, [49]=0.96, [50]=1.06,
}

local _balance_pass_applied = false  -- local guard survives module reload properly

local function apply_balance_pass()
    if _balance_pass_applied then return end
    for _, u in ipairs(UPGRADES) do
        local tab_mult = BALANCE_COST_TAB[u.tab] or 1.0
        local id_mult = BALANCE_COST_ID[u.id] or 1.0
        u.base = math.max(50, math.floor((u.base * tab_mult * id_mult) + 0.5))
    end
    _balance_pass_applied = true
end

apply_balance_pass()

-- Build lookup table
Upgrades._by_id = {}
for _, u in ipairs(UPGRADES) do
    Upgrades._by_id[u.id] = u
end

-- ─────────────────────────────────────────────
-- Tab / sub-tab metadata
-- ─────────────────────────────────────────────

Upgrades.tab_info = {
    [1] = { name = "Economy",     subs = { [1]="Income",         [2]="Storage"        } },
    [2] = { name = "Combat",      subs = { [1]="Offense",        [2]="Defense"        } },
    [3] = { name = "Creatures",   subs = { [1]="Recruitment",    [2]="Growth"         } },
    [4] = { name = "Magic",       subs = { [1]="Spells",         [2]="Research"       } },
    [5] = { name = "Dungeon",     subs = { [1]="Rooms",          [2]="Warband"        } },
    [6] = { name = "Traps & Doors", subs = { [1]="Lethality",    [2]="Resilience"     } },
}

-- ─────────────────────────────────────────────
-- Persistence  (plain CSV: id=rank,id=rank,…)
-- ─────────────────────────────────────────────

function Upgrades.load()
    local f = io.open(Upgrades.data_path, "r")
    Game.upgrades_ranks = {}
    if not f then return end

    local content = f:read("*all") or ""
    f:close()

    local loaded_ranks = {}
    for pair in content:gmatch("[^,]+") do
        local id, rank = pair:match("^(%d+)=(%d+)$")
        if id and rank then
            local upgrade_id = tonumber(id)
            local clean_rank = math.max(0, math.floor(tonumber(rank) or 0))
            if Upgrades._by_id[upgrade_id] and clean_rank > 0 then
                loaded_ranks[upgrade_id] = clean_rank
            end
        else
            local key, value = pair:match("^([%a_]+)=([^,]+)$")
            if key == "upgrade_gold" and value then
                Upgrades.upgrade_currency = math.max(0, math.floor(tonumber(value) or 0))
            elseif key == "automation_profile" and value then
                if value == "balanced" or value == "aggro" or value == "turtle" or value == "auto" then
                    Upgrades.automation_profile = value
                end
            elseif key == "ppo_weights" and value then
                Upgrades.ppo_weights = {}
                for w in value:gmatch("[^|]+") do
                    if #Upgrades.ppo_weights < 5 then
                        table.insert(Upgrades.ppo_weights, math.max(0.25, math.min(4.0, tonumber(w) or 1.0)))
                    end
                end
                while #Upgrades.ppo_weights < 5 do
                    table.insert(Upgrades.ppo_weights, 1.0)
                end
            elseif key == "awakenings" and value then
                Upgrades.awakenings = {}
                for kv in value:gmatch("[^|]+") do
                    local ak, av = kv:match("([^:]+):(%d+)")
                    if ak and av then Upgrades.awakenings[ak] = tonumber(av) end
                end
            elseif key == "bounty_contract" and value then
                local kind, goal, progress, reward = value:match("([^:]+):(%d+):(%d+):(%d+)")
                if kind and goal and progress and reward then
                    Upgrades.bounty_contract = { kind=kind, goal=tonumber(goal), progress=tonumber(progress), reward=tonumber(reward), completed=false }
                    for _, t in ipairs(BOUNTY_CONTRACTS or {}) do
                        if t.kind == kind then
                            Upgrades.bounty_contract.name = t.name
                            Upgrades.bounty_contract.desc = t.desc
                            break
                        end
                    end
                else
                    -- Corrupt contract payloads should not poison the save forever.
                    Upgrades.bounty_contract = nil
                    Upgrades._dirty = true
                end
            elseif key == "bounty_streak" and value then
                Upgrades.bounty_contract_streak = clamp_bounty_streak(value)
            end
        end
    end
    Game.upgrades_ranks = loaded_ranks
    if hydrate_bounty_contract then hydrate_bounty_contract() end
end

function Upgrades.save()
    Game.upgrades_ranks = Game.upgrades_ranks or {}
    if hydrate_bounty_contract then hydrate_bounty_contract() end
    local parts = {
        "upgrade_gold=" .. tostring(Upgrades.get_upgrade_gold()),
        "automation_profile=" .. tostring(Upgrades.automation_profile or "balanced"),
        "bounty_streak=" .. tostring(clamp_bounty_streak(Upgrades.bounty_contract_streak))
    }
    if Upgrades.ppo_weights then
        parts[#parts+1] = "ppo_weights=" .. table.concat(Upgrades.ppo_weights, "|")
    end
    if Upgrades.awakenings and next(Upgrades.awakenings) then
        local awk_parts = {}
        for k, v in pairs(Upgrades.awakenings) do
            awk_parts[#awk_parts+1] = k .. ":" .. tostring(v)
        end
        parts[#parts+1] = "awakenings=" .. table.concat(awk_parts, "|")
    end
    if Upgrades.bounty_contract and not Upgrades.bounty_contract.completed then
        local c = Upgrades.bounty_contract
        parts[#parts+1] = "bounty_contract=" .. tostring(c.kind or "kill") .. ":" .. tostring(c.goal or 1) .. ":" .. tostring(c.progress or 0) .. ":" .. tostring(c.reward or 0)
    end
    for id, rank in pairs(Game.upgrades_ranks) do
        local clean_id = tonumber(id)
        local clean_rank = math.max(0, math.floor(tonumber(rank) or 0))
        if clean_id and Upgrades._by_id[clean_id] and clean_rank > 0 then
            parts[#parts + 1] = tostring(clean_id) .. "=" .. tostring(clean_rank)
        end
    end
    table.sort(parts)

    -- Write atomically where the Lua runtime allows it.  This prevents a crash
    -- during save from leaving upgrades.dat as a zero-byte file.
    local payload = table.concat(parts, ",")
    local tmp_path = tostring(Upgrades.data_path) .. ".tmp"
    local f, err = io.open(tmp_path, "w")
    if not f then
        print("Upgrades: failed to save " .. tostring(tmp_path) .. ": " .. tostring(err))
        return false
    end

    local ok, write_err = pcall(function()
        f:write(payload)
        f:close()
    end)
    if not ok then
        pcall(function() f:close() end)
        print("Upgrades: failed while writing save: " .. tostring(write_err))
        return false
    end

    local renamed = false
    if os and os.rename then
        os.remove(Upgrades.data_path) -- Required on Windows, os.rename fails if target exists
        renamed = os.rename(tmp_path, Upgrades.data_path)
    end
    if not renamed then
        -- Some sandboxed Lua builds disallow rename; fall back to direct write.
        local direct, direct_err = io.open(Upgrades.data_path, "w")
        if not direct then
            print("Upgrades: failed to save " .. tostring(Upgrades.data_path) .. ": " .. tostring(direct_err))
            return false
        end
        direct:write(payload)
        direct:close()
    end

    Upgrades._dirty = false
    return true
end

function Upgrades.get_rank(id)
    Game.upgrades_ranks = Game.upgrades_ranks or {}
    id = tonumber(id)
    if not id then return 0 end
    return Game.upgrades_ranks[id] or 0
end

function Upgrades.set_rank(id, rank)
    Game.upgrades_ranks = Game.upgrades_ranks or {}
    id = tonumber(id)
    if not Upgrades._by_id[id] then return end
    rank = math.max(0, math.floor(tonumber(rank) or 0))
    local diff = rank - (Game.upgrades_ranks[id] or 0)
    Game.upgrades_ranks[id] = rank
    Upgrades._dirty = true
    if diff > 0 then
        Upgrades.inflation = Upgrades.inflation or {}
        -- BALANCE: Reduced inflation per rank from 0.003 to 0.0010 so costs don't spiral
        -- as aggressively at high ranks. Decay is 0.0010 per 1000 ticks (~50s).
        -- At 0.0010/rank and 0.0010/1000-tick decay, buying 10 ranks adds 0.010 inflation
        -- which decays in ~10,000 ticks (~8 minutes). This keeps inflation meaningful
        -- but prevents it from becoming permanent over a long session.
        Upgrades.inflation[id] = (Upgrades.inflation[id] or 0) + (0.0010 * diff)
    end
end

-- Diminishing returns for every upgrade: rank 1 gives full value, while
-- later ranks continue to help but add progressively less.
function Upgrades.effective_rank(rank)
    rank = math.max(0, tonumber(rank) or 0)
    if rank <= 1 then return rank end
    return rank ^ EFFECT_POWER
end

local function tuned_rank(rank, power, cap)
    local value = Upgrades.effective_rank(rank)
    if power and power ~= 1.0 then
        value = value * power
    end
    if cap then
        value = math.min(cap, value)
    end
    return value
end

function Upgrades.effective_owned_rank(id)
    return Upgrades.effective_rank(Upgrades.get_rank(id))
end

local function scaled_effect(id, per_rank)
    return math.floor(tuned_rank(Upgrades.get_rank(id), COMBAT_POWER) * per_rank + 0.5)
end

local function scaled_economy_effect(id, per_rank, cap)
    return math.floor(tuned_rank(Upgrades.get_rank(id), ECONOMY_POWER, cap) * per_rank + 0.5)
end

local function scaled_utility_effect(id, per_rank, cap)
    return math.floor(tuned_rank(Upgrades.get_rank(id), UTILITY_POWER, cap) * per_rank + 0.5)
end

local function scaled_effect_at_rank(id, per_rank, rank_offset)
    local rank = math.max(0, Upgrades.get_rank(id) + (rank_offset or 0))
    return math.floor(tuned_rank(rank, COMBAT_POWER) * per_rank + 0.5)
end

local function scaled_total(id, base, per_rank)
    return base + scaled_effect(id, per_rank)
end

local function combined_scaled_effect(parts)
    local total = 0
    for _, part in ipairs(parts) do
        total = total + (tuned_rank(Upgrades.get_rank(part[1]), COMBAT_POWER) * part[2])
    end
    return math.floor(total + 0.5)
end

local function previous_combined_scaled_effect(parts, bought_id)
    local total = 0
    for _, part in ipairs(parts) do
        local rank = Upgrades.get_rank(part[1])
        if part[1] == bought_id then rank = math.max(0, rank - 1) end
        total = total + (tuned_rank(rank, COMBAT_POWER) * part[2])
    end
    return math.floor(total + 0.5)
end

local function combined_scaled_total(base, parts)
    return base + combined_scaled_effect(parts)
end

local function scaled_reduction_value(base, id, reduction)
    local per_rank = (1 - (tonumber(reduction) or 1)) * 100
    return math.max(1, math.floor((tonumber(base) or 100) - (Upgrades.effective_owned_rank(id) * per_rank) + 0.5))
end

local function scaled_reduction_value_at_rank(base, id, reduction, rank_offset)
    local rank = math.max(0, Upgrades.get_rank(id) + (rank_offset or 0))
    local per_rank = (1 - (tonumber(reduction) or 1)) * 100
    return math.max(1, math.floor((tonumber(base) or 100) - (Upgrades.effective_rank(rank) * per_rank) + 0.5))
end

local function rally_loyalty_bonus()
    return scaled_effect(15, 1)
end

-- Identical to rally_loyalty_bonus; both use same upgrade id 15.
-- Kept separate for descriptive clarity in status/UI output.
local function rally_hp_bonus()
    return rally_loyalty_bonus()
end

local function veteran_drill_bonus()
    return scaled_effect(17, 1)
end

local function juggernaut_bonus()
    return math.min(MAX_JUGGERNAUT_BONUS, scaled_effect(40, 5))
end

local function tribute_pulse_amount()
    local total = scaled_economy_effect(2, 10) + scaled_economy_effect(31, 18)
    return math.max(0, total)
end

local function research_efficiency_bonus()
    return scaled_utility_effect(22, 2, MAX_EFFECTIVE_UTILITY_RANK) +
           scaled_utility_effect(34, 2, MAX_EFFECTIVE_UTILITY_RANK)
end

local function workshop_efficiency_bonus()
    return scaled_utility_effect(23, 2, MAX_EFFECTIVE_UTILITY_RANK)
end

local function training_efficiency_bonus()
    return scaled_utility_effect(24, 2, MAX_EFFECTIVE_UTILITY_RANK)
end

local function scavenger_efficiency_bonus()
    return scaled_utility_effect(27, 2, MAX_EFFECTIVE_UTILITY_RANK)
end

function Upgrades.offline_training_speed_multiplier()
    return 1.0 + math.min(3.0, Upgrades.get_rank(41) * 0.1)
end

player_creature_cap_value = function()
    return 30
end

-- Command capacity: base 8, each rank of capacity upgrades adds diminishing returns.
-- Safety-capped at 30 because hand/engine limits can become unstable above that.
local function command_capacity_value()
    return math.min(30, 8 + combined_scaled_effect({ {13, 2}, {14, 1}, {16, 2}, {28, 1}, {35, 3} }))
end

local function command_capacity_value_at_rank(id, rank_offset)
    local parts = { {13, 2}, {14, 1}, {16, 2}, {28, 1}, {35, 3} }
    local total = 8
    for _, part in ipairs(parts) do
        local rank = Upgrades.get_rank(part[1])
        if part[1] == id then rank = math.max(0, rank + (rank_offset or 0)) end
        total = total + math.floor(Upgrades.effective_rank(rank) * part[2] + 0.5)
    end
    return math.min(30, total)
end

function Upgrades.offline_income_flat_bonus()
    return tuned_rank(Upgrades.get_rank(38), ECONOMY_POWER) * 2 + math.floor(tuned_rank(Upgrades.get_rank(37), ECONOMY_POWER) * 8 + 0.5)
end

local function silent_tithe_match_bonus()
    return scaled_economy_effect(37, 6)
end

local function vault_interest_match_bonus()
    return math.floor(Upgrades.offline_income_flat_bonus() * 4 + 0.5)
end

local function door_health_value()
    return 300 + scaled_utility_effect(26, 35) + scaled_utility_effect(36, 25)
end

local function door_health_value_at_rank(id, rank_offset)
    local rank26 = Upgrades.get_rank(26)
    local rank36 = Upgrades.get_rank(36)
    if id == 26 then rank26 = math.max(0, rank26 + (rank_offset or 0)) end
    if id == 36 then rank36 = math.max(0, rank36 + (rank_offset or 0)) end
    return 300 +
           math.floor(tuned_rank(rank26, UTILITY_POWER) * 35 + 0.5) +
           math.floor(tuned_rank(rank36, UTILITY_POWER) * 25 + 0.5)
end

-- V8 fun-balance helper effects. These add more positive feedback moments
-- without raw stat creep: bounty = aggression, comeback = recovery, momentum = survival/training.
local function bounty_board_bonus()
    return math.min(120, scaled_economy_effect(47, 3))
end

local function comeback_pact_refund()
    return math.min(150, scaled_economy_effect(48, 4))
end

local function momentum_drill_reward()
    return math.min(120, scaled_economy_effect(49, 3))
end

local function rival_contract_bonus()
    return math.min(0.35, tuned_rank(Upgrades.get_rank(50), UTILITY_POWER) * 0.006)
end

-- V9 Bounty Board contracts. These are lightweight rotating objectives tied to
-- real play events, so the board feels active without requiring fragile map hooks.
BOUNTY_CONTRACTS = {
    { kind="kill",    name="Cull the Invaders",    desc="Defeat enemy creatures",        base_goal=12, base_reward=250 },
    { kind="elite",   name="Trophy Hunt",          desc="Defeat level 6+ enemies",       base_goal=4,  base_reward=350 },
    { kind="levelup", name="Seasoned Survivors",   desc="Level up your creatures",       base_goal=3,  base_reward=300 },
    { kind="revenge", name="Blood Price",          desc="Defeat enemies after losses",    base_goal=6,  base_reward=400 },
}

local function bounty_template_by_kind(kind)
    for _, template in ipairs(BOUNTY_CONTRACTS or {}) do
        if template.kind == kind then return template end
    end
    return nil
end

hydrate_bounty_contract = function()
    local c = Upgrades.bounty_contract
    if not c then return nil end
    local template = bounty_template_by_kind(c.kind)
    if not template then
        -- Old/corrupt saves should not leave the board stuck on an impossible contract.
        Upgrades.bounty_contract = nil
        Upgrades._dirty = true
        return nil
    end
    c.name = template.name
    c.desc = template.desc
    c.goal = math.max(1, math.floor(tonumber(c.goal) or template.base_goal or 1))
    c.progress = math.max(0, math.min(c.goal, math.floor(tonumber(c.progress) or 0)))
    c.reward = math.max(25, math.floor(tonumber(c.reward) or contract_reward_for(template, c.goal) or template.base_reward or 25))
    c.completed = c.progress >= c.goal and true or false
    return c
end

local function creature_level_value(creature)
    if not creature then return 1 end
    return tonumber(creature.level or creature.Level or creature.exp_level or creature.ExpLevel or creature.EXP_LEVEL) or 1
end

local function contract_power_multiplier()
    return 1.0 + math.min(1.25, tuned_rank(Upgrades.get_rank(47), ECONOMY_POWER) * 0.025) + rival_contract_bonus()
end

bounty_streak_bonus_multiplier = function()
    -- Small streak reward for finishing contracts, capped so it feels good without snowballing.
    return 1.0 + math.min(0.50, clamp_bounty_streak(Upgrades.bounty_contract_streak) * 0.05)
end

contract_reward_for = function(template, goal)
    local strength = 0
    if Upgrades.compute_strength_score then
        local ok, score = pcall(Upgrades.compute_strength_score)
        if ok then strength = tonumber(score) or 0 end
    end
    local reward = ((template.base_reward or 100) + (goal * 8) + (strength * 0.012)) * contract_power_multiplier() * bounty_streak_bonus_multiplier()
    -- Prevent very long campaign strength scores from turning one contract into a runaway jackpot.
    local cap = MAX_SAFE_COST
    if template.kind == "kill" then
        cap = 250000 + (goal * 2500)
    elseif template.kind == "elite" then
        cap = 350000 + (goal * 4000)
    elseif template.kind == "levelup" then
        cap = 300000 + (goal * 3500)
    elseif template.kind == "revenge" then
        cap = 400000 + (goal * 4500)
    end
    return math.max(25, math.floor(math.min(reward, cap) + 0.5))
end

local function bounty_reroll_cost()
    if Upgrades.get_rank(47) <= 0 then return 0 end
    -- First board creation should be free; only actual rerolls cost Upgrade Gold.
    if not Upgrades.bounty_contract or Upgrades.bounty_contract.completed then return 0 end
    local current_reward = tonumber(Upgrades.bounty_contract.reward) or 0
    local rank_pressure = math.floor(tuned_rank(Upgrades.get_rank(47), ECONOMY_POWER) * 12 + 0.5)
    -- Small fee stops infinite fishing, but stays cheap enough that a bad contract can be skipped.
    -- The soft cap prevents high-rank contract rewards from making rerolls feel punitive.
    local raw = math.floor((current_reward * 0.05) + rank_pressure + 0.5)
    local soft_cap = math.max(30, math.floor(current_reward * 0.10 + 0.5))
    return math.max(15, math.min(raw, soft_cap))
end

function Upgrades.roll_bounty_contract(force, avoid_kind)
    if hydrate_bounty_contract then hydrate_bounty_contract() end
    if not force and Upgrades.bounty_contract and not Upgrades.bounty_contract.completed then
        return Upgrades.bounty_contract
    end
    if Upgrades.get_rank(47) <= 0 then
        Upgrades.bounty_contract = nil
        return nil
    end
    if not BOUNTY_CONTRACTS or #BOUNTY_CONTRACTS == 0 then
        Upgrades.bounty_contract = nil
        return nil
    end
    local candidates = {}
    for _, t in ipairs(BOUNTY_CONTRACTS) do
        if not avoid_kind or #BOUNTY_CONTRACTS <= 1 or t.kind ~= avoid_kind then
            candidates[#candidates + 1] = t
        end
    end
    if #candidates == 0 then candidates = BOUNTY_CONTRACTS end
    local template = candidates[math.random(1, #candidates)]
    local rank = Upgrades.get_rank(47)
    local goal_growth = math.sqrt(rank)
    if template.kind == "elite" or template.kind == "revenge" then
        goal_growth = goal_growth * 0.65
    elseif template.kind == "levelup" then
        goal_growth = goal_growth * 0.75
    end
    local goal = math.max(1, math.floor((template.base_goal or 5) + goal_growth + 0.5))
    Upgrades.bounty_contract = {
        kind = template.kind,
        name = template.name,
        desc = template.desc,
        goal = goal,
        progress = 0,
        reward = contract_reward_for(template, goal),
        completed = false,
    }
    Upgrades._dirty = true
    return Upgrades.bounty_contract
end

function Upgrades.bounty_contract_status_text()
    if hydrate_bounty_contract then hydrate_bounty_contract() end
    local c = Upgrades.roll_bounty_contract(false)
    if not c then
        return "=== BOUNTY BOARD ===\nBuy at least 1 rank of Bounty Board to unlock rotating contracts."
    end
    return "=== BOUNTY BOARD ===\n" .. tostring(c.name or "Contract") ..
           "\nObjective: " .. tostring(c.desc or c.kind or "Progress") ..
           "\nProgress: " .. tostring(math.min(c.progress or 0, c.goal or 1)) .. "/" .. tostring(c.goal or 1) ..
           "\nType: " .. tostring(c.kind or "unknown") ..
           "\nReward: " .. format_gold(c.reward or 0) .. " Upgrade Gold" ..
           "\nStreak: " .. tostring(clamp_bounty_streak(Upgrades.bounty_contract_streak)) .. " (+" .. tostring(math.floor((bounty_streak_bonus_multiplier() - 1.0) * 100 + 0.5)) .. "%)" ..
           "\nReroll Cost: " .. format_gold(bounty_reroll_cost()) .. " Upgrade Gold" ..
           "\nCommands: /u contract | /u contract reroll"
end

function Upgrades.advance_bounty_contract(kind, amount)
    if hydrate_bounty_contract then hydrate_bounty_contract() end
    local c = Upgrades.roll_bounty_contract(false)
    if not c or c.completed or c.kind ~= kind then return false end
    amount = math.floor(tonumber(amount) or 1)
    if amount <= 0 then return false end
    -- Safety clamp: one noisy engine event should not instantly complete a long objective.
    amount = math.min(MAX_BOUNTY_PROGRESS_PER_EVENT, amount)
    c.progress = math.min(c.goal or 1, (c.progress or 0) + amount)
    Upgrades._dirty = true
    if c.progress >= (c.goal or 1) then
        c.completed = true
        local reward = math.max(0, math.floor(tonumber(c.reward) or 0))
        if reward > 0 then Upgrades.add_upgrade_gold(reward) end
        Upgrades.bounty_contract_streak = clamp_bounty_streak((Upgrades.bounty_contract_streak or 0) + 1)
        Upgrades._dirty = true
        print("Bounty Board: completed " .. tostring(c.name or "contract") .. " for " .. format_gold(reward) .. " Upgrade Gold")
        Upgrades.roll_bounty_contract(true, c.kind)
        return true
    end
    return false
end

local function safe_upgrade_cost(base, scale, rank)
    base = math.max(1, tonumber(base) or 50)
    scale = math.max(1.01, tonumber(scale) or 1.15)
    rank = math.max(0, tonumber(rank) or 0)

    -- Avoid overflow/absurd values before math.floor.  Costs above this are
    -- intentionally unreachable but must remain printable/comparable.
    local log_cost = math.log(base) + (rank * math.log(scale))
    if log_cost >= math.log(MAX_SAFE_COST) then
        return MAX_SAFE_COST
    end

    local cost = math.floor(base * (scale ^ rank))
    if cost ~= cost or cost == math.huge or cost > MAX_SAFE_COST then return MAX_SAFE_COST end
    return math.max(1, cost)
end

-- ─────────────────────────────────────────────
-- Cost calculation
-- ─────────────────────────────────────────────

-- Returns the cost of the next rank of upgrade `id`.
-- Formula: base * (price_scale * (1 + inflation_per_point))^rank
function Upgrades.cost(id)
    local u = Upgrades._by_id[id]
    if not u then return 0 end
    local rank = math.max(0, tonumber(Upgrades.get_rank(id)) or 0)
    local inf = math.max(0, tonumber(Upgrades.inflation and Upgrades.inflation[id]) or 0)
    local effective_scale = math.max(1.01, (tonumber(Upgrades.price_scale) or 1.15) * (1.0 + inf))
    return safe_upgrade_cost(u.base, effective_scale, rank)
end

-- Returns the cost of upgrade `id` at a specific rank (NOT the next rank).
-- This is used by buy_max_one_upgrade to simulate costs without side effects.
-- Formula: base * (price_scale * (1 + inflation_per_point))^rank
function Upgrades.cost_at_rank(id, rank)
    local u = Upgrades._by_id[id]
    if not u then return 0 end
    rank = math.max(0, tonumber(rank) or 0)
    local inf = math.max(0, tonumber(Upgrades.inflation and Upgrades.inflation[id]) or 0)
    local effective_scale = math.max(1.01, (tonumber(Upgrades.price_scale) or 1.15) * (1.0 + inf))
    return safe_upgrade_cost(u.base, effective_scale, rank)
end

-- Returns the inflation-adjusted effective scale for an upgrade at a given rank.
-- Used by ROI functions to properly account for inflation in cost calculations.
local function effective_scale_at_rank(id, rank)
    local inf = math.max(0, tonumber(Upgrades.inflation and Upgrades.inflation[id]) or 0)
    return math.max(1.01, (tonumber(Upgrades.price_scale) or 1.15) * (1.0 + inf))
end

-- ─────────────────────────────────────────────
-- ROI system
-- ─────────────────────────────────────────────
-- Power weights reflect the real gameplay impact of each upgrade.
-- Used by buy_max to decide which upgrade delivers the most value
-- per Upgrade Gold spent at the current moment.
--
-- ROI formula:  roi(id) = power_weight[id] / (effective_scale ^ rank)
-- This naturally favours lower-ranked high-impact upgrades first,
-- and re-evaluates after every single purchase so the ordering
-- stays optimal as Upgrade Gold is spent.
-- FIX: ROI now accounts for inflation to match actual cost.

local ROI_WEIGHTS = {
    -- Economy (boosted to encourage strong early game macro scaling)
    [2]=0.52, [3]=0.58, [6]=0.60,
    [31]=0.62, [37]=0.65, [38]=0.60,
    -- Combat (Dexterity [8] boosted slightly to keep pace with Strength [7])
    [7]=1.40, [8]=1.25, [9]=1.26, [10]=1.38, [11]=1.12, [12]=1.20,
    -- Creatures
    -- Capacity upgrades raised to 0.65 to ensure strong dungeon population growth.
    [13]=0.65, [14]=0.65, [15]=0.86, [16]=0.65, [17]=0.78, [18]=0.66, [35]=0.65,
    -- Magic
    [19]=1.02, [21]=0.64, [22]=0.62, [23]=0.60, [24]=0.68,
    -- Dungeon
    [26]=0.90, [27]=0.72, [28]=0.65,
    -- Added upgrades
    [33]=1.08, [34]=0.68, [36]=0.86,
    [40]=1.70,
    [47]=1.02, [48]=0.92, [49]=0.88, [50]=0.70,
}

local ECONOMY_UPGRADES = { [2]=true, [3]=true, [6]=true, [31]=true, [37]=true, [38]=true }
local OFFENSE_UPGRADES = { [7]=true, [8]=true, [9]=true, [19]=true, [33]=true, [40]=true, [47]=true }
local DEFENSE_UPGRADES = { [10]=true, [11]=true, [12]=true, [26]=true, [27]=true, [36]=true, [48]=true }
local CREATURE_GROWTH_UPGRADES = { [13]=true, [14]=true, [15]=true, [16]=true, [17]=true, [18]=true, [35]=true, [49]=true }
local UTILITY_UPGRADES = { [21]=true, [22]=true, [23]=true, [24]=true, [28]=true, [34]=true, [50]=true }
local UPGRADE_STRENGTH_WEIGHTS

local AI_UPGRADE_PROFILES = {
    { offense = 1.70, defense = 0.85, economy = 0.75, creatures = 1.10, utility = 0.80, name = "Slayer" },
    { offense = 0.80, defense = 1.65, economy = 0.80, creatures = 1.15, utility = 0.95, name = "Guardian" },
    { offense = 0.90, defense = 0.90, economy = 1.75, creatures = 1.05, utility = 1.00, name = "Merchant" },
    { offense = 1.05, defense = 1.00, economy = 0.85, creatures = 1.75, utility = 0.90, name = "Breeder" },
    { offense = 0.95, defense = 1.05, economy = 0.95, creatures = 0.95, utility = 1.70, name = "Scholar" },
    { offense = 1.28, defense = 1.28, economy = 0.70, creatures = 1.22, utility = 0.80, name = "Warlord" },
    { offense = 0.88, defense = 0.88, economy = 1.35, creatures = 0.95, utility = 1.35, name = "Tactician" },
    -- Wacky/Extreme profiles for more fun variations
    { offense = 2.50, defense = 0.40, economy = 1.20, creatures = 0.50, utility = 0.50, name = "Glass Cannon" },
    { offense = 0.50, defense = 2.50, economy = 1.50, creatures = 0.80, utility = 0.40, name = "Immortal Turtle" },
    { offense = 0.50, defense = 0.50, economy = 0.50, creatures = 2.80, utility = 1.50, name = "Mega Swarm" },
    { offense = 1.80, defense = 1.80, economy = 0.20, creatures = 0.20, utility = 1.50, name = "Elite Juggernaut" },
    -- New Keeper Profiles
    { offense = 1.50, defense = 0.70, economy = 0.60, creatures = 1.40, utility = 1.80, name = "Necromancer" },
    { offense = 0.80, defense = 1.80, economy = 1.50, creatures = 0.60, utility = 1.30, name = "Industrialist" }
}

local HERO_UPGRADE_PROFILES = {
    { offense = 1.20, defense = 2.20, economy = 0.50, creatures = 1.40, utility = 0.70, name = "Crusader" }, -- Knight-heavy
    { offense = 2.20, defense = 0.70, economy = 0.50, creatures = 0.80, utility = 1.80, name = "Archmage" }, -- Wizard-heavy
    { offense = 1.40, defense = 0.90, economy = 1.80, creatures = 1.10, utility = 0.80, name = "Rogue" },    -- Thief-heavy
    { offense = 1.40, defense = 1.40, economy = 0.80, creatures = 1.40, utility = 1.00, name = "Avenging Force" },
    { offense = 1.90, defense = 1.10, economy = 0.60, creatures = 1.60, utility = 0.90, name = "Zealot" }
}

-- AI specialization traits: permanent modifiers that shape a rival's identity.
-- Each trait biases upgrade category weights and can enable unique behaviors.
local AI_TRAITS = {
    { name = "Brute",      offense=1.35, defense=1.25, economy=0.85, creatures=0.95, utility=0.80, desc="Pounds enemies into submission with raw force." },
    { name = "Swarm",      offense=0.90, defense=0.95, economy=0.90, creatures=1.60, utility=0.85, desc="Overwhelms through sheer numbers and rapid recruitment." },
    { name = "Sniper",     offense=1.30, defense=0.80, economy=0.95, creatures=0.90, utility=1.15, desc="Prefers precision: dexterity, spell damage, and range." },
    { name = "Hoarder",    offense=0.80, defense=0.90, economy=1.55, creatures=0.90, utility=1.00, desc="Amasses wealth and uses it to outlast opponents." },
    { name = "Tactician",  offense=0.95, defense=0.90, economy=0.95, creatures=0.85, utility=1.45, desc="Out-thinks the enemy with magic and efficiency." },
    { name = "Berserker",  offense=1.50, defense=1.40, economy=0.60, creatures=0.70, utility=0.60, desc="Fights harder when wounded; relentless aggression." },
    { name = "Despot",     offense=1.20, defense=1.10, economy=0.75, creatures=1.50, utility=0.95, desc="Commands highly-trained cohorts; periodically levels up weakest minions." },
    { name = "Warlock",    offense=1.40, defense=0.70, economy=1.10, creatures=0.80, utility=1.60, desc="A master of dark magics and utility spells." },
}

local HERO_TRAITS = {
    { name = "Paladin",    offense=1.20, defense=1.50, economy=0.70, creatures=1.20, utility=0.90, desc="Righteous protector with balanced combat prowess." },
    { name = "Shadow",     offense=1.50, defense=0.70, economy=1.30, creatures=0.80, utility=1.20, desc="Strikes from darkness with gold-fueled subterfuge." },
    { name = "Inquisitor", offense=1.75, defense=1.10, economy=0.50, creatures=1.20, utility=1.20, desc="Purges heretics; deals bonus damage to high-level player creatures." },
    { name = "Archon",     offense=1.30, defense=1.30, economy=0.60, creatures=1.40, utility=1.40, desc="Empowers heroes with divine synergy; all heroes gain +1 level when spawning." },
    { name = "Assassin",   offense=1.80, defense=0.50, economy=1.00, creatures=0.90, utility=1.50, desc="Highly lethal but fragile; prioritizes taking down the Dungeon Heart quickly." },
}

local function random_range(low, high)
    return low + math.random() * (high - low)
end

local function ai_upgrade_category_multiplier(id, profile)
    profile = profile or {}
    if OFFENSE_UPGRADES[id] then return profile.offense or 1 end
    if DEFENSE_UPGRADES[id] then return profile.defense or 1 end
    if ECONOMY_UPGRADES[id] then return profile.economy or 1 end
    if CREATURE_GROWTH_UPGRADES[id] then return profile.creatures or 1 end
    if UTILITY_UPGRADES[id] then return profile.utility or 1 end
    return 1
end

local function make_ai_upgrade_profile(is_hero, player)
    local base_list = is_hero and HERO_UPGRADE_PROFILES or AI_UPGRADE_PROFILES
    local trait_list = is_hero and HERO_TRAITS or AI_TRAITS
    local base = base_list[math.random(1, #base_list)]
    local profile = { name = base.name }
    for k, v in pairs(base) do
        if k ~= "name" then
            profile[k] = v * random_range(0.60, 1.50)
        end
    end

    -- Apply permanent specialization trait (stored per-rival)
    local p_idx = player and player_to_idx(player)
    local trait_name = p_idx and (Game.upgrades_ai_traits or {})[p_idx]
    local trait = nil
    if trait_name then
        for _, t in ipairs(trait_list) do
            if t.name == trait_name then trait = t; break end
        end
    end
    if not trait then
        -- Fallback: assign random trait if not yet stored
        trait = trait_list[math.random(1, #trait_list)]
        if p_idx then
            Game.upgrades_ai_traits = Game.upgrades_ai_traits or {}
            Game.upgrades_ai_traits[p_idx] = trait.name
        end
    end
    if trait then
        for k, v in pairs(trait) do
            if k ~= "name" and k ~= "desc" then
                profile[k] = (profile[k] or 1) * v
            end
        end
        profile.name = profile.name .. " (" .. trait.name .. ")"
        profile.trait_desc = trait.desc
        profile.trait = trait.name
    end

    -- DNC-aware adaptation: read death patterns and adjust
    local dnc = analyze_dnc_pattern()
    local s = adaptive_game_state()

    if dnc.pattern == "burst" then
        -- Got nuked: hard pivot to defense
        profile.defense = (profile.defense or 1) * (1.0 + dnc.intensity * 2.5)
        profile.offense = (profile.offense or 1) * (1.0 - dnc.intensity * 0.4)
        profile.creatures = (profile.creatures or 1) * (1.0 + dnc.intensity * 1.0)
        profile.name = profile.name .. " (Reeling)"
    elseif dnc.pattern == "grinding" then
        -- Sustained losses: boost both defense and creature growth
        profile.defense = (profile.defense or 1) * (1.0 + dnc.intensity * 1.2)
        profile.creatures = (profile.creatures or 1) * (1.0 + dnc.intensity * 0.8)
        profile.offense = (profile.offense or 1) * (1.0 - dnc.intensity * 0.3)
        profile.name = profile.name .. " (Attrited)"
    elseif dnc.pattern == "recovering" then
        -- Recovering: lean into economy to rebuild
        profile.economy = (profile.economy or 1) * (1.0 + dnc.intensity * 0.8)
        profile.offense = (profile.offense or 1) * (1.0 + dnc.intensity * 0.4)
        profile.name = profile.name .. " (Rebuilding)"
    end

    -- Creature-roster-aware bias: AI invests in upgrades that match its army
    if player and GetCreatures then
        local roster = get_ai_roster_profile(player)
        profile.offense = (profile.offense or 1) * roster.strength
        profile.utility = (profile.utility or 1) * roster.dexterity
        profile.defense = (profile.defense or 1) * roster.defense
    end

    -- Counter-building: analyze player's upgrade tabs and counter-invest
    local player_up = analyze_player_upgrade_profile()
    local counter = get_counter_build_multipliers(player_up)
    for k, v in pairs(counter) do
        profile[k] = (profile[k] or 1) * v
    end
    if player_up.dominance > 0.3 then
        local dom_name = ({[1]="Economy",[2]="Combat",[3]="Creatures",[4]="Magic",[5]="Dungeon"})[player_up.dominant] or "?"
        profile.name = profile.name .. " (anti-" .. dom_name .. ")"
    end

    -- Kill-method awareness: adapt to how the player fights
    local kill_mult = get_kill_method_multipliers()
    for k, v in pairs(kill_mult) do
        if v ~= 1 then profile[k] = (profile[k] or 1) * v end
    end

    -- Tactical mode: short-term situational override
    local p_state = player and get_player_game_state(player) or s
    local mode = determine_ai_tactical_mode(player, p_state)
    profile = apply_tactical_mode_bias(profile, mode)
    if mode ~= "balanced" then
        profile.name = profile.name .. " [" .. mode:upper() .. "]"
    end

    -- Late-game escalation: all AI become more aggressive over time
    local turn = PLAYER0 and PLAYER0.GAME_TURN or 0
    if turn > 24000 then
        local late_factor = 1.0 + clamp((turn - 24000) / 24000, 0, 1.0)
        profile.offense = (profile.offense or 1) * late_factor
        profile.defense = (profile.defense or 1) * late_factor
        profile.name = profile.name .. " (Escalated)"
    end

    -- Berserker trait special: bonus when wounded
    if trait and trait.name == "Berserker" then
        local wounded_ratio = p_state and p_state.wounded_ratio or 0
        local berserk_mult = 1.0 + wounded_ratio * 0.8
        profile.offense = (profile.offense or 1) * berserk_mult
        profile.defense = (profile.defense or 1) * berserk_mult
    end

    if math.random() < 0.25 then
        profile.economy = (profile.economy or 1) * random_range(0.30, 2.20)
    end
    return profile
end

local function ai_upgrade_roll_weight(id, profile, jitter_low, jitter_high)
    local base = UPGRADE_STRENGTH_WEIGHTS[id] or 1.0
    return math.max(0.05, base * ai_upgrade_category_multiplier(id, profile) * random_range(jitter_low or 0.35, jitter_high or 2.50))
end

local function weighted_random_upgrade_id(ids, profile, jitter_low, jitter_high)
    local total = 0
    local choices = {}
    for _, id in ipairs(ids or {}) do
        local weight = ai_upgrade_roll_weight(id, profile, jitter_low, jitter_high)
        total = total + weight
        choices[#choices + 1] = { id = id, weight = weight }
    end
    if total <= 0 or #choices == 0 then return nil end

    local roll = math.random() * total
    local current = 0
    for _, choice in ipairs(choices) do
        current = current + choice.weight
        if roll <= current then
            return choice.id
        end
    end
    return choices[#choices].id
end

local is_player_creature

clamp = function(value, low, high)
    value = tonumber(value) or 0
    if value < low then return low end
    if value > high then return high end
    return value
end

local _cached_creatures_turn = -1
local _cached_creatures_count = 0
local _cached_wounded_count = 0

local function count_player_creatures()
    if not GetCreatures then return 0, 0 end
    local turn = PLAYER0 and PLAYER0.GAME_TURN or 0
    if turn > 0 and _cached_creatures_turn == turn then
        return _cached_creatures_count, _cached_wounded_count
    end

    local count, wounded = 0, 0
    for _, creature in ipairs(GetCreatures() or {}) do
        if is_player_creature(creature) then
            count = count + 1
            local hp = tonumber(creature.health)
            local max_hp = tonumber(creature.max_health)
            if hp and max_hp and max_hp > 0 and hp < max_hp * 0.55 then
                wounded = wounded + 1
            end
        end
    end

    _cached_creatures_turn = turn
    _cached_creatures_count = count
    _cached_wounded_count = wounded
    return count, wounded
end

local function count_creatures_for_player(player)
    if not GetCreatures then return 0, 0, 1 end
    local count, wounded, sum_level = 0, 0, 0
    for _, creature in ipairs(GetCreatures() or {}) do
        local same_owner = false
        if creature and creature.owner then
            if type(creature.owner) == "number" then
                same_owner = (player.playerId and creature.owner == player.playerId)
            else
                same_owner = (creature.owner == player) or (player.playerId and creature.owner.playerId == player.playerId)
            end
        end
        if same_owner then
            count = count + 1
            local hp = tonumber(creature.health)
            local max_hp = tonumber(creature.max_health)
            if hp and max_hp and max_hp > 0 and hp < max_hp * 0.55 then
                wounded = wounded + 1
            end
            sum_level = sum_level + (tonumber(creature.level) or 1)
        end
    end
    local avg_level = count > 0 and (sum_level / count) or 1
    return count, wounded, avg_level
end

local function count_room_tiles(player, room_type)
    if not GetRoomsOfPlayerAndType then return 0 end
    local rooms = GetRoomsOfPlayerAndType(player, room_type)
    if not rooms then return 0 end
    return #rooms
end

local function seconds_since(turn, now)
    turn = tonumber(turn)
    now = tonumber(now) or 0
    if not turn or turn <= 0 then return math.huge end
    return math.max(0, (now - turn) / 20)
end

local function get_player_game_state(player)
    local turn = PLAYER0 and PLAYER0.GAME_TURN or 0
    local creature_count, wounded_count, avg_level = count_creatures_for_player(player)
    local cap = player == PLAYER_GOOD and RIVAL_HERO_CREATURE_CAP or RIVAL_KEEPER_CREATURE_CAP
    if player == PLAYER0 then
        cap = math.max(1, tonumber(player_creature_cap_value and player_creature_cap_value()) or 30)
    end
    
    local gold = player.MONEY or 0
    local state = {
        turn = turn,
        early = clamp(1 - (turn / 12000), 0, 1),
        late = clamp((turn - 12000) / 24000, 0, 1),
        gold = gold,
        creature_shortage = clamp(1 - (creature_count / cap), 0, 1),
        wounded_ratio = clamp(wounded_count / math.max(1, creature_count), 0, 1),
        avg_level = avg_level,
        threat_level = 0,
        under_attack = 0,
        deaths = 0
    }
    
    -- Threat Level based on distance of PLAYER0 forces to this player's heart
    if player ~= PLAYER0 and player.heart and player.heart.isValid and player.heart:isValid() and player.heart.pos then
        local heart_pos = player.heart.pos
        local min_dist = math.huge
        if GetCreatures then
            for _, creature in ipairs(GetCreatures() or {}) do
                if creature.owner == PLAYER0 and creature.pos and creature.isValid and creature:isValid() then
                    local dx = creature.pos.val_x - heart_pos.val_x
                    local dy = creature.pos.val_y - heart_pos.val_y
                    local dist = math.sqrt(dx*dx + dy*dy)
                    if dist < min_dist then min_dist = dist end
                end
            end
        end
        if min_dist < 11520 then
            state.threat_level = clamp(1 - (min_dist / 11520), 0, 1)
        end
    end

    if player == PLAYER0 then
        state.under_attack = seconds_since(Upgrades._recent_damage_taken_turn, turn) <= 45 and 1 or 0
        state.deaths = clamp((tonumber(Upgrades._mortality_score) or 0) / 8, 0, 1.5)
    else
        state.under_attack = state.threat_level > 0.1 and 1 or 0
        state.deaths = clamp(state.creature_shortage * 1.5, 0, 1.5)
    end
    
    return state
end


adaptive_game_state = function()
    local turn = PLAYER0 and PLAYER0.GAME_TURN or 0
    local creature_count, wounded_count = count_player_creatures()
    local cap = math.max(1, tonumber(player_creature_cap_value and player_creature_cap_value()) or 30)
    local gold = upgrade_gold()
    local cheapest = Upgrades._cached_cheapest
    if not cheapest or (Upgrades._cached_cheapest_turn ~= turn) then
        cheapest = math.huge
        for _, u in ipairs(UPGRADES) do
            if is_upgrade_unlocked(u) then
                cheapest = math.min(cheapest, Upgrades.cost(u.id))
            end
        end
        if cheapest == math.huge then cheapest = 1 end
        Upgrades._cached_cheapest = cheapest
        Upgrades._cached_cheapest_turn = turn
    end

    local state = {
        turn = turn,
        early = clamp(1 - (turn / 12000), 0, 1),
        late = clamp((turn - 12000) / 24000, 0, 1),
        bank = clamp(gold / math.max(1, cheapest * 8), 0, 2),
        creature_shortage = clamp(1 - (creature_count / cap), 0, 1),
        wounded_ratio = clamp(wounded_count / math.max(1, creature_count), 0, 1),
        under_attack = 0,
        attacking = 0,
        deaths = clamp((tonumber(Upgrades._mortality_score) or 0) / 8, 0, 1.5),
    }

    local taken_age = seconds_since(Upgrades._recent_damage_taken_turn, turn)
    local dealt_age = seconds_since(Upgrades._recent_damage_dealt_turn, turn)
    local death_age = seconds_since(Upgrades._last_death_turn, turn)

    state.under_attack = math.max(
        taken_age <= 45 and (1 - taken_age / 45) or 0,
        death_age <= 90 and (1 - death_age / 90) or 0
    )
    state.attacking = dealt_age <= 45 and (1 - dealt_age / 45) or 0

    return state
end

local function adaptive_roi_multiplier(id, tab)
    local s = adaptive_game_state()
    local mult = 1.0

    if ECONOMY_UPGRADES[id] then
        mult = mult * (1.0 + 0.55 * s.early + 0.25 * s.creature_shortage)
        mult = mult * (1.0 - 0.30 * s.under_attack)
        mult = mult * (1.0 - 0.15 * s.late)
        mult = mult * (1.0 - 0.40 * math.min(1, s.deaths))
    end

    if OFFENSE_UPGRADES[id] then
        mult = mult * (1.0 + 0.55 * s.attacking + 0.25 * s.under_attack + 0.18 * s.late)
        mult = mult * (1.0 + 0.15 * math.max(0, s.bank - 1.5))
    end

    if DEFENSE_UPGRADES[id] then
        mult = mult * (1.0 + 0.75 * s.under_attack + 0.55 * s.deaths + 0.35 * s.wounded_ratio + 0.15 * s.late)
    end

    if CREATURE_GROWTH_UPGRADES[id] then
        mult = mult * (1.0 + 0.65 * s.creature_shortage + 0.25 * s.early)
        mult = mult * (1.0 + 0.25 * s.under_attack)
    end

    if UTILITY_UPGRADES[id] then
        mult = mult * (1.0 + 0.18 * s.early + 0.35 * s.bank)
        if tab == 4 and (s.attacking > 0.15 or s.under_attack > 0.15) then
            mult = mult * 1.18
        end
    end

    if s.bank > 1.0 then
        mult = mult * (1.0 + math.min(0.20, (s.bank - 1.0) * 0.10))
    end

    return clamp(mult, 0.35, 2.75)
end

local function adaptive_focus_label()
    if not Upgrades.buymax_auto_enabled and (Upgrades.automation_profile or "balanced") ~= "auto" then
        return tostring(Upgrades.automation_profile or "balanced")
    end

    local s = adaptive_game_state()
    if s.under_attack > 0.35 or s.deaths > 0.4 or s.wounded_ratio > 0.25 then
        return "defense"
    elseif s.attacking > 0.35 then
        return "offense"
    elseif s.creature_shortage > 0.45 then
        return "growth"
    elseif s.early > 0.35 then
        return "economy"
    end
    return "balanced"
end

-- ─────────────────────────────────────────────
-- AI intelligence helpers
-- ─────────────────────────────────────────────

-- Analyze DNC death memory to detect patterns the AI can react to.
-- Returns a table with pattern type and intensity.
analyze_dnc_pattern = function()
    local mem = Upgrades.dnc_memory or {}
    local total, recent, peak, recent_waves = 0, 0, 0, 0
    local current_wave = PLAYER0 and math.floor((PLAYER0.GAME_TURN or 0) / 1000) or 0
    for wave, count in pairs(mem) do
        total = total + count
        if count > peak then peak = count end
        if wave >= current_wave - 3 then
            recent = recent + count
            recent_waves = recent_waves + 1
        end
    end
    local pattern = "stable"
    local intensity = 0
    if recent_waves > 0 then
        local avg_recent = recent / recent_waves
        local avg_all = math.max(1, total / math.max(1, current_wave + 1))
        if avg_recent > avg_all * 2.5 and avg_recent >= 3 then
            pattern = "burst"    -- sudden death spike: got nuked
            intensity = clamp(avg_recent / 10, 0, 1)
        elseif avg_recent > avg_all * 1.2 then
            pattern = "grinding" -- sustained losses: getting chipped
            intensity = clamp(avg_recent / 6, 0, 1)
        elseif avg_recent < avg_all * 0.5 then
            pattern = "recovering" -- deaths declining: stabilizing
            intensity = clamp(1 - (avg_recent / math.max(1, avg_all)), 0, 1)
        end
    end
    return { pattern = pattern, intensity = intensity, total = total, recent = recent, peak = peak }
end

-- Scan an AI player's current creature roster and return dominant type categories.
-- Returns multipliers for strength/dexterity/defense/heavy preferences.
function get_ai_roster_profile(player)
    local str_count, dex_count, def_count, total = 0, 0, 0, 0
    if not GetCreatures then return { strength=1, dexterity=1, defense=1, heavy=1 } end

    local strength_types = { ARCHER=true, BARBARIAN=true, BILE_DEMON=true, DARK_MISTRESS=true, DEMONSPAWN=true, DRAGON=true, GIANT=true, HELL_HOUND=true, HORNY=true, KNIGHT=true, ORC=true, SAMURAI=true, SKELETON=true, TROLL=true, VAMPIRE=true, WITCH=true }
    local dexterity_types = { BIRD=true, DRUID=true, FAIRY=true, GHOST=true, MONK=true, SPIDER=true, THIEF=true, TIME_MAGE=true, WIZARD=true }
    local defense_types = { DWARFA=true, MAIDEN=true, TENTACLE=true, TUNNELLER=true }

    for _, creature in ipairs(GetCreatures() or {}) do
        local same_owner = false
        if creature and creature.owner then
            if type(creature.owner) == "number" then
                same_owner = (player.playerId and creature.owner == player.playerId)
            else
                same_owner = (creature.owner == player) or (player.playerId and creature.owner.playerId == player.playerId)
            end
        end
        if same_owner and creature.model then
            total = total + 1
            local key = creature.model:upper()
            if strength_types[key] then str_count = str_count + 1 end
            if dexterity_types[key] then dex_count = dex_count + 1 end
            if defense_types[key] then def_count = def_count + 1 end
        end
    end

    if total == 0 then return { strength=1, dexterity=1, defense=1, heavy=1 } end
    return {
        strength = 1.0 + (str_count / total) * 0.6,
        dexterity = 1.0 + (dex_count / total) * 0.6,
        defense = 1.0 + (def_count / total) * 0.6,
        heavy = 1.0 + ((str_count + def_count) / total) * 0.4,  -- heavy hitters + tanks = slow but powerful
    }
end

-- Determine the AI player's current tactical mode based on game state.
local function determine_ai_tactical_mode(player, state)
    state = state or {}
    if state.under_attack and state.under_attack > 0.5 then
        return "defensive"
    end
    if state.deaths and state.deaths > 0.6 then
        return "defensive"
    end
    if state.creature_shortage and state.creature_shortage > 0.5 then
        return "growth"
    end
    if state.gold and state.gold < 500 then
        return "economic"
    end
    if state.turn and state.turn > 25000 and (not state.deaths or state.deaths < 0.3) then
        return "aggressive"
    end
    -- Late game favors aggression
    if state.turn and state.turn > 35000 then
        return "aggressive"
    end
    return "balanced"
end

-- Apply tactical mode bias to a profile table.
local function apply_tactical_mode_bias(profile, mode)
    if mode == "defensive" then
        profile.defense = (profile.defense or 1) * 1.6
        profile.offense = (profile.offense or 1) * 0.8
        profile.creatures = (profile.creatures or 1) * 1.3
        profile.economy = (profile.economy or 1) * 0.7
    elseif mode == "growth" then
        profile.creatures = (profile.creatures or 1) * 1.7
        profile.economy = (profile.economy or 1) * 1.2
        profile.offense = (profile.offense or 1) * 0.7
    elseif mode == "economic" then
        profile.economy = (profile.economy or 1) * 1.8
        profile.defense = (profile.defense or 1) * 1.2
        profile.utility = (profile.utility or 1) * 1.2
    elseif mode == "aggressive" then
        profile.offense = (profile.offense or 1) * 1.7
        profile.defense = (profile.defense or 1) * 0.7
        profile.creatures = (profile.creatures or 1) * 0.8
    end
    return profile
end

-- ─────────────────────────────────────────────
-- Counter-building & kill-profiling
-- ─────────────────────────────────────────────

-- Scan the player's purchased upgrade ranks per tab.
-- Used by AI to determine where the player is strong and counter-invest.
analyze_player_upgrade_profile = function()
    local tabs = { [1]=0, [2]=0, [3]=0, [4]=0, [5]=0 }
    for id, rank in pairs(Game.upgrades_ranks or {}) do
        local u = Upgrades._by_id[id]
        if u and u.tab then
            tabs[u.tab] = (tabs[u.tab] or 0) + rank
        end
    end
    -- Normalize: find dominant and secondary tabs
    local max_tab, max_val, second_val = 1, tabs[1], 0
    for t = 2, 5 do
        local v = tabs[t] or 0
        if v > max_val then second_val = max_val; max_val = v; max_tab = t
        elseif v > second_val then second_val = v end
    end
    local total = max_val + second_val
    return {
        dominant = max_tab,
        dominance = total > 0 and (max_val - second_val) / total or 0,
        economy = tabs[1] or 0,
        combat = tabs[2] or 0,
        creatures = tabs[3] or 0,
        magic = tabs[4] or 0,
        dungeon = tabs[5] or 0,
    }
end

-- Returns counter-building multipliers for an AI profile based on what
-- the player has invested in. High player combat → AI boosts defense, etc.
get_counter_build_multipliers = function(player_profile)
    if not player_profile then return { offense=1, defense=1, economy=1, creatures=1, utility=1 } end
    local mult = { offense=1, defense=1, economy=1, creatures=1, utility=1 }
    local dom = player_profile.dominant
    local dom_intensity = 1.0 + player_profile.dominance * 0.6  -- stronger counter if player is lopsided

    if dom == 1 then
        -- Player is economy-heavy: pressure them with offense
        mult.offense = 1.0 + 0.45 * dom_intensity
        mult.creatures = 1.0 + 0.25 * dom_intensity
    elseif dom == 2 then
        -- Player is combat-heavy: bunker down
        mult.defense = 1.0 + 0.55 * dom_intensity
        mult.creatures = 1.0 + 0.30 * dom_intensity  -- more bodies to absorb
    elseif dom == 3 then
        -- Player is creature-heavy: kill their army faster
        mult.offense = 1.0 + 0.50 * dom_intensity
        mult.defense = 1.0 + 0.25 * dom_intensity
    elseif dom == 4 then
        -- Player is magic-heavy: spread out with creatures
        mult.creatures = 1.0 + 0.50 * dom_intensity
        mult.defense = 1.0 + 0.35 * dom_intensity
    elseif dom == 5 then
        -- Player is dungeon-heavy: attack from all angles
        mult.offense = 1.0 + 0.40 * dom_intensity
        mult.utility = 1.0 + 0.30 * dom_intensity
    end
    return mult
end

-- Track what method the player uses to kill things.
-- Updated in Upgrades_OnApplyDamage and Upgrades_OnCreatureDeath.
-- Returns a profile: { trap=0..1, creature=0..1, spell=0..1 }
local KILL_METHOD_DECAY = 0.97  -- per-pulse decay so old data fades
local function analyze_player_kill_method()
    local kp = Upgrades._kill_profile or { trap=0, creature=0, spell=0, ranged=0 }
    local total = kp.trap + kp.creature + kp.spell + kp.ranged
    if total == 0 then return { trap=0.33, creature=0.34, spell=0.33 } end
    return {
        trap = kp.trap / total,
        creature = kp.creature / total,
        spell = kp.spell / total,
        ranged = kp.ranged / total,
    }
end

-- Apply kill-method awareness: if player mostly uses traps, AI boosts door health;
-- if mostly creatures, AI boosts combat; if mostly spells, AI boosts defense.
get_kill_method_multipliers = function()
    local km = analyze_player_kill_method()
    local mult = { offense=1, defense=1, economy=1, creatures=1, utility=1 }
    if km.trap > 0.40 then
        -- Player relies on traps: AI invests in door health and utility
        mult.defense = mult.defense + km.trap * 0.5
        mult.utility = mult.utility + km.trap * 0.3
    end
    if km.creature > 0.40 then
        -- Player fights with creatures: match their combat investment
        mult.offense = mult.offense + km.creature * 0.5
        mult.defense = mult.defense + km.creature * 0.3
    end
    if km.spell > 0.30 then
        -- Player uses spells heavily: spread and absorb
        mult.creatures = mult.creatures + km.spell * 0.5
        mult.defense = mult.defense + km.spell * 0.4
    end
    if km.ranged > 0.30 then
        -- Player uses ranged attacks: close the distance
        mult.offense = mult.offense + km.ranged * 0.4
        mult.creatures = mult.creatures + km.ranged * 0.3
    end
    return mult
end

-- Return the trait name for a given rival player index.
local function get_rival_trait_name(p_idx)
    if not p_idx then return nil end
    return (Game.upgrades_ai_traits or {})[p_idx]
end

-- Return the trait definition table for a given trait name.
local function get_trait_def(trait_name, is_hero)
    local list = is_hero and HERO_TRAITS or AI_TRAITS
    for _, t in ipairs(list) do
        if t.name == trait_name then return t end
    end
    return nil
end

-- ─────────────────────────────────────────────
-- Trait special ability triggers
-- ─────────────────────────────────────────────
-- Each trait has a unique trigger that fires during EconomyPulse or combat events.
-- These make traits feel distinct beyond simple stat weights.

-- Brute: All creatures get +X strength/defense scaling with heart health deficit.
-- Swarm: When creature count is low, chance to spawn bonus creatures.
-- Sniper: On first hit against a target, bonus damage.
-- Hoarder: Bonus gold income scaling with gold reserves.
-- Tactician: Bonus efficiency when outnumbered (creature count deficit).
-- Berserker: Wounded creatures get extra strength/speed (applied in OnApplyDamage).
-- Paladin (hero): On ally death, heal nearby allies.
-- Shadow (hero): On kill, steal gold from the player.
local function trigger_brute_ability(player)
    if not player or not player.heart or not player.heart.isValid or not player.heart:isValid() then return end
    local hp_pct = (player.heart.health or 1) / math.max(1, player.heart.max_health or 1)
    if hp_pct >= 0.50 then return end  -- only when heart is below 50%
    local bonus = math.floor((1.0 - hp_pct) * 2.0 * 25)  -- up to +50 at 0% heart
    if bonus <= 0 then return end
    if not GetCreatures then return end
    for _, creature in ipairs(GetCreatures() or {}) do
        local same_owner = false
        if creature and creature.owner then
            if type(creature.owner) == "number" then same_owner = (player.playerId and creature.owner == player.playerId)
            else same_owner = (creature.owner == player) or (player.playerId and creature.owner.playerId == player.playerId) end
        end
        if same_owner then
            pcall(function()
                if creature.strength then creature.strength = math.max(1, creature.strength + bonus) end
                if creature.defense then creature.defense = math.max(1, creature.defense + bonus) end
            end)
        end
    end
end

local function trigger_swarm_ability(player)
    local creature_count = 0
    if GetCreatures then
        for _, cr in ipairs(GetCreatures() or {}) do
            local same_owner = (cr.owner == player) or (player.playerId and cr.owner and cr.owner.playerId == player.playerId)
            if same_owner then creature_count = creature_count + 1 end
        end
    end
    local cap = player == PLAYER_GOOD and RIVAL_HERO_CREATURE_CAP or RIVAL_KEEPER_CREATURE_CAP
    if creature_count >= cap * 0.6 then return end  -- not desperate enough
    if math.random() < 0.15 then
        pcall(function() player:add_gold(50 + math.floor(cap * 0.5)) end)  -- bonus gold for recruitment
    end
end

local function trigger_hoarder_ability(player)
    local gold = tonumber(player.MONEY) or 0
    if gold < 2000 then return end
    local bonus = math.floor(gold * 0.02)  -- 2% of gold as bonus income
    if bonus > 0 then
        local p_idx = player_to_idx(player)
        if p_idx then Upgrades.add_ai_upgrade_gold(p_idx, bonus) end
    end
end

local function trigger_tactician_ability(player)
    if not GetCreatures then return end
    local my_count, player_count = 0, 0
    for _, cr in ipairs(GetCreatures() or {}) do
        local is_mine = (cr.owner == player) or (player.playerId and cr.owner and cr.owner.playerId == player.playerId)
        local is_player = cr.owner == PLAYER0 or (PLAYER0 and PLAYER0.playerId and cr.owner and cr.owner.playerId == PLAYER0.playerId)
        if is_mine then my_count = my_count + 1 end
        if is_player then player_count = player_count + 1 end
    end
    if my_count < player_count * 0.7 and my_count > 0 then
        -- Outnumbered: bonus to all creatures
        local outnumber_ratio = clamp(player_count / math.max(1, my_count), 1, 4)
        local bonus = math.floor(outnumber_ratio * 3)
        if bonus <= 0 then return end
        for _, cr in ipairs(GetCreatures() or {}) do
            local is_mine = (cr.owner == player) or (player.playerId and cr.owner and cr.owner.playerId == player.playerId)
            if is_mine then
                pcall(function()
                    if cr.defense then cr.defense = cr.defense + bonus end
                    if cr.loyalty then cr.loyalty = math.min(100, cr.loyalty + bonus) end
                end)
            end
        end
    end
end

local function trigger_despot_ability(player)
    if not GetCreatures then return end
    if math.random() > 0.15 then return end -- run occasionally
    local lowest_cr, lowest_lvl = nil, 11
    for _, cr in ipairs(GetCreatures() or {}) do
        local same_owner = (cr.owner == player) or (player.playerId and cr.owner and cr.owner.playerId == player.playerId)
        if same_owner and cr.level and cr.level < lowest_lvl then
            lowest_lvl = cr.level
            lowest_cr = cr
        end
    end
    if lowest_cr and lowest_lvl < 10 then
        pcall(function()
            if lowest_cr.isValid and lowest_cr:isValid() then
                lowest_cr:level_up(1)
            end
        end)
    end
end

-- Trigger the appropriate trait ability for an AI rival player.
local function trigger_rival_trait_ability(player)
    if not player then return end
    local p_idx = player_to_idx(player)
    if not p_idx then return end
    local trait_name = get_rival_trait_name(p_idx)
    if not trait_name then return end
    if trait_name == "Brute" then trigger_brute_ability(player) end
    if trait_name == "Swarm" then trigger_swarm_ability(player) end
    if trait_name == "Hoarder" then trigger_hoarder_ability(player) end
    if trait_name == "Tactician" then trigger_tactician_ability(player) end
    if trait_name == "Despot" then trigger_despot_ability(player) end
    -- Berserker is handled in OnApplyDamage (per-creature wounded bonus)
    -- Sniper is handled in OnShotHit (bonus ranged damage)
    -- Paladin/Shadow handled in OnCreatureDeath
end

function Upgrades.get_dynamic_roi_weight(id)
    local w = ROI_WEIGHTS[id]
    if not w then return 0 end
    
    local u = Upgrades._by_id[id]
    if not u then return w end

    local mult = Upgrades.ppo_weights and Upgrades.ppo_weights[u.tab] or 1.0
    local profile = Upgrades.automation_profile or "balanced"
    local turn = PLAYER0 and PLAYER0.GAME_TURN or 0

    if profile == "auto" or Upgrades.buymax_auto_enabled then
        mult = mult * adaptive_roi_multiplier(id, u.tab)
    end

    if profile == "auto" then
        profile = "balanced"
    end

    if profile == "turtle" then
        if u.tab == 1 or u.tab == 5 then mult = mult * 1.5 end
        if u.tab == 2 then mult = mult * 0.7 end
    elseif profile == "aggro" then
        if u.tab == 2 or u.tab == 4 then mult = mult * 1.5 end
        if u.tab == 1 then mult = mult * 0.7 end
    end

    -- Predictive AI ROI (decay happens in Upgrades_InflationDecay, not here)
    -- This only reads the score, sets no state, so it doesn't corrupt on repeated calls.
    local mortality = Upgrades._mortality_score or 0
    if mortality > 10 then
        if u.tab == 2 or u.tab == 5 then mult = mult * 1.5 end
    elseif mortality == 0 then
        if u.tab == 1 then mult = mult * 1.3 end
    end
    
    -- Synergy Anticipation: Juggernaut (40) needs Battle Fury (7) and Iron Skin (10) at Rank 50
    if id == 7 or id == 10 then
        local rank = Upgrades.get_rank(id)
        if rank >= 30 and rank < 50 then
            -- Gradually boost ROI as it gets closer to 50 to ensure it crosses the finish line
            mult = mult * (1.0 + ((rank - 30) / 20) * 0.35)
        end
    end

    -- Creature limit / Command capacity awareness
    -- Stop buying these upgrades if we've already hit the hard cap of 30.
    if id == 13 or id == 14 or id == 16 or id == 28 or id == 35 then
        if command_capacity_value() >= 30 then
            return 0
        end
    end

    return w * mult
end

-- Returns the ROI score for buying the next rank of upgrade `id`.
-- Higher is better.  Returns 0 if the upgrade doesn't exist.
-- FIX: Now accounts for inflation in the cost divisor so ROI matches actual purchase price.
function Upgrades.roi(id)
    local w = Upgrades.get_dynamic_roi_weight(id)
    if not w or w == 0 then return 0 end
    local rank = math.max(0, tonumber(Upgrades.get_rank(id)) or 0)
    local scale = effective_scale_at_rank(id, rank)
    -- Avoid overflow for absurdly high ranks; at that point ROI is effectively 0.
    local log_divisor = rank * math.log(scale)
    if log_divisor > 700 then return 0 end
    return w / math.exp(log_divisor)
end

-- Picks the optimal upgrade, intelligently saving up for high-ROI options.
-- Returns id or nil if nothing is affordable or if saving is optimal.
local function best_affordable_upgrade(gold)
    local best_id, best_roi = nil, -1
    local best_target_id, best_target_score = nil, -1

    for _, u in ipairs(UPGRADES) do
        if is_upgrade_unlocked(u) then
            local c = Upgrades.cost(u.id)
            local roi = Upgrades.roi(u.id)
            local min_roi = Upgrades.buymax_auto_min_roi or 0

            if roi > min_roi then
                if c <= gold then
                    if roi > best_roi then
                        best_roi = roi
                        best_id  = u.id
                    end
                end

                -- Intelligent saving: consider unaffordable upgrades if their ROI is massive.
                local score = roi
                if c > gold then
                    -- Penalize unaffordable options based on distance to cost.
                    -- An exponent of 0.85 means a 2x cost upgrade needs ~1.8x the ROI to be targeted.
                    local ratio = math.max(1, gold) / c
                    score = roi * (ratio ^ 0.85)
                end

                if score > best_target_score then
                    best_target_score = score
                    best_target_id = u.id
                end
            end
        end
    end

    -- If the absolute best strategic target is currently unaffordable, we should save up!
    if best_target_id and Upgrades.cost(best_target_id) > gold then
        Upgrades._saving_for_id = best_target_id
        return nil
    end

    Upgrades._saving_for_id = nil
    return best_id
end

-- best_efficient_affordable_upgrade was unused; removed.

function Upgrades.buy_one_efficient()
    local gold = upgrade_gold()
    local id = best_affordable_upgrade(gold)
    local roi = id and Upgrades.roi(id) or 0
    if not id then return nil, 0, 0 end

    local u = Upgrades._by_id[id]
    if not u then return nil, 0, roi or 0 end

    local cost = Upgrades.cost(id)
    if cost > gold then return nil, 0, roi or 0 end

    deduct_upgrade_gold(cost)
    local new_rank = Upgrades.get_rank(id) + 1
    Upgrades.set_rank(id, new_rank)
    Upgrades.save()

    if type(u.apply) == "function" then
        safe_call(u.apply, new_rank)
    end
    Upgrades.apply_gameplay_effects()

    return id, cost, roi
end

-- Alias is now the function itself, not a separate variable that shadows it.
auto_buy_visible_delta = nil -- will be assigned after AUTO_BUY_EFFECTS

function Upgrades.buy_max_one_upgrade(selected_id, min_visible_delta)
    local gold = upgrade_gold()
    local id = selected_id or best_affordable_upgrade(gold)
    local roi = id and Upgrades.roi(id) or 0
    if not id then return nil, 0, 0, roi end

    local u = Upgrades._by_id[id]
    if not u or not is_upgrade_unlocked(u) then return nil, 0, 0, roi end
    if Upgrades.cost(id) > gold then return nil, 0, 0, roi end

    local spent = 0
    local bought = 0
    local iterations = 0
    local MAX_ITER = MAX_BULK_BUY_RANKS
    local simulated_rank = Upgrades.get_rank(id)
    -- Simulate per-rank inflation as well as rank growth, so bulk-buy pricing
    -- matches repeated single purchases instead of undercharging high stacks.
    local simulated_inflation = math.max(0, tonumber(Upgrades.inflation and Upgrades.inflation[id]) or 0)
    local base_cost = tonumber(u.base) or 50

    while iterations < MAX_ITER do
        iterations = iterations + 1
        local current_rank = simulated_rank + bought
        local effective_scale = math.max(1.01, (tonumber(Upgrades.price_scale) or 1.15) * (1.0 + simulated_inflation))
        local cost = safe_upgrade_cost(base_cost, effective_scale, current_rank)
        if cost > (gold - spent) then break end
        if min_visible_delta and auto_buy_visible_delta and auto_buy_visible_delta(id) < min_visible_delta then break end

        spent = spent + cost
        bought = bought + 1
        simulated_inflation = simulated_inflation + 0.0010

        -- Do not apply during simulation; commit once after ranks/currency are updated.
    end

    if bought > 0 then
        local new_rank = simulated_rank + bought
        Upgrades.set_rank(id, new_rank)
        deduct_upgrade_gold(spent)
        safe_call(u.apply, new_rank)
        Upgrades.apply_gameplay_effects()
        Upgrades.save()
    end

    return id, spent, bought, roi
end

-- Toggle Auto Buy Max from chat commands.
function Upgrades.toggle_buymax_auto(enabled)
    Upgrades.buymax_auto_enabled = enabled ~= false
    pcall(QuickMessage, "Auto Buy Max: " .. (Upgrades.buymax_auto_enabled and "ON" or "OFF"), "QUERY")
    return Upgrades.buymax_auto_enabled
end

local function format_signed_amount(amount, suffix)
    suffix = suffix or ""
    if type(amount) ~= "number" then return tostring(amount) .. suffix end
    local formatted = format_gold(math.abs(amount))
    if amount > 0 then
        return "+" .. formatted .. suffix
    elseif amount < 0 then
        return "-" .. formatted .. suffix
    end
    return "0" .. suffix
end

local UPGRADE_EFFECT_LABELS = {
    [2]  = "In-match gold tribute",
    [3]  = "Creature loyalty",
    [6]  = "Training cost reduction",
    [7]  = "Creature strength",
    [8]  = "Creature dexterity",
    [9]  = "Spell damage",
    [10] = "Creature HP increase",
    [11] = "Creature defense",
    [12] = "Living creature HP scaling",
    [13] = "Hand command capacity",
    [14] = "Hand command capacity",
    [15] = "Creature loyalty and HP",
    [16] = "Hand command capacity",
    [17] = "Creature strength and defense",
    [18] = "Scavenging cost reduction",
    [19] = "Spell range",
    [21] = "Spell cost reduction",
    [22] = "Research efficiency",
    [23] = "Workshop efficiency",
    [24] = "Training room efficiency",
    [26] = "Door health",
    [27] = "Scavenger room efficiency",
    [28] = "Hand command capacity",
    [31] = "In-match gold tribute",
    [33] = "Spell damage",
    [34] = "Research efficiency",
    [35] = "Hand command capacity",
    [36] = "Door health",
    [37] = "Offline Gold gain",
    [38] = "Offline Gold gain",
    [40] = "Massive strength and defense",
    [41] = "Offline training speed",
    [42] = "Mana-to-offline-gold synergy",
    [43] = "Blood magic spell casting",
    [44] = "Treasury storage capacity",
    [45] = "Trap reliability",
    [46] = "Door self-repair",
    [47] = "Kill bounty rewards",
    [48] = "Comeback death refunds",
    [49] = "Level-up momentum rewards",
    [50] = "Rival contract intensity",
}

local AUTO_BUY_EFFECTS = {
    [2]  = function() return tribute_pulse_amount() - math.max(0, previous_combined_scaled_effect({ {2, 10}, {31, 18} }, 2)), tribute_pulse_amount(), "Tribute pulse", "g" end,
    [3]  = function() return scaled_effect(3, 2) - scaled_effect_at_rank(3, 2, -1), scaled_effect(3, 2), "Creature loyalty" end,
    [6]  = function()
        -- Use base=100 to match apply_creature_configuration and show_status
        local previous = scaled_reduction_value_at_rank(100, 6, 0.96, -1)
        local total = scaled_reduction_value(100, 6, 0.96)
        return total - previous, total, "Training cost scaling"
    end,
    [7]  = function() return scaled_effect(7, 2) - scaled_effect_at_rank(7, 2, -1), scaled_effect(7, 2), "Creature strength" end,
    [8]  = function() return scaled_effect(8, 2) - scaled_effect_at_rank(8, 2, -1), scaled_effect(8, 2), "Creature dexterity" end,
    [9]  = function() return combined_scaled_effect({ {9, 2}, {33, 1} }) - previous_combined_scaled_effect({ {9, 2}, {33, 1} }, 9), combined_scaled_effect({ {9, 2}, {33, 1} }), "Spell damage" end,
    [10] = function() return scaled_effect(10, 2) - scaled_effect_at_rank(10, 2, -1), scaled_effect(10, 2), "Creature health" end,
    [11] = function() return scaled_effect(11, 2) - scaled_effect_at_rank(11, 2, -1), scaled_effect(11, 2), "Creature defense" end,
    [12] = function() return scaled_effect(12, 3) - scaled_effect_at_rank(12, 3, -1), scaled_effect(12, 3), "Living creature HP scaling" end,
    [13] = function() return command_capacity_value() - command_capacity_value_at_rank(13, -1), command_capacity_value(), "Hand command capacity" end,
    [14] = function() return command_capacity_value() - command_capacity_value_at_rank(14, -1), command_capacity_value(), "Hand command capacity" end,
    [15] = function() return rally_loyalty_bonus() - scaled_effect_at_rank(15, 1, -1), rally_loyalty_bonus(), "Rally loyalty and HP scaling" end,
    [16] = function() return command_capacity_value() - command_capacity_value_at_rank(16, -1), command_capacity_value(), "Hand command capacity" end,
    [17] = function() return veteran_drill_bonus() - scaled_effect_at_rank(17, 1, -1), veteran_drill_bonus(), "Veteran strength and defense" end,
    [18] = function()
        -- Use base=100 to match apply_creature_configuration and show_status
        local previous = scaled_reduction_value_at_rank(100, 18, 0.96, -1)
        local total = scaled_reduction_value(100, 18, 0.96)
        return total - previous, total, "Scavenging cost scaling"
    end,
    [19] = function() return scaled_effect(19, 2) - scaled_effect_at_rank(19, 2, -1), scaled_effect(19, 2), "Spell range" end,
    [21] = function()
        -- Use base=100 to match apply_creature_configuration and show_status.
        local previous = scaled_reduction_value_at_rank(100, 21, 0.96, -1)
        local total = scaled_reduction_value(100, 21, 0.96)
        return total - previous, total, "Spell pay scaling"
    end,
    [22] = function() return research_efficiency_bonus() - previous_combined_scaled_effect({ {22, 2}, {34, 2} }, 22), 100 + research_efficiency_bonus(), "Research efficiency" end,
    [23] = function() return workshop_efficiency_bonus() - scaled_effect_at_rank(23, 2, -1), 100 + workshop_efficiency_bonus(), "Workshop efficiency" end,
    [24] = function() return training_efficiency_bonus() - scaled_effect_at_rank(24, 2, -1), 100 + training_efficiency_bonus(), "Training room efficiency" end,
    [26] = function()
        local previous = door_health_value_at_rank(26, -1)
        local total = door_health_value()
        return total - previous, total, "Door health"
    end,
    [27] = function() return scavenger_efficiency_bonus() - scaled_effect_at_rank(27, 2, -1), 100 + scavenger_efficiency_bonus(), "Scavenger room efficiency" end,
    [28] = function() return command_capacity_value() - command_capacity_value_at_rank(28, -1), command_capacity_value(), "Hand command capacity" end,
    [31] = function() return tribute_pulse_amount() - math.max(0, previous_combined_scaled_effect({ {2, 10}, {31, 18} }, 31)), tribute_pulse_amount(), "Tribute pulse", "g" end,
    [33] = function() return combined_scaled_effect({ {9, 2}, {33, 1} }) - previous_combined_scaled_effect({ {9, 2}, {33, 1} }, 33), combined_scaled_effect({ {9, 2}, {33, 1} }), "Spell damage" end,
    [34] = function() return research_efficiency_bonus() - previous_combined_scaled_effect({ {22, 2}, {34, 2} }, 34), 100 + research_efficiency_bonus(), "Research efficiency" end,
    [35] = function() return command_capacity_value() - command_capacity_value_at_rank(35, -1), command_capacity_value(), "Hand command capacity" end,
    [36] = function()
        local previous = door_health_value_at_rank(36, -1)
        local total = door_health_value()
        return total - previous, total, "Door health"
    end,
    [37] = function()
        local previous = math.floor((Upgrades.effective_rank(math.max(0, Upgrades.get_rank(37) - 1)) * 5) + 0.5)
        local total = math.floor((Upgrades.effective_owned_rank(37) * 5) + 0.5)
        return total - previous, total, "Offline income and tithe scaling"
    end,
    [38] = function()
        local previous = Upgrades.effective_rank(math.max(0, Upgrades.get_rank(38) - 1))
        local total = Upgrades.offline_income_flat_bonus()
        return total - previous, total, "Offline base and match interest", "g/s"
    end,
    [47] = function()
        local prev = math.min(120, math.floor(tuned_rank(math.max(0, Upgrades.get_rank(47) - 1), ECONOMY_POWER) * 3 + 0.5))
        local total = bounty_board_bonus()
        return total - prev, total, "Kill bounty bonus", "%"
    end,
    [48] = function()
        local prev = math.min(150, math.floor(tuned_rank(math.max(0, Upgrades.get_rank(48) - 1), ECONOMY_POWER) * 4 + 0.5))
        local total = comeback_pact_refund()
        return total - prev, total, "Death refund", "g"
    end,
    [49] = function()
        local prev = math.min(120, math.floor(tuned_rank(math.max(0, Upgrades.get_rank(49) - 1), ECONOMY_POWER) * 3 + 0.5))
        local total = momentum_drill_reward()
        return total - prev, total, "Level-up reward", "g"
    end,
    [50] = function()
        local total = math.floor(rival_contract_bonus() * 100 + 0.5)
        return total, total, "Rival contract intensity", "%"
    end,
}

-- Assign auto_buy_visible_delta after AUTO_BUY_EFFECTS is defined,
-- fixing the local-vs-global shadowing bug.
auto_buy_visible_delta = function(id)
    local effect = AUTO_BUY_EFFECTS[id]
    if not effect then return 0 end

    local ok, delta = pcall(effect)
    if not ok or type(delta) ~= "number" then return 0 end
    return math.abs(delta)
end

local function format_auto_buy_effect(id)
    local effect = AUTO_BUY_EFFECTS[id]
    if not effect then
        return (UPGRADE_EFFECT_LABELS[id] or "Upgrade effect") .. " Rank " .. Upgrades.get_rank(id)
    end

    local ok, delta, total, label, suffix = pcall(effect)
    if not ok then
        return (UPGRADE_EFFECT_LABELS[id] or "Upgrade effect") .. " Rank " .. Upgrades.get_rank(id)
    end
    suffix = suffix or ""
    return format_signed_amount(delta, suffix) .. " " .. label
end

local function upgrade_effect_label(id)
    id = tonumber(id)
    local label = UPGRADE_EFFECT_LABELS[id]
    if label then return label end
    local effect = AUTO_BUY_EFFECTS[id]
    if effect then
        local ok, delta, total, dynamic_label = pcall(effect)
        if ok and dynamic_label then return tostring(dynamic_label) end
    end
    return "Upgrade effect"
end

local function upgrade_display_name(u_or_id)
    local id = type(u_or_id) == "table" and u_or_id.id or u_or_id
    return upgrade_effect_label(id)
end

local function record_creature_base(creature)
    if not creature or not creature.ThingIndex then return nil end
    Upgrades._creature_base_stats = Upgrades._creature_base_stats or {}
    local key = creature.ThingIndex
    local base = Upgrades._creature_base_stats[key]
    if not base then
        base = {}
        for _, field in ipairs({
            "max_health", "max_speed", "strength", "dexterity", "defense",
            "spell_damage", "range", "job_value", "loyalty", "pay",
            "training_cost", "scavenging_cost"
        }) do
            local ok, value = pcall(function() return tonumber(creature[field]) end)
            if ok and value and value > 0 then base[field] = value end
        end
        Upgrades._creature_base_stats[key] = base
    end
    return base
end

is_player_creature = function(creature)
    if not creature or not creature.isValid or not creature:isValid() then return false end
    if not PLAYER0 then return false end
    if type(creature.owner) == "number" then return PLAYER0.playerId and creature.owner == PLAYER0.playerId end
    return creature.owner == PLAYER0 or (PLAYER0.playerId and creature.owner.playerId == PLAYER0.playerId)
end

local function is_owned_by_player0(thing)
    if not thing or not PLAYER0 then return false end
    if thing.owner == PLAYER0 then return true end
    if type(thing.owner) == "number" then
        return PLAYER0.playerId and thing.owner == PLAYER0.playerId
    end
    return thing.owner and PLAYER0.playerId and thing.owner.playerId == PLAYER0.playerId
end

local function is_player_room(room)
    if not room or not PLAYER0 then return false end
    return is_owned_by_player0(room)
end

local function room_type_key(room)
    return tostring(room and room.type or ""):upper()
end

local function is_room_type(room, ...)
    local key = room_type_key(room)
    for _, name in ipairs({...}) do
        local wanted = tostring(name):upper()
        if key == wanted or key:find(wanted, 1, true) then return true end
    end
    return false
end

local function record_room_base(room)
    if not room or not room.room_idx then return nil end
    Upgrades._room_base_stats = Upgrades._room_base_stats or {}
    local key = room.room_idx
    local base = Upgrades._room_base_stats[key]
    if not base then
        base = {}
        for _, field in ipairs({ "max_capacity", "max_health", "efficiency" }) do
            local ok, value = pcall(function() return tonumber(room[field]) end)
            if ok and value and value > 0 then base[field] = value end
        end
        Upgrades._room_base_stats[key] = base
    end
    return base
end

-- Room health bonus: placeholder for future upgrades that boost room HP directly.
-- Currently all room health increases come from the room's base stat + upgrade config.
local function room_health_bonus(room)
    return 0
end

local function room_efficiency_bonus(room)
    if is_room_type(room, "RESEARCH", "RSRCH") then
        return research_efficiency_bonus()
    elseif is_room_type(room, "WORKSHOP", "WRKSH") then
        return workshop_efficiency_bonus()
    elseif is_room_type(room, "TRAINING", "TRAIN") then
        return training_efficiency_bonus()
    elseif is_room_type(room, "SCAVENGER", "SCAVN") then
        return scavenger_efficiency_bonus()
    end
    return 0
end

local function apply_upgrade_room_stats()
    if not GetRoomsOfPlayerAndType or not PLAYER0 then return end

    for _, room in ipairs(GetRoomsOfPlayerAndType(PLAYER0, "ANY_ROOM") or {}) do
        safe_call(function()
            if not is_player_room(room) then return end
            local base = record_room_base(room)
            if not base then return end

            if base.max_health then
                local old_max = tonumber(room.max_health) or base.max_health
                local new_max = math.max(1, base.max_health + room_health_bonus(room))
                if room.health then
                    if new_max > old_max then
                        room.health = math.min(new_max, (tonumber(room.health) or new_max) + (new_max - old_max))
                    else
                        room.health = math.min(tonumber(room.health) or new_max, new_max)
                    end
                end
            end

        end)
    end
end

local function apply_creature_configuration()
    local set_creature_config = Set_creature_configuration or SetCreatureConfiguration or SetCreatureConfig
    if not set_creature_config then return end

    local jug_bonus = juggernaut_bonus()
    local strength_bonus = scaled_effect(7, 2) + veteran_drill_bonus() + jug_bonus
    local dexterity_bonus = scaled_effect(8, 2)
    local defense_bonus = scaled_effect(11, 2) + veteran_drill_bonus() + jug_bonus
    local health_flat = scaled_effect(10, 2) + scaled_effect(12, 3) + rally_hp_bonus()
    local training_cost_reduction = math.max(0, 100 - scaled_reduction_value(100, 6, 0.96))
    local pay_reduction = math.max(0, 100 - scaled_reduction_value(100, 21, 0.96))

    for _, creature_type in ipairs(all_creature_types()) do
        local base = base_creature_config(creature_type)
        if base then
            if base.Health then
                set_config_field(set_creature_config, creature_type, "Health", math.max(1, base.Health + health_flat))
            end
            if base.Strength then
                set_config_field(set_creature_config, creature_type, "Strength", math.max(1, base.Strength + strength_bonus))
            end
            if base.Dexterity then
                set_config_field(set_creature_config, creature_type, "Dexterity", math.max(1, base.Dexterity + dexterity_bonus))
            end
            if base.Defence then
                set_config_field(set_creature_config, creature_type, "Defence", math.max(1, base.Defence + defense_bonus))
            end
            if base.TrainingCost then
                set_config_field(set_creature_config, creature_type, "TrainingCost", math.max(1, base.TrainingCost - training_cost_reduction))
            end
            if base.Pay and base.Pay > 0 then
                set_config_field(set_creature_config, creature_type, "Pay", math.max(1, base.Pay - pay_reduction))
            end
        end
    end
end

local function apply_upgrade_creature_stats()
    if not GetCreatures then return end

    -- These bonuses are already applied globally via apply_creature_configuration()
    -- (sets type-wide Strength, Dexterity, Defence, Health, TrainingCost, Pay).
    -- Here we only apply bonuses for FIELDS NOT handled by the type config:
    -- spell_damage, range, loyalty. This avoids doubling up on config-settable stats.
    local spell_damage_bonus = combined_scaled_effect({ {9, 2}, {33, 1} })
    local range_bonus = scaled_effect(19, 2)
    local loyalty_bonus = scaled_effect(3, 2) + rally_loyalty_bonus()

    for _, creature in ipairs(GetCreatures() or {}) do
        safe_call(function()
            if not is_player_creature(creature) then return end
            
            -- Only apply the delta of the buff to preserve level-ups and engine math!
            Upgrades._creature_applied_bonuses = Upgrades._creature_applied_bonuses or {}
            local key = creature.ThingIndex
            if not key then return end
            local applied = Upgrades._creature_applied_bonuses[key] or {}

            -- Apply instant deltas for non-config-settable stats only
            local function apply_delta(field_name, current_bonus)
                local delta = current_bonus - (applied[field_name] or 0)
                if delta ~= 0 then
                    local current_val = tonumber(get_live_field(creature, field_name))
                    if current_val then
                        set_live_field(creature, field_name, math.max(1, current_val + delta))
                    end
                    applied[field_name] = current_bonus
                end
            end

            apply_delta("spell_damage", spell_damage_bonus)
            apply_delta("range", range_bonus)
            apply_delta("loyalty", loyalty_bonus)
            
            Upgrades._creature_applied_bonuses[key] = applied
        end)
    end
end

function Upgrades.garbage_collect_creatures()
    if not Upgrades._creature_applied_bonuses or not GetCreatures then return end
    local alive = {}
    for _, creature in ipairs(GetCreatures() or {}) do
        if creature.ThingIndex then alive[creature.ThingIndex] = true end
    end
    local dead_keys = {}
    for key, _ in pairs(Upgrades._creature_applied_bonuses) do
        if not alive[key] then dead_keys[#dead_keys+1] = key end
    end
    for _, key in ipairs(dead_keys) do
        Upgrades._creature_applied_bonuses[key] = nil
    end

    if Upgrades._rival_applied_health_bonus then
        local dead_rivals = {}
        for key, _ in pairs(Upgrades._rival_applied_health_bonus) do
            if not alive[key] then dead_rivals[#dead_rivals+1] = key end
        end
        for _, key in ipairs(dead_rivals) do
            Upgrades._rival_applied_health_bonus[key] = nil
        end
    end

    if Upgrades._archon_buffed then
        local dead_archons = {}
        for key, _ in pairs(Upgrades._archon_buffed) do
            if not alive[key] then dead_archons[#dead_archons+1] = key end
        end
        for _, key in ipairs(dead_archons) do
            Upgrades._archon_buffed[key] = nil
        end
    end
end

local function set_rule(name, value)
    if SetGameRule then safe_call(SetGameRule, name, value) end
end

local VALID_ROOM_PROPERTIES = {
    Health = true,
    StorageHeight = true,
}

local function set_room(room, property, value)
    if not SetRoomConfiguration then return end
    if not VALID_ROOM_PROPERTIES[property] then return end
    safe_call(SetRoomConfiguration, room, property, value)
end

local function set_door(door, property, value)
    if SetDoorConfiguration then safe_call(SetDoorConfiguration, door, property, value) end
end

local DOOR_BASE_HEALTH = {
    WOOD = 400,
    BRACED = 1000,
    STEEL = 2500,
}

local function active_world_modifier_value(id)
    if not Game or not Game.world_modifiers then return nil end
    for _, mod in ipairs(Game.world_modifiers) do
        if mod.id == id then return mod.value or true end
    end
    return nil
end

function Upgrades.apply_gameplay_effects()
    local spell_damage_bonus = combined_scaled_effect({ {9, 2}, {33, 1} })
    local spell_range_bonus = scaled_effect(19, 2)

    local gold_pile_val = 200
    if active_world_modifier_value(36) then gold_pile_val = 400 end

    local gold_per_hoard = 3000
    if active_world_modifier_value(37) then gold_per_hoard = 6000 end

    local train_eff = 256 + training_efficiency_bonus()
    local fast_learn = active_world_modifier_value(13)
    local slow_learn = active_world_modifier_value(14)
    local eff_train = active_world_modifier_value(19)
    if eff_train then
        train_eff = train_eff * 2
    elseif fast_learn then
        train_eff = train_eff + math.floor(train_eff * (fast_learn / 100))
    elseif slow_learn then
        train_eff = math.max(30, train_eff - math.floor(train_eff * (slow_learn / 100)))
    end

    local work_eff = 256 + workshop_efficiency_bonus()
    if active_world_modifier_value(21) then work_eff = work_eff * 2 end

    local research_eff = 256 + research_efficiency_bonus()
    if active_world_modifier_value(20) then research_eff = research_eff * 2 end

    local scav_eff = 256 + scavenger_efficiency_bonus()
    local fast_scav = active_world_modifier_value(22)
    local scav_mast = active_world_modifier_value(42)
    if scav_mast then
        scav_eff = scav_eff * 3
    elseif fast_scav then
        scav_eff = scav_eff * 2
    end

    local room_sell = 50
    local cheap_rooms = active_world_modifier_value(18)
    if cheap_rooms then room_sell = cheap_rooms end

    -- Re-check procedural synergy each application so it cleans up when conditions no longer met
    Upgrades.check_procedural_synergy()
    if Upgrades.procedural_synergy_tabs then
        local t1, t2 = Upgrades.procedural_synergy_tabs[1], Upgrades.procedural_synergy_tabs[2]
        if t1 == 1 or t2 == 1 then gold_pile_val = math.floor(gold_pile_val * 1.5) end
        if t1 == 2 or t2 == 2 then 
            if SetIncreaseOnExperience then 
                safe_call(SetIncreaseOnExperience, "StrengthIncreaseOnExp", scaled_effect(7, 2) + 10) 
                safe_call(SetIncreaseOnExperience, "DefenseIncreaseOnExp", scaled_effect(11, 2) + 10) 
            end
        end
        if t1 == 4 or t2 == 4 then
            research_eff = research_eff + 50
        end
    end

    set_rule("GoldPileValue", gold_pile_val)
    set_rule("BagGoldHold", 100)
    set_rule("GoldPerHoard", gold_per_hoard)
    set_rule("PotOfGoldHolds", 250)
    set_rule("ChestGoldHold", 500)
    set_rule("TrainEfficiency", train_eff)
    set_rule("WorkEfficiency", work_eff)
    set_rule("ResearchEfficiency", research_eff)
    set_rule("ScavengeEfficiency", scav_eff)
    set_rule("TortureTrainingCost", scaled_reduction_value(100, 6, 0.96))
    set_rule("TortureScavengingCost", scaled_reduction_value(100, 18, 0.96))
    set_rule("PayDaySpeed", 100 + math.min(200, scaled_effect(3, 2) + rally_loyalty_bonus()))
    set_rule("RoomSellGoldBackPercent", room_sell)
    set_rule("HeroDoorWaitTime", 200 + door_health_value())
    set_rule("MaxThingsInHand", command_capacity_value())

    set_room("TREASURE", "StorageHeight", 1 + math.floor(Upgrades.get_rank(44) or 0))
    set_room("TREASURE", "Health", 100)
    set_room("LAIR", "Health", 4000)
    set_room("RESEARCH", "Health", 320)
    set_room("WORKSHOP", "Health", 900)
    set_room("TRAINING", "Health", 1000)
    set_room("SCAVENGER", "Health", 350)

    for door, base_health in pairs(DOOR_BASE_HEALTH) do
        set_door(door, "Health", math.max(1, base_health + door_health_value() - 300))
    end

    if SetIncreaseOnExperience then
        safe_call(SetIncreaseOnExperience, "SpellDamageIncreaseOnExp", spell_damage_bonus)
        safe_call(SetIncreaseOnExperience, "RangeIncreaseOnExp", spell_range_bonus)
        safe_call(SetIncreaseOnExperience, "TrainingCostIncreaseOnExp", scaled_reduction_value(100, 6, 0.96))
        safe_call(SetIncreaseOnExperience, "ScavengingCostIncreaseOnExp", scaled_reduction_value(100, 18, 0.96))
        safe_call(SetIncreaseOnExperience, "PayIncreaseOnExp", scaled_reduction_value(100, 21, 0.96))
        safe_call(SetIncreaseOnExperience, "LoyaltyIncreaseOnExp", scaled_effect(3, 2))
        safe_call(SetIncreaseOnExperience, "StrengthIncreaseOnExp", scaled_effect(7, 2))
        safe_call(SetIncreaseOnExperience, "DexterityIncreaseOnExp", scaled_effect(8, 2))
        safe_call(SetIncreaseOnExperience, "DefenseIncreaseOnExp", scaled_effect(11, 2))
        safe_call(SetIncreaseOnExperience, "HealthIncreaseOnExp", scaled_effect(10, 2) + scaled_effect(12, 3))
    end

    enforce_player_creature_cap()
    apply_creature_configuration()
    -- apply_upgrade_room_stats() disabled: room_health_bonus always returns 0, so this is pure overhead.
    -- If a future upgrade adds room HP scaling, re-enable this call.
    -- apply_upgrade_room_stats()
    apply_upgrade_creature_stats()
end

local function snapshot_auto_buy_totals()
    local totals = {}
    for id, effect in pairs(AUTO_BUY_EFFECTS) do
        local ok, _, total, label, suffix = pcall(effect)
        if ok and label and type(total) == "number" then
            suffix = suffix or ""
            totals[label .. "|" .. suffix] = {
                label = label,
                suffix = suffix,
                total = total,
                id = id,
            }
        end
    end
    return totals
end

-- format_auto_buy_changes was unused; removed.

-- NOTE: auto_buy_available_roi, best_visible_auto_buy_upgrade, and best_auto_buy_upgrade
-- are kept for reference; buy_max uses best_affordable_upgrade directly.
-- The function below has been fixed to properly simulate rank advancement.
local function auto_buy_available_roi(id, gold)
    if auto_buy_visible_delta and auto_buy_visible_delta(id) < 1 then return 0 end

    local initial_rank = Upgrades.get_rank(id)
    local remaining = math.max(0, tonumber(gold) or 0)
    local score = 0
    local bought = 0
    local iterations = 0
    local MAX_ITER = 2000
    local u = Upgrades._by_id[id]
    if not u then return 0 end

    local simulated_inflation = Upgrades.inflation and Upgrades.inflation[id] or 0

    while iterations < MAX_ITER do
        iterations = iterations + 1

        local sim_rank = initial_rank + bought
        local effective_scale = math.max(1.01, (tonumber(Upgrades.price_scale) or 1.15) * (1.0 + simulated_inflation))
        local cost = safe_upgrade_cost(tonumber(u.base) or 50, effective_scale, sim_rank)
        
        if cost > remaining then break end

        local w = Upgrades.get_dynamic_roi_weight(id)
        score = score + (w / (effective_scale ^ sim_rank))
        remaining = remaining - cost
        bought = bought + 1
        simulated_inflation = simulated_inflation + 0.0010
    end

    if bought == 0 then return 0 end
    return score
end

local function best_visible_auto_buy_upgrade(gold)
    local best_id, best_roi = nil, -1
    for _, u in ipairs(UPGRADES) do
        if is_upgrade_unlocked(u) then
            if Upgrades.cost(u.id) <= gold then
                local roi = auto_buy_available_roi(u.id, gold)
                if roi > 0 and roi > best_roi then
                    best_id = u.id
                    best_roi = roi
                end
            end
        end
    end
    return best_id
end

local function best_auto_buy_upgrade(gold)
    return best_visible_auto_buy_upgrade(gold) or best_affordable_upgrade(gold)
end

-- Greedy buy-max: keep purchasing the highest-ROI affordable upgrade
-- until no more can be bought.  Returns a summary table.
function Upgrades.buy_max()
    local gold      = upgrade_gold()
    local spent     = 0
    local purchases = {}   -- { [id] = count }
    local iterations = 0
    local MAX_ITER   = MAX_BULK_BUY_RANKS   -- safety cap

    while iterations < MAX_ITER do
        iterations = iterations + 1
        local id = best_affordable_upgrade(gold - spent)
        if not id then break end

        local cost = Upgrades.cost(id)
        if cost <= 0 or cost > (gold - spent) then break end
        spent = spent + cost
        purchases[id] = (purchases[id] or 0) + 1

        local new_rank = Upgrades.get_rank(id) + 1
        Upgrades.set_rank(id, new_rank)

        -- Apply effect immediately so subsequent ROI uses updated ranks
        local u = Upgrades._by_id[id]
        if type(u.apply) == "function" then
            safe_call(u.apply, new_rank)
        end
    end

    if spent > 0 then
        deduct_upgrade_gold(spent)
        Upgrades.apply_gameplay_effects()
        Upgrades.save()
        
        Upgrades.rival_roll_session_id = (Upgrades.rival_roll_session_id or 0) + 1
        if Upgrades_InitRivals then pcall(Upgrades_InitRivals) end
    end

    return purchases, spent
end

-- Builds a readable summary string from buy_max purchases table.
local function format_buymax_summary(purchases, spent)
    if spent == 0 then
        if Upgrades._saving_for_id then
            local u = Upgrades._by_id[Upgrades._saving_for_id]
            return "Buy Max: Saving up for " .. (u and upgrade_display_name(u) or "a better effect") .. " (Optimal ROI)."
        end
        return "Buy Max: not enough Upgrade Gold to purchase anything."
    end

    -- Group by tab for a compact display
    local tab_totals = {}   -- [tab_idx] = total ranks bought
    local top = {}          -- top individual purchases by count
    for id, cnt in pairs(purchases) do
        local u = Upgrades._by_id[id]
        if u then
            tab_totals[u.tab] = (tab_totals[u.tab] or 0) + cnt
            top[#top + 1] = { id = id, cnt = cnt, name = upgrade_display_name(u) }
        end
    end
    table.sort(top, function(a, b)
        if a.cnt ~= b.cnt then return a.cnt > b.cnt end
        return a.id < b.id
    end)

    local lines = { "=== BUY MAX COMPLETE ==="}
    lines[#lines+1] = "Spent: " .. format_gold(spent) .. " Upgrade Gold  |  Remaining: " .. format_gold(upgrade_gold()) .. " Upgrade Gold"
    lines[#lines+1] = ""

    -- Per-tab summary line
    for ti = 1, 6 do
        local cnt = tab_totals[ti]
        if cnt and cnt > 0 then
            lines[#lines+1] = "  [" .. ti .. "] " .. Upgrades.tab_info[ti].name .. ": +" .. cnt .. " rank(s)"
        end
    end

    lines[#lines+1] = ""
    -- Top 5 individual upgrades
    lines[#lines+1] = "Top purchases:"
    for i = 1, math.min(5, #top) do
        local entry = top[i]
        lines[#lines+1] = "  #" .. string.format("%02d", entry.id) ..
                           " " .. entry.name ..
                           " x" .. entry.cnt ..
                           "  [Rank " .. Upgrades.get_rank(entry.id) .. "]"
    end

    return table.concat(lines, "\n")
end

-- ─────────────────────────────────────────────
-- Apply all purchased upgrades
-- ─────────────────────────────────────────────

function Upgrades.apply_all()
    -- Reset upgrade gold tracking when applying upgrades on load
    Upgrades.upgrade_gold_granted = 0
    for _, u in ipairs(UPGRADES) do
        local rank = Upgrades.get_rank(u.id)
        if rank > 0 and type(u.apply) == "function" then
            safe_call(u.apply, rank)
        end
    end
    Upgrades.apply_gameplay_effects()
end

-- Returns and clears the gold granted by upgrades in this session
-- (used by OfflineProgress to integrate upgrade gold into its display)
function Upgrades.consume_upgrade_gold()
    local amount = Upgrades.upgrade_gold_granted or 0
    Upgrades.upgrade_gold_granted = 0
    return amount
end

-- ─────────────────────────────────────────────
-- UI State
-- Tracks where the player is in the menu so short contextual
-- commands work without repeating the full path each time.
-- ─────────────────────────────────────────────

Upgrades.ui_state = Upgrades.ui_state or { view = "root", tab = nil, sub = nil, last_id = nil }

-- ─────────────────────────────────────────────
-- UI helpers
-- ─────────────────────────────────────────────

local function show(msg)
    if QuickObjective then
        pcall(QuickObjective, msg, nil)
    elseif QuickMessage then
        pcall(QuickMessage, msg, "QUERY")
    end
end

local function format_upgrade_gold()
    return format_gold(upgrade_gold()) .. " Upgrade Gold"
end

-- Build a breadcrumb string for the current UI state.
local function breadcrumb()
    local s  = Upgrades.ui_state
    local ti = s.tab and Upgrades.tab_info[s.tab]
    if s.view == "tab" and ti then
        return "SHOP > " .. ti.name:upper()
    elseif s.view == "subtab" and ti then
        local sn = ti.subs[s.sub or 0] or "?"
        return "SHOP > " .. ti.name:upper() .. " > " .. sn:upper()
    elseif s.view == "info" and s.last_id then
        local u = Upgrades._by_id[s.last_id]
        return "SHOP > INFO: " .. (u and upgrade_display_name(u) or "#" .. s.last_id)
    end
    return "UPGRADES SHOP"
end

-- Show the tab list (root view).
local function show_tab_list()
    local s = Upgrades.ui_state
    s.view = "root"; s.tab = nil; s.sub = nil
    local lines = { "=== UPGRADES SHOP ===" }
    lines[#lines+1] = format_upgrade_gold()
    lines[#lines+1] = ""
    for i = 1, 6 do
        local ti = Upgrades.tab_info[i]
        local owned, total, affordable = 0, 0, false
        for _, u in ipairs(UPGRADES) do
            if u.tab == i and is_upgrade_unlocked(u) then
                total = total + 1
                if Upgrades.get_rank(u.id) > 0 then owned = owned + 1 end
                if Upgrades.cost(u.id) <= upgrade_gold() then affordable = true end
            end
        end
        local mark = affordable and " [BUY]" or ""
        lines[#lines+1] = "  [" .. i .. "] " .. ti.name .. mark ..
                           "  (" .. owned .. "/" .. total .. " unlocked)"
    end
    lines[#lines+1] = ""
    lines[#lines+1] = "  [M] Buy Max (ROI)   [S] Status"
    lines[#lines+1] = ""
    lines[#lines+1] = "Type: /u <1-6>  /u m  /u s"
    show(table.concat(lines, "\n"))
end

-- Show one tab's two sub-tabs.
local function show_tab(tab_idx)
    local ti = Upgrades.tab_info[tab_idx]
    if not ti then show("Unknown tab: " .. tostring(tab_idx)); return end
    local s = Upgrades.ui_state
    s.view = "tab"; s.tab = tab_idx
    local lines = { "=== " .. breadcrumb() .. " ===" }
    lines[#lines+1] = format_gold(upgrade_gold()) .. " Upgrade Gold"
    lines[#lines+1] = ""
    for sub_idx = 1, 2 do
        local sub_name = ti.subs[sub_idx]
        local affordable = false
        for _, u in ipairs(UPGRADES) do
            if u.tab == tab_idx and u.sub == sub_idx and is_upgrade_unlocked(u) then
                if Upgrades.cost(u.id) <= upgrade_gold() then
                    affordable = true
                end
            end
        end
        local mark = affordable and " [BUY]" or ""
        lines[#lines+1] = "  [" .. string.char(64 + sub_idx) .. "] " .. sub_name .. mark
        for _, u in ipairs(UPGRADES) do
            if u.tab == tab_idx and u.sub == sub_idx and is_upgrade_unlocked(u) then
                local rank = Upgrades.get_rank(u.id)
                local cost = Upgrades.cost(u.id)
                local upgrade_mark = (cost <= upgrade_gold()) and " [BUY]" or ""
                lines[#lines+1] = "      #" .. string.format("%02d", u.id) ..
                                   "  " .. upgrade_display_name(u) ..
                                   "  Rank " .. rank ..
                                   "  " .. format_gold(cost) .. " Upgrade Gold" .. upgrade_mark
            end
        end
        lines[#lines+1] = ""
    end
    lines[#lines+1] = "Type: /u a  /u b  /u back  /u <1-6>"
    show(table.concat(lines, "\n"))
end

-- Show one sub-tab's upgrades with full descriptions.
local function show_subtab(tab_idx, sub_idx)
    local ti = Upgrades.tab_info[tab_idx]
    if not ti then show("Unknown tab."); return end
    local sub_name = ti.subs[sub_idx]
    if not sub_name then show("Unknown sub-tab."); return end
    local s = Upgrades.ui_state
    s.view = "subtab"; s.tab = tab_idx; s.sub = sub_idx
    local lines = { "=== " .. breadcrumb() .. " ===" }
    lines[#lines+1] = format_gold(upgrade_gold()) .. " Upgrade Gold"
    lines[#lines+1] = ""
    for _, u in ipairs(UPGRADES) do
        if u.tab == tab_idx and u.sub == sub_idx and is_upgrade_unlocked(u) then
            local rank = Upgrades.get_rank(u.id)
            local cost = Upgrades.cost(u.id)
            local mark = cost <= upgrade_gold() and "  [BUY: /u " .. u.id .. "]" or "  [need " .. format_gold(math.abs(cost - upgrade_gold())) .. " Upgrade Gold]"
            lines[#lines+1] = "#" .. string.format("%02d", u.id) ..
                               "  " .. upgrade_display_name(u) ..
                               "  Rank " .. rank ..
                               "  " .. format_gold(cost) .. " Upgrade Gold" .. mark
            lines[#lines+1] = "   " .. u.desc
            lines[#lines+1] = ""
        end
    end
    lines[#lines+1] = "Type: /u <id>  /u i <id>  /u back"
    show(table.concat(lines, "\n"))
end

-- Show full details for one upgrade.
local function show_info(id)
    local u = Upgrades._by_id[id]
    if not u then show("No upgrade with id " .. tostring(id)); return end
    if not is_upgrade_unlocked(u) then show("Upgrade #" .. tostring(id) .. " is locked."); return end
    local s = Upgrades.ui_state
    if s.view ~= "subtab" or s.tab ~= u.tab or s.sub ~= u.sub then
        s.tab = u.tab; s.sub = u.sub
    end
    s.view    = "info"
    s.last_id = id
    local rank = Upgrades.get_rank(id)
    local cost = Upgrades.cost(id)
    local ti   = Upgrades.tab_info[u.tab]
    local sub_name = ti and ti.subs[u.sub] or "?"
    local can_buy  = cost <= upgrade_gold()
    local lines = {
        "=== " .. breadcrumb() .. " ===",
        "#" .. string.format("%02d", id) .. "  " .. upgrade_display_name(u),
        "Tab: " .. (ti and ti.name or "?") .. " > " .. sub_name,
        "",
        u.desc,
        "",
        "Current Rank: " .. rank,
        "Effective Rank: " .. string.format("%.2f", Upgrades.effective_rank(rank)),
        "Next Cost: " .. format_gold(cost) .. " Upgrade Gold",
        "You have:  " .. format_gold(upgrade_gold()) .. " Upgrade Gold",
    }
    if can_buy then
        lines[#lines+1] = ""
        lines[#lines+1] = "[BUY]  You can afford this!  Type: /u buy"
    else
        lines[#lines+1] = "  Need " .. format_gold(cost - upgrade_gold()) .. " Upgrade Gold."
    end
    lines[#lines+1] = "  Type: /u back to return"
    show(table.concat(lines, "\n"))
end

-- Purchase one rank and re-render the current view.
local function do_buy(id)
    local u = Upgrades._by_id[id]
    if not u then
        pcall(QuickMessage, "No upgrade #" .. tostring(id), "QUERY"); return
    end
    if not is_upgrade_unlocked(u) then
        pcall(QuickMessage, "Upgrade #" .. tostring(id) .. " is locked.", "QUERY"); return
    end
    local cost = Upgrades.cost(id)
    local gold = upgrade_gold()
    if gold < cost then
        pcall(QuickMessage, "Need " .. format_gold(cost) .. " Upgrade Gold, have " .. format_gold(gold), "QUERY")
        return
    end
    deduct_upgrade_gold(cost)
    local new_rank = Upgrades.get_rank(id) + 1
    Upgrades.set_rank(id, new_rank)
    Upgrades.save()
    safe_call(u.apply, new_rank)
    Upgrades.apply_gameplay_effects()
    Upgrades.ui_state.last_id = id
    pcall(QuickMessage,
        "[BOUGHT] " .. upgrade_display_name(u) .. " Rank " .. new_rank ..
        "  |  Next: " .. format_gold(Upgrades.cost(id)) .. " Upgrade Gold" ..
        "  |  You have: " .. format_gold(upgrade_gold()) .. " Upgrade Gold",
        "QUERY")
    local s = Upgrades.ui_state
    if s.view == "subtab" and s.tab and s.sub then
        show_subtab(s.tab, s.sub)
    elseif s.view == "info" then
        show_info(id)
    end
end

-- Show all purchased upgrades in a compact overview.
local function show_status()
    local lines = { "=== ACTIVE UPGRADE EFFECTS ===" }
    lines[#lines+1] = format_gold(upgrade_gold()) .. " Upgrade Gold"
    lines[#lines+1] = "Auto Profile: " .. (Upgrades.automation_profile or "balanced"):upper() ..
                       " (" .. adaptive_focus_label() .. ")"
    lines[#lines+1] = "Ranks use diminishing returns."
    lines[#lines+1] = "Rival AI Base Score: " .. math.floor(Upgrades.compute_strength_score() + 0.5)
    lines[#lines+1] = ""

    local effects = {}
    -- Economy
    effects[#effects+1] = string.format("In-match tribute pulse: +%s Upgrade Gold per cycle", format_gold(tribute_pulse_amount()))
    effects[#effects+1] = string.format("Offline base income: +%s Upgrade Gold/s", format_gold(Upgrades.offline_income_flat_bonus()))
    effects[#effects+1] = string.format("In-match tithe scaling: +%d", silent_tithe_match_bonus())
    effects[#effects+1] = string.format("In-match vault interest: +%sg per cycle", format_gold(vault_interest_match_bonus()))
    effects[#effects+1] = string.format("Creature loyalty: +%d (upgrade bonus only)", scaled_effect(3, 2) + rally_loyalty_bonus())
    effects[#effects+1] = string.format("Training cost number: %d", scaled_reduction_value(100, 6, 0.96))
    -- Combat
    effects[#effects+1] = string.format("Creature strength: +%d (upgrade bonus only)", scaled_effect(7, 2) + veteran_drill_bonus())
    effects[#effects+1] = string.format("Dexterity: +%d (upgrade bonus only)", scaled_effect(8, 2))
    effects[#effects+1] = string.format("Spell damage: +%d (upgrade bonus only)", combined_scaled_effect({ {9, 2}, {33, 1} }))
    effects[#effects+1] = string.format("Kill bounty bonus: +%s%%", format_gold(bounty_board_bonus()))
    if hydrate_bounty_contract then hydrate_bounty_contract() end
    if Upgrades.bounty_contract then
        local c = Upgrades.bounty_contract
        effects[#effects+1] = string.format("Active bounty contract: %s %d/%d", tostring(c.name or c.kind or "Contract"), math.min(c.progress or 0, c.goal or 1), c.goal or 1)
    end
    effects[#effects+1] = string.format("Comeback death refund: +%s Upgrade Gold", format_gold(comeback_pact_refund()))
    effects[#effects+1] = string.format("Health: +%d flat +%d scaling", scaled_effect(10, 2), scaled_effect(12, 3) + rally_hp_bonus())
    effects[#effects+1] = string.format("Defense: +%d (upgrade bonus only)", scaled_effect(11, 2) + veteran_drill_bonus())
    -- Creatures
    effects[#effects+1] = string.format("Creature cap: %d", player_creature_cap_value())
    effects[#effects+1] = string.format("Hand command capacity: %d", command_capacity_value())
    effects[#effects+1] = string.format("Rally loyalty bonus: +%d", rally_loyalty_bonus())
    effects[#effects+1] = string.format("Veteran drill bonus: +%d strength/defense", veteran_drill_bonus())
    effects[#effects+1] = string.format("Scavenging cost number: %d", scaled_reduction_value(100, 18, 0.96))
    effects[#effects+1] = string.format("Level-up momentum reward: +%s Upgrade Gold", format_gold(momentum_drill_reward()))
    -- Magic
    effects[#effects+1] = string.format("Spell range: +%d (upgrade bonus only)", scaled_effect(19, 2))
    effects[#effects+1] = string.format("Spell pay number: %d", scaled_reduction_value(100, 21, 0.96))
    effects[#effects+1] = string.format("Research efficiency: +%d", research_efficiency_bonus())
    effects[#effects+1] = string.format("Workshop efficiency: +%d", workshop_efficiency_bonus())
    effects[#effects+1] = string.format("Training room efficiency: +%d", training_efficiency_bonus())
    -- Dungeon
    effects[#effects+1] = string.format("Door health: %d", door_health_value())
    effects[#effects+1] = string.format("Scavenger room efficiency: +%d", scavenger_efficiency_bonus())
    effects[#effects+1] = string.format("Rival contract intensity: +%d%%", math.floor(rival_contract_bonus() * 100 + 0.5))

    for _, eff in ipairs(effects) do
        lines[#lines+1] = eff
    end
    show(table.concat(lines, "\n"))
end

-- ─────────────────────────────────────────────
-- Awakenings / Objective Tracker HUD
-- ─────────────────────────────────────────────

function Upgrades.update_awakening_progress(key, value, max_val)
    Upgrades.awakenings = Upgrades.awakenings or {}
    local old_val = Upgrades.awakenings[key] or 0
    if value > old_val then
        Upgrades.awakenings[key] = math.min(value, max_val)
        Upgrades._dirty = true
        
        local new_val = Upgrades.awakenings[key]
        if old_val < (max_val * 0.5) and new_val >= (max_val * 0.5) then
            if QuickMessage then pcall(QuickMessage, "Awakening Progress: " .. key .. " 50%", "QUERY") end
        elseif old_val < (max_val * 0.75) and new_val >= (max_val * 0.75) then
            if QuickMessage then pcall(QuickMessage, "Awakening Progress: " .. key .. " 75%", "QUERY") end
        elseif old_val < max_val and new_val >= max_val then
            if QuickMessage then pcall(QuickMessage, "Awakening Complete: " .. key .. " 100%", "QUERY") end
        end
    end
end

-- ─────────────────────────────────────────────
-- Chat command handler
-- ─────────────────────────────────────────────

function Upgrades.OnChat(eventData)
    if not eventData then return end
    local raw_msg = eventData.Message or eventData.message or eventData.Msg or eventData.msg or eventData.Text or eventData.text or eventData.chat_message or ""
    local msg = tostring(raw_msg):lower():match("^%s*(.-)%s*$")

    local args_raw
    if msg == "/upgrades" or msg:match("^/upgrades%s") then
        args_raw = msg:match("^/upgrades%s+(.+)$") or ""
    elseif msg == "/u" or msg:match("^/u%s") then
        args_raw = msg:match("^/u%s+(.+)$") or ""
    else
        return
    end

    local args = {}
    for token in args_raw:gmatch("%S+") do args[#args + 1] = token end

    local s  = Upgrades.ui_state

    if #args == 0 then
        show_tab_list()
        return
    end

    local a1 = args[1]

    if a1 == "version" or a1 == "v" then
        show("KeeperFX Upgrades " .. tostring(Upgrades.version or "unknown") .. "\nSave: " .. tostring(Upgrades.data_path or "upgrades.dat"))
        return
    end

    if a1 == "status" or a1 == "stats" or a1 == "s" then
        show_status(); return
    end

    if a1 == "contract" or a1 == "contracts" or a1 == "bounty" then
        if args[2] == "reroll" or args[2] == "new" then
            local cost = bounty_reroll_cost()
            if cost > 0 and upgrade_gold() < cost then
                show("Bounty Board: need " .. format_gold(cost) .. " Upgrade Gold to reroll.\n" .. Upgrades.bounty_contract_status_text())
                return
            end
            local old_kind = Upgrades.bounty_contract and Upgrades.bounty_contract.kind
            if cost > 0 then deduct_upgrade_gold(cost) end
            -- Manual rerolls reset the completion streak so fishing is a convenience, not optimal farming.
            Upgrades.bounty_contract_streak = clamp_bounty_streak(0)
            Upgrades.roll_bounty_contract(true, old_kind)
            Upgrades.save()
        end
        show(Upgrades.bounty_contract_status_text())
        return
    end

    if a1 == "profile" or a1 == "p" then
        local mode = args[2]
        if mode == "turtle" or mode == "aggro" or mode == "balanced" or mode == "auto" then
            Upgrades.automation_profile = mode
            Upgrades._dirty = true
            Upgrades.save()
            show("Manual Buy Max profile set to: " .. mode:upper() .. "\nUse /u m to spend Upgrade Gold.")
        else
            show("Profile: " .. (Upgrades.automation_profile or "balanced"):upper() .. "\nUse: /u profile balanced|aggro|turtle|auto")
        end
        return
    end

    if a1 == "buymax" or a1 == "buy_max" then
        local mode = args[2]
        if mode == "on" or mode == "enable" or mode == "enabled" or mode == "off" or mode == "disable" or mode == "disabled" then
            Upgrades.toggle_buymax_auto(mode == "on" or mode == "enable" or mode == "enabled"); return
        elseif mode == "turtle" or mode == "aggro" or mode == "balanced" or mode == "auto" then
            Upgrades.automation_profile = mode
            Upgrades._dirty = true
            Upgrades.save()
            show("Manual Buy Max profile set to: " .. mode:upper() .. "\nUse /u m to buy manually.")
            return
        elseif mode == "now" or mode == "once" or mode == "manual" then
            local purchases, spent = Upgrades.buy_max()
            show(format_buymax_summary(purchases, spent))
            return
        elseif mode == "status" or mode == "s" then
            show("Auto Buy Max: " .. (Upgrades.buymax_auto_enabled and "ON" or "OFF") ..
                 "\nProfile: " .. (Upgrades.automation_profile or "balanced"):upper() ..
                 " (" .. adaptive_focus_label() .. ")" ..
                 "\nManual command: /u m" ..
                 "\nAuto: 5m adaptive ROI")
            return
        end

        show("Auto Buy Max: " .. (Upgrades.buymax_auto_enabled and "ON" or "OFF") ..
             "\nFocus: " .. adaptive_focus_label() ..
             "\n5m adaptive ROI.\n/u m buys now.")
        return
    end

    if a1 == "max" or a1 == "m" then
        local purchases, spent = Upgrades.buy_max()
        show(format_buymax_summary(purchases, spent))
        return
    end

    if a1 == "back" then
        if     s.view == "info"   and s.tab and s.sub then show_subtab(s.tab, s.sub)
        elseif s.view == "info"   and s.tab           then show_tab(s.tab)
        elseif s.view == "subtab" and s.tab           then show_tab(s.tab)
        elseif s.view == "tab"                        then show_tab_list()
        else   show_tab_list()
        end
        return
    end

    if a1 == "info" or a1 == "i" then
        local id = tonumber(args[2])
        if not id then id = s.last_id end
        if id then show_info(id) else show("Usage: /u i <id>") end
        return
    end

    if a1 == "help" or a1 == "h" or a1 == "?" then
        show("/u <1-6>  /u a/b  /u <id>  /u buy <id>  /u m  /u s  /u p  /u v  /u back")
        return
    end

    if a1 == "buy" or a1 == "b" then
        local id = tonumber(args[2])
        if not id then id = s.last_id end
        if id then do_buy(id) else show("Usage: /u buy <id>") end
        return
    end

    if s.view == "subtab" and s.tab and s.sub then
        local id = tonumber(a1)
        if id then
            local u = Upgrades._by_id[id]
            if u and u.tab == s.tab and u.sub == s.sub then
                s.last_id = id
                do_buy(id)
            else
                show_info(id)
            end
            return
        end
        local sub_char = a1:lower()
        local sub_idx = (sub_char == "a") and 1 or (sub_char == "b") and 2
        if sub_idx then show_subtab(s.tab, sub_idx); return end
    end

    if s.view == "info" and s.last_id and tonumber(a1) == s.last_id then
        do_buy(s.last_id); return
    end

    local tab_idx = tonumber(a1)
    if tab_idx and tab_idx >= 1 and tab_idx <= 6 then
        if #args >= 2 then
            local sub_char = args[2]:lower()
            local sub_idx  = (sub_char == "a") and 1 or (sub_char == "b") and 2 or tonumber(sub_char)
            if sub_idx and sub_idx >= 1 and sub_idx <= 2 then
                show_subtab(tab_idx, sub_idx); return
            end
        end
        show_tab(tab_idx); return
    end

    if s.view == "tab" and s.tab then
        local sub_char = a1:lower()
        local sub_idx  = (sub_char == "a") and 1 or (sub_char == "b") and 2
        if sub_idx then show_subtab(s.tab, sub_idx); return end
    end

    for i = 1, 6 do
        if Upgrades.tab_info[i].name:lower() == a1 then
            show_tab(i); return
        end
    end

    show("/u <1-6>  /u a/b  /u <id>  /u buy <id>  /u i <id>  /u m  /u s  /u p  /u back")
end

-- ─────────────────────────────────────────────
-- AI Rival Strength Scaling
-- ─────────────────────────────────────────────

UPGRADE_STRENGTH_WEIGHTS = {
    [2]=0.2,  [3]=0.3,  [6]=0.3,
    [7]=1.5,  [8]=1.2,  [9]=1.3,  [10]=1.5, [11]=1.2, [12]=1.4,
    [13]=1.0, [14]=1.2, [15]=0.8, [16]=1.3, [17]=0.9, [18]=0.6,
    [19]=1.1, [21]=0.7, [22]=0.6, [23]=0.6, [24]=0.7,
    [26]=0.8, [27]=0.7, [28]=0.9,
    [31]=0.2, [33]=1.1, [34]=0.6, [35]=1.0, [36]=0.8,
    [37]=0.2, [38]=0.2, [40]=1.8,
    [47]=0.7, [48]=0.6, [49]=0.6, [50]=1.1,
}

function Upgrades.compute_strength_score()
    local score = 0
    for id, w in pairs(UPGRADE_STRENGTH_WEIGHTS) do
        score = score + Upgrades.effective_owned_rank(id) * w
    end
    return score * (1.0 + rival_contract_bonus())
end

local function is_active_rival_player(p)
    if (type(p) ~= "table" and type(p) ~= "userdata") or p == PLAYER0 then return false end
    return true
end

local function get_rival_entries()
    local out, seen = {}, {}
    for _, p in ipairs(computer_player_list()) do
        if is_active_rival_player(p) and not seen[p] then
            out[#out + 1] = { p = p, hero = p == PLAYER_GOOD }
            seen[p] = true
        end
    end
    return out
end

local function get_player_ai_ranks(player)
    local idx = player_to_idx(player)
    if not idx then return {} end
    Game.upgrades_ai_ranks = Game.upgrades_ai_ranks or {}
    return Game.upgrades_ai_ranks[idx] or {}
end

local function ai_effective_rank(rank)
    -- Dynamic Scaling: AI gradually gets tougher in the late game to maintain challenge
    local turn = PLAYER0 and PLAYER0.GAME_TURN or 0
    local late_scaler = 1.0 + clamp((turn - 12000) / 42000, 0, 0.75)
    return Upgrades.effective_rank(rank) * RIVAL_POWER * late_scaler
end

local function ai_scaled_effect(player_ranks, id, per_rank)
    local rank = math.max(0, tonumber(player_ranks[id]) or 0)
    return math.floor(ai_effective_rank(rank) * per_rank + 0.5)
end

local function ai_combined_scaled_effect(player_ranks, parts)
    local total = 0
    for _, part in ipairs(parts) do
        total = total + (ai_effective_rank(math.max(0, tonumber(player_ranks[part[1]]) or 0)) * part[2])
    end
    return math.floor(total + 0.5)
end

local function ai_scaled_reduction_value(base, player_ranks, id, reduction)
    local rank = math.max(0, tonumber(player_ranks[id]) or 0)
    local per_rank = (1 - (tonumber(reduction) or 1)) * 100
    return math.max(1, math.floor((tonumber(base) or 100) - (ai_effective_rank(rank) * per_rank) + 0.5))
end

-- Veteran Drills (#17) bonus for AI rivals — mirrors veteran_drill_bonus() for the player.
local function ai_veteran_drill_bonus(player_ranks)
    return ai_scaled_effect(player_ranks, 17, 1)
end

-- Juggernaut synergy (#40) bonus for AI rivals — mirrors juggernaut_bonus() for the player.
-- Requires both Battle Fury (#7) and Iron Skin (#10) at rank 50 in the AI's rolled ranks.
local function ai_juggernaut_bonus(player_ranks)
    local rank7  = math.max(0, tonumber(player_ranks[7])  or 0)
    local rank10 = math.max(0, tonumber(player_ranks[10]) or 0)
    if rank7 < 50 or rank10 < 50 then return 0 end
    return math.min(MAX_JUGGERNAUT_BONUS, ai_scaled_effect(player_ranks, 40, 5))
end

local function apply_rival_player_effects(player)
    if not player or (type(player) ~= "table" and type(player) ~= "userdata") then return end
    local ranks = get_player_ai_ranks(player)
    if not next(ranks) then return end

    safe_call(MaxCreatures, player, player == PLAYER_GOOD and RIVAL_HERO_CREATURE_CAP or RIVAL_KEEPER_CREATURE_CAP)

    -- Feature 20: Royal Funding Influx for Hero AI
    if player == PLAYER_GOOD and not Upgrades._royal_funding_granted then
        local found_avatar = false
        if GetCreatures then
            for _, creature in ipairs(GetCreatures() or {}) do
                if creature.owner == PLAYER_GOOD and creature.model == "AVATAR" then
                    found_avatar = true
                    break
                end
            end
        end
        if found_avatar then
            Upgrades._royal_funding_granted = true
            local p_idx = player_to_idx(PLAYER_GOOD)
            if p_idx then
                Upgrades.add_ai_upgrade_gold(p_idx, 10000)
                pcall(QuickMessage, "The Lord of the Land has arrived with Royal Funding!", "QUERY")
            end
        end
    end

    -- Feature 21: Hero Party Synergy (for PLAYER_GOOD)
    -- Feature 18: Lord of the Land Raid Boss Aura
    local party_synergy_mult = 1.0
    local has_lord_aura = false
    if player == PLAYER_GOOD and GetCreatures then
        local unique_classes = {}
        local class_count = 0
        for _, creature in ipairs(GetCreatures() or {}) do
            if creature.owner == PLAYER_GOOD and creature.model then
                if not unique_classes[creature.model] then
                    unique_classes[creature.model] = true
                    class_count = class_count + 1
                end
                if (creature.model == "AVATAR" or creature.model == "KNIGHT") and (tonumber(creature.level) or 1) >= 10 then
                    has_lord_aura = true
                end
            end
        end
        if class_count >= 4 then
            party_synergy_mult = 1.15 -- +15% stats
        end
    end

    local jug_bonus_ai   = ai_juggernaut_bonus(ranks)
    local vet_bonus_ai   = ai_veteran_drill_bonus(ranks)
    local strength_bonus = ai_scaled_effect(ranks, 7, 2) + vet_bonus_ai + jug_bonus_ai
    local dexterity_bonus = ai_scaled_effect(ranks, 8, 2)
    local defense_bonus = ai_scaled_effect(ranks, 11, 2) + vet_bonus_ai + jug_bonus_ai
    -- Rally Standards (#15) contributes HP flat and loyalty, matching the player's rally_hp_bonus()/rally_loyalty_bonus().
    local health_flat = ai_scaled_effect(ranks, 10, 2) + ai_scaled_effect(ranks, 12, 3) + ai_scaled_effect(ranks, 15, 1)
    local spell_damage_bonus = ai_combined_scaled_effect(ranks, { {9, 2}, {33, 1} })
    local range_bonus = ai_scaled_effect(ranks, 19, 2)
    local loyalty_bonus = ai_scaled_effect(ranks, 3, 2) + ai_scaled_effect(ranks, 15, 1)
    local training_cost_reduction = math.max(0, 100 - ai_scaled_reduction_value(100, ranks, 6, 0.96))
    local scavenging_cost_reduction = math.max(0, 100 - ai_scaled_reduction_value(100, ranks, 18, 0.96))
    local pay_reduction = math.max(0, 100 - ai_scaled_reduction_value(100, ranks, 21, 0.96))

    if not GetCreatures then return end
    for _, creature in ipairs(GetCreatures() or {}) do
        local same_owner = false
        if creature and creature.owner then
            if type(creature.owner) == "number" then
                same_owner = (player.playerId and creature.owner == player.playerId)
            else
                same_owner = (creature.owner == player) or (player.playerId and creature.owner.playerId == player.playerId)
            end
        end
        if same_owner then
            local p_idx = player_to_idx(player)
            if p_idx and get_rival_trait_name(p_idx) == "Archon" then
                Upgrades._archon_buffed = Upgrades._archon_buffed or {}
                local key = creature.ThingIndex
                if key and not Upgrades._archon_buffed[key] then
                    Upgrades._archon_buffed[key] = true
                    local cur_lvl = tonumber(creature.level) or 1
                    if cur_lvl < 10 then
                        pcall(function() creature:level_up(1) end)
                    end
                end
            end
            safe_call(function()
                local base = record_creature_base(creature)
                if not base then return end

                -- Raid Boss Aura extra flat bonus
                local aura_str = (has_lord_aura and creature.model ~= "AVATAR" and creature.model ~= "KNIGHT") and 15 or 0
                local aura_def = (has_lord_aura and creature.model ~= "AVATAR" and creature.model ~= "KNIGHT") and 15 or 0

                -- Apply party synergy factor to strength, defense, health
                local final_str = math.floor(((base.strength or 0) + strength_bonus + aura_str) * party_synergy_mult + 0.5)
                local final_def = math.floor(((base.defense or 0) + defense_bonus + aura_def) * party_synergy_mult + 0.5)
                local final_hp_flat = math.floor(health_flat * party_synergy_mult + 0.5)

                local base_health = base_creature_health(creature.model) or base.max_health
                if base_health then
                    Upgrades._rival_applied_health_bonus = Upgrades._rival_applied_health_bonus or {}
                    local key = creature.ThingIndex
                    local previous_bonus = key and (Upgrades._rival_applied_health_bonus[key] or 0) or 0
                    local old_max = tonumber(creature.max_health) or base.max_health or base_health
                    local old_hp = tonumber(creature.health) or old_max
                    local unbuffed_max = math.max(1, old_max - previous_bonus, base_health)
                    local base_hp_scaled = math.floor(unbuffed_max * party_synergy_mult + 0.5)
                    local new_max = math.max(1, base_hp_scaled + final_hp_flat)
                    local was_full = old_hp >= old_max
                    set_live_field(creature, "max_health", new_max)
                    if was_full then
                        creature.health = new_max
                    elseif new_max > old_max then
                        creature.health = math.min(new_max, old_hp + (new_max - old_max))
                    else
                        creature.health = math.min(old_hp, new_max)
                    end
                    if key then Upgrades._rival_applied_health_bonus[key] = final_hp_flat + (base_hp_scaled - unbuffed_max) end
                end

                if base.strength then set_live_field(creature, "strength", math.max(1, final_str)) end
                if base.dexterity then set_live_field(creature, "dexterity", math.max(1, base.dexterity + dexterity_bonus)) end
                if base.defense then set_live_field(creature, "defense", math.max(1, final_def)) end
                if base.spell_damage then set_live_field(creature, "spell_damage", math.max(1, base.spell_damage + spell_damage_bonus)) end
                if base.range then set_live_field(creature, "range", math.max(1, base.range + range_bonus)) end
                if base.loyalty then set_live_field(creature, "loyalty", math.max(1, base.loyalty + loyalty_bonus)) end
                if base.training_cost then set_live_field(creature, "training_cost", math.max(1, base.training_cost - training_cost_reduction)) end
                if base.scavenging_cost then set_live_field(creature, "scavenging_cost", math.max(1, base.scavenging_cost - scavenging_cost_reduction)) end
                if base.pay then set_live_field(creature, "pay", math.max(1, base.pay - pay_reduction)) end
            end)
        end
    end
end

local function generate_ai_upgrades(target_score, profile)
    local ai_ranks = {}
    local current_score = 0
    
    local available_ids = {}
    for _, u in ipairs(UPGRADES) do
        -- Hidden/synergy upgrades are player progression rewards, not rival roll lottery prizes.
        if type(u.hidden) ~= "function" then
            table.insert(available_ids, u.id)
        end
    end
    
    if #available_ids == 0 or target_score <= 0 then
        return ai_ranks
    end
    
    local max_iterations = 10000
    local iter = 0
    local stagnant = 0
    
    while current_score < target_score and iter < max_iterations do
        iter = iter + 1
        local id = weighted_random_upgrade_id(available_ids, profile, 0.10, 5.50) or available_ids[math.random(1, #available_ids)]
        local w = UPGRADE_STRENGTH_WEIGHTS[id] or 1.0
        
        -- Capped but swingier chunks make rival rolls feel less samey without huge overshoots.
        local max_chunk = math.min(15, math.max(1, math.floor(target_score / random_range(8, 20))))
        local chunk = math.random(1, max_chunk)
        if math.random() < 0.25 and max_chunk > 1 then
            chunk = math.random(math.max(1, math.floor(max_chunk * 0.5)), max_chunk)
        end
        
        local rank = ai_ranks[id] or 0
        local next_rank = rank + chunk
        
        local score_diff = (Upgrades.effective_rank(next_rank) - Upgrades.effective_rank(rank)) * w
        
        -- Prevent overshoot
        local before_score = current_score
        if current_score + score_diff > target_score * 1.35 then
            local single_diff = (Upgrades.effective_rank(rank + 1) - Upgrades.effective_rank(rank)) * w
            if current_score + single_diff <= target_score * 1.35 then
                ai_ranks[id] = rank + 1
                current_score = current_score + single_diff
            end
        else
            ai_ranks[id] = next_rank
            current_score = current_score + score_diff
        end
        if current_score == before_score then
            stagnant = stagnant + 1
            if stagnant > 250 then break end
        else
            stagnant = 0
        end
    end
    
    return ai_ranks
end

local function get_random_difficulty_variance()
    local player_strength = Upgrades.compute_strength_score and Upgrades.compute_strength_score() or 0
    local rand = math.random()
    
    if player_strength > 120 then
        -- Highly upgraded player: push rivals into Hard, Nightmare, or Apocalypse
        if rand < 0.15 then
            return "hard", random_range(1.50, 3.00)
        elseif rand < 0.70 then
            return "nightmare", random_range(3.50, 6.50)
        else
            return "apocalypse", random_range(7.00, 11.00)
        end
    elseif player_strength > 50 then
        -- Moderately upgraded player: eliminate easy rivals
        if rand < 0.40 then
            return "normal", random_range(0.85, 1.70)
        elseif rand < 0.85 then
            return "hard", random_range(1.50, 3.20)
        else
            return "nightmare", random_range(3.50, 6.00)
        end
    else
        -- Standard/early game distribution
        if rand < 0.20 then
            return "easy", random_range(0.25, 0.80)
        elseif rand < 0.60 then
            return "normal", random_range(0.70, 1.55)
        elseif rand < 0.90 then
            return "hard", random_range(1.30, 2.85)
        else
            return "nightmare", random_range(3.50, 6.00)
        end
    end
end

function Upgrades.roll_rival_buffs(score)
    local rivals  = get_rival_entries()
    local rolls   = {}
    for _, entry in ipairs(rivals) do
        local hero_mult = entry.hero and RIVAL_HERO_SCORE_MULT or RIVAL_KEEPER_SCORE_MULT
        local variance_type, variance = get_random_difficulty_variance()
        local profile = make_ai_upgrade_profile(entry.hero, entry.p)
        local target_score = (score + RIVAL_BASE_SCORE) * variance * hero_mult * random_range(0.82, 1.22)
        
        local ai_ranks = generate_ai_upgrades(target_score, profile)
        
        rolls[#rolls + 1] = {
            player        = entry.p,
            is_hero       = entry.hero,
            upgrade_ranks = ai_ranks,
            tier          = target_score,
            variance_type = variance_type,
        }
    end
    return rolls
end

local function apply_one_rival_roll(roll)
    local p = roll.player
    if not p then return end
    
    local player_idx = player_to_idx(p)
    if not player_idx then return end
    
    Game.upgrades_ai_ranks = Game.upgrades_ai_ranks or {}
    Game.upgrades_ai_ranks[player_idx] = {}
    
    local ai_ranks = Game.upgrades_ai_ranks[player_idx]
    
    for upgrade_id, rank in pairs(roll.upgrade_ranks or {}) do
        local upgrade = Upgrades._by_id[upgrade_id]
        if upgrade and rank > 0 then
            ai_ranks[upgrade_id] = rank
            
            -- Do not call upgrade.apply for rival rolls: those apply functions are
            -- player/global configuration hooks. Rival creature stats are applied
            -- separately in apply_rival_player_effects().
        end
    end
    
    safe_call(MaxCreatures, p, p == PLAYER_GOOD and RIVAL_HERO_CREATURE_CAP or RIVAL_KEEPER_CREATURE_CAP)
    apply_rival_player_effects(p)
end

function Upgrades.apply_rival_rolls()
    Game.upgrades_ai_rolls = Game.upgrades_ai_rolls or {}
    local stored = Game.upgrades_ai_rolls
    if #stored == 0 then return end
    local player_map = {
        [1]=PLAYER1, [2]=PLAYER2, [3]=PLAYER3,
        [4]=PLAYER4, [5]=PLAYER5, [6]=PLAYER6,
        [7]=PLAYER_GOOD,
    }
    for _, roll in ipairs(stored) do
        local p = player_map[roll.player_idx]
        if type(p) == "table" or type(p) == "userdata" then
            roll.player = p
            apply_one_rival_roll(roll)
        end
    end
end

player_to_idx = function(p)
    if not p then return nil end
    local lut = {
        [1]=PLAYER1, [2]=PLAYER2, [3]=PLAYER3,
        [4]=PLAYER4, [5]=PLAYER5, [6]=PLAYER6,
        [7]=PLAYER_GOOD,
    }
    if type(p) == "number" then
        for idx, ref in pairs(lut) do
            if ref and (ref.playerId == p or idx == p) then return idx end
        end
    else
        for idx, ref in pairs(lut) do
            if ref == p or (ref and p.playerId and ref.playerId == p.playerId) then return idx end
        end
    end
    return nil
end

local RIVAL_ROLL_VERSION = 5

local function current_rival_roll_turn()
    return math.max(0, tonumber(PLAYER0 and PLAYER0.GAME_TURN) or 0)
end

local function rival_roll_needs_refresh()
    local rolls = Game and Game.upgrades_ai_rolls
    if Game.upgrades_ai_roll_version ~= RIVAL_ROLL_VERSION then return true end
    if Game.upgrades_ai_roll_session_id ~= Upgrades.rival_roll_session_id then return true end
    if type(rolls) ~= "table" or #rolls == 0 then return true end
    local stored_turn = tonumber(Game.upgrades_ai_roll_turn)
    if stored_turn and current_rival_roll_turn() < stored_turn then return true end
    return false
end

function Upgrades.init_rivals()
    if not Game then return end

    -- Assign permanent traits to each rival if not already set
    Game.upgrades_ai_traits = Game.upgrades_ai_traits or {}
    for _, entry in ipairs(get_rival_entries()) do
        local idx = player_to_idx(entry.p)
        if idx and not Game.upgrades_ai_traits[idx] then
            local trait_list = entry.hero and HERO_TRAITS or AI_TRAITS
            Game.upgrades_ai_traits[idx] = trait_list[math.random(1, #trait_list)].name
        end
    end

    local need_roll = rival_roll_needs_refresh()
    if need_roll then
        local score = Upgrades.compute_strength_score()
        local rolls = Upgrades.roll_rival_buffs(score)

        Game.upgrades_ai_ranks = {}

        local serialisable = {}
        for _, roll in ipairs(rolls) do
            local idx = player_to_idx(roll.player)
            if idx then
                serialisable[#serialisable + 1] = {
                    player_idx    = idx,
                    is_hero       = roll.is_hero,
                    upgrade_ranks = roll.upgrade_ranks,
                    tier          = roll.tier,
                }
            end
        end
        Game.upgrades_ai_rolls = serialisable
        Game.upgrades_ai_roll_turn = current_rival_roll_turn()
        Game.upgrades_ai_roll_version = RIVAL_ROLL_VERSION
        Game.upgrades_ai_roll_session_id = Upgrades.rival_roll_session_id
        Upgrades.announce_rival_buffs(rolls, score)
    end

    Upgrades.apply_rival_rolls()
end

function Upgrades.announce_rival_buffs(rolls, score)
    for _, roll in ipairs(rolls) do
        if roll.is_hero and roll.variance_type == "apocalypse" then
            if QuickObjective then
                pcall(QuickObjective, "CRISIS: An Apocalyptic Hero has arisen to cleanse the dungeon!", nil)
            elseif QuickMessage then
                pcall(QuickMessage, "CRISIS: An Apocalyptic Hero has arisen to cleanse the dungeon!", "QUERY")
            end
        elseif roll.is_hero and roll.variance_type == "nightmare" then
            if QuickObjective then
                pcall(QuickObjective, "WARNING: A Nightmare-tier Hero has entered the realm!", nil)
            elseif QuickMessage then
                pcall(QuickMessage, "WARNING: A Nightmare-tier Hero has entered the realm!", "QUERY")
            end
        elseif roll.is_hero and roll.variance_type == "hard" then
            if QuickMessage then pcall(QuickMessage, "A formidable Hero approaches...", "QUERY") end
        elseif not roll.is_hero and roll.variance_type == "apocalypse" then
            if QuickMessage then pcall(QuickMessage, "CRISIS: An Apocalyptic rival Keeper is digging nearby!", "QUERY") end
        elseif not roll.is_hero and roll.variance_type == "nightmare" then
            if QuickMessage then pcall(QuickMessage, "WARNING: A Nightmare-tier rival Keeper is digging nearby!", "QUERY") end
        end
    end
end

function Upgrades_InitRivals()
    if Upgrades and Upgrades.init_rivals then
        pcall(Upgrades.init_rivals)
    end
end

function Upgrades_ApplyRivalCreatureStats()
    if Upgrades and Upgrades.apply_rival_rolls then
        pcall(Upgrades.apply_rival_rolls)
    end
end

function Upgrades_AutoSave()
    if Upgrades and Upgrades._dirty then
        local ok, saved = pcall(Upgrades.save)
        if not ok then
            print("Upgrades: " .. tostring(saved))
        end
    end
end

function Upgrades_EconomyPulse()
    if not Upgrades then return end
    
    Upgrades.garbage_collect_creatures()

    if PLAYER0 then
        local ok_money, money = pcall(function() return PLAYER0.MONEY end)
        if ok_money and type(money) == "number" then
            Upgrades.update_awakening_progress("gold_hoarded", money, 1000000)
            local max_money = 250000
            if max_money > 0 and money >= max_money * 0.95 then
                local transmute = math.floor(money * LIQUIDATOR_RATE)
                if transmute > 0 then
                    pcall(function() PLAYER0:add_gold(-transmute) end)
                    Upgrades.add_upgrade_gold(transmute * LIQUIDATOR_UPGRADE_GOLD_RATIO)
                end
            end
        end

        local tithe_bonus = silent_tithe_match_bonus()
        local bonus = tribute_pulse_amount() + tithe_bonus + vault_interest_match_bonus()
        if bonus > 0 then
            pcall(function() PLAYER0:add_gold(bonus) end)
            Upgrades.add_upgrade_gold(bonus)
        end
    end

    for _, p in ipairs(computer_player_list()) do
        if is_active_rival_player(p) then
            local p_idx = player_to_idx(p)
            if p_idx then
                if Upgrades.ai_gold_locked then
                    -- Telemetry/QA lock
                    Upgrades.add_ai_upgrade_gold(p_idx, 0)
                else
                    local ranks = get_player_ai_ranks(p)
                    local pulse = ai_combined_scaled_effect(ranks, { {2, 10}, {31, 18} })
                    
                    -- AI treasury-aware check: low gold triggers starvation relief
                    local starvation_boost = 0
                    if (p.MONEY or 0) < 1000 then
                        starvation_boost = 25
                    end

                    -- Calculate AI strength score
                    local ai_score = 0
                    for id, r in pairs(ranks) do
                        ai_score = ai_score + Upgrades.effective_rank(r) * (UPGRADE_STRENGTH_WEIGHTS[id] or 1.0)
                    end
                    local p_score = Upgrades.compute_strength_score()

                    -- Tech Catch-up (rubber-banding)
                    local catch_up = 1.0
                    if ai_score < p_score * 0.5 then
                        catch_up = 1.75
                    elseif ai_score < p_score * 0.8 then
                        catch_up = 1.35
                    end

                    -- Late-game tribute escalation
                    local turn = current_rival_roll_turn()
                    local escalation = 1.0
                    if turn > 20000 then
                        escalation = 1.0 + clamp((turn - 20000) / 5000, 0, 5.0) * 0.15
                    end
                    -- Endgame crisis scaling (turn 30000+): steep income ramp so AI can field
                    -- high-rank upgrades and keep pressure on a stacked player.
                    local crisis_mult = 1.0
                    if turn > 30000 then
                        crisis_mult = 1.0 + clamp((turn - 30000) / 10000, 0, 4.0) * 0.40
                        escalation = escalation * crisis_mult
                    end

                    -- Give computer players a guaranteed baseline income so they can buy upgrades mid-game
                    -- even if they didn't randomly roll an economy focus.
                    local base_income = math.floor(p_score / 15) + 12
                    if p == PLAYER_GOOD then
                        base_income = math.floor(base_income * 1.5)
                        
                        -- Hero specific comeback rubber-band
                        local hero_ranks = get_player_ai_ranks(PLAYER_GOOD)
                        local hero_rank_sum = 0
                        for _, c in pairs(hero_ranks) do hero_rank_sum = hero_rank_sum + c end
                        local hero_score = hero_rank_sum * 15
                        
                        if hero_score < (p_score * 0.4) then
                            base_income = base_income * 2.5
                        elseif hero_score < (p_score * 0.6) then
                            base_income = base_income * 1.5
                        end
                    end
                    pulse = math.floor((pulse + base_income) * catch_up * escalation) + starvation_boost

                    if pulse > 0 then
                        Upgrades.add_ai_upgrade_gold(p_idx, pulse)
                    end

                    -- Feature 17: Emergency Upgrade Sell-back
                    if p.heart and p.heart.isValid and p.heart:isValid() and p.heart.health and p.heart.max_health then
                        if p.heart.health < p.heart.max_health * 0.45 then
                            local sold_gold = 0
                            for _, econ_id in ipairs({2, 3, 6, 31, 37, 38, 22, 23, 24, 28, 34}) do
                                local rank = ranks[econ_id] or 0
                                if rank > 5 then
                                    local refund_count = math.floor(rank * 0.25)
                                    local u = Upgrades._by_id[econ_id]
                                    if u and refund_count > 0 then
                                        for r = rank, rank - refund_count + 1, -1 do
                                            local cost = safe_upgrade_cost(u.base, math.max(1.01, (tonumber(Upgrades.price_scale) or 1.15)), r)
                                            sold_gold = sold_gold + math.floor(cost * 0.5)
                                        end
                                        ranks[econ_id] = rank - refund_count
                                    end
                                end
                            end
                            if sold_gold > 0 then
                                Upgrades.add_ai_upgrade_gold(p_idx, sold_gold)
                                -- Force immediate defense buying
                                ai_buy_max(p)
                            end
                        end
                        
                        if p.heart.health < p.heart.max_health * 0.30 then
                            if not p._rage_triggered or (PLAYER0 and (PLAYER0.GAME_TURN - p._rage_triggered > 600)) then
                                p._rage_triggered = PLAYER0 and PLAYER0.GAME_TURN or 0
                                if GetCreatures then
                                    for _, cr in ipairs(GetCreatures() or {}) do
                                        local same_owner = false
                                        if type(cr.owner) == "number" then same_owner = (p.playerId and cr.owner == p.playerId)
                                        else same_owner = (cr.owner == p) or (p.playerId and cr.owner.playerId == p.playerId) end
                                        
                                        if same_owner then
                                            pcall(function()
                                                if cr.strength then cr.strength = cr.strength + 75 end
                                                if cr.defense then cr.defense = cr.defense + 75 end
                                            end)
                                        end
                                    end
                                end
                                if QuickMessage then pcall(QuickMessage, "An enemy Keeper is Enraged! (Heart < 30%)", "QUERY") end
                            end
                        end
                    end
                end
            end
        end

        -- Trigger trait abilities for each AI rival
        trigger_rival_trait_ability(p)
    end

    -- Rival rivalry: AI rivals occasionally skirmish with each other.
    -- Winner gets bonus gold, loser loses some.
    trigger_rival_rivalry()

    -- Decay kill-profile each pulse so old data fades
    if Upgrades._kill_profile then
        for k, v in pairs(Upgrades._kill_profile) do
            Upgrades._kill_profile[k] = v * KILL_METHOD_DECAY
        end
    end
end

-- ─────────────────────────────────────────────
-- Rival rivalry events
-- ─────────────────────────────────────────────
-- Rivals periodically fight each other, creating dynamic escalation.
function trigger_rival_rivalry()
    local rivals = get_rival_entries()
    if #rivals < 2 then return end
    local turn = current_rival_roll_turn()
    if turn < 5000 then return end  -- too early

    -- Low probability per pulse (~5% per 200-tick pulse = ~every 2 minutes on average)
    if math.random() > 0.05 then return end

    -- Pick two different rivals
    local a_idx = math.random(1, #rivals)
    local b_idx = a_idx
    while b_idx == a_idx do b_idx = math.random(1, #rivals) end
    local a = rivals[a_idx]
    local b = rivals[b_idx]

    local a_p_idx = player_to_idx(a.p)
    local b_p_idx = player_to_idx(b.p)
    if not a_p_idx or not b_p_idx then return end

    -- Compare strength scores
    local a_ranks = get_player_ai_ranks(a.p)
    local b_ranks = get_player_ai_ranks(b.p)
    local a_score = 0
    for id, r in pairs(a_ranks) do a_score = a_score + r * (UPGRADE_STRENGTH_WEIGHTS[id] or 1.0) end
    local b_score = 0
    for id, r in pairs(b_ranks) do b_score = b_score + r * (UPGRADE_STRENGTH_WEIGHTS[id] or 1.0) end

    local winner, loser, w_p_idx, l_p_idx
    if a_score > b_score then
        winner, loser = a, b
        w_p_idx, l_p_idx = a_p_idx, b_p_idx
    else
        winner, loser = b, a
        w_p_idx, l_p_idx = b_p_idx, a_p_idx
    end

    -- Winner gets a burst of upgrade gold, loser loses some
    local winnings = math.floor(math.max(10, (a_score + b_score) * 0.15))
    local losses = math.floor(math.max(5, math.min(b_score, winnings * 0.3)))

    Upgrades.add_ai_upgrade_gold(w_p_idx, winnings)
    local loser_gold = Upgrades.get_ai_upgrade_gold(l_p_idx)
    if loser_gold >= losses then
        Upgrades.add_ai_upgrade_gold(l_p_idx, -losses)
    end

    -- Sometimes announce major rivalries
    if a_score > 100 or b_score > 100 then
        local winner_name = winner.hero and "Hero forces" or "Keeper"
        local loser_name = loser.hero and "Hero forces" or "Keeper"
        if QuickMessage then
            pcall(QuickMessage, "Rival clash: " .. winner_name .. " defeated " .. loser_name .. " in battle!", "QUERY")
        end
    end
end

local function add_progress_reward(amount)
    amount = math.max(0, math.floor(tonumber(amount) or 0))
    amount = math.min(MAX_SAFE_COST, math.floor(amount * PROGRESS_REWARD_SCALE + 0.5))
    if amount <= 0 or not PLAYER0 then return end
    pcall(function() PLAYER0:add_gold(amount) end)
    Upgrades.add_upgrade_gold(amount)
end

local function progress_reward_from_delta(delta, bonus, divisor)
    delta = math.max(0, tonumber(delta) or 0)
    bonus = math.max(0, tonumber(bonus) or 0)
    if delta <= 0 or bonus <= 0 then return 0 end
    return math.floor((delta * bonus) / math.max(1, divisor or 100) + 0.5)
end

function Upgrades_ProgressPulse()
    if not Upgrades or not PLAYER0 then return end

    local research = tonumber(PLAYER0.TOTAL_RESEARCH) or 0
    local manufactured = tonumber(PLAYER0.TOTAL_MANUFACTURED) or 0
    local scavenged = tonumber(PLAYER0.CREATURES_SCAVENGED_GAINED) or 0

    if Upgrades._last_research == nil or Upgrades._last_manufactured == nil or Upgrades._last_scavenged == nil then
        Upgrades._last_research = research
        Upgrades._last_manufactured = manufactured
        Upgrades._last_scavenged = scavenged
        return
    end

    local reward = 0
    reward = reward + progress_reward_from_delta(research - Upgrades._last_research, research_efficiency_bonus(), 50)
    reward = reward + progress_reward_from_delta(manufactured - Upgrades._last_manufactured, workshop_efficiency_bonus(), 2)
    reward = reward + progress_reward_from_delta(scavenged - Upgrades._last_scavenged, scavenger_efficiency_bonus(), 1)

    Upgrades._last_research = research
    Upgrades._last_manufactured = manufactured
    Upgrades._last_scavenged = scavenged

    add_progress_reward(reward)
end

function Upgrades_OnPowerCast(eventData)
    if not Upgrades or not PLAYER0 or not eventData then return end
    local caster = event_player(eventData)
    if caster ~= PLAYER0 then return end
    
    local current_spells = Upgrades.awakenings and Upgrades.awakenings.spells_cast or 0
    Upgrades.update_awakening_progress("spells_cast", current_spells + 1, 500)

    -- Kill-profile tracking: spell usage
    Upgrades._kill_profile = Upgrades._kill_profile or { trap=0, creature=0, spell=0, ranged=0 }
    Upgrades._kill_profile.spell = (Upgrades._kill_profile.spell or 0) + 1

    local refund = math.min(MAX_POWER_REFUND, math.max(0, math.floor(scaled_utility_effect(21, 1) + 0.5)))
    if refund > 0 then
        pcall(function() PLAYER0:add_gold(refund) end)
    end

    local healamount = math.min(MAX_POWER_HEAL, math.floor((scaled_effect(19, 1) + scaled_effect(9, 1)) / 5 + 0.5))
    local target = event_subject(eventData)
    if target and is_owned_by_player0(target) and healamount > 0 then
        pcall(function()
            if target.isValid and not target:isValid() then return end
            if target.health and target.max_health and target.health > 0 and target.health < target.max_health then
                target.health = math.min(target.max_health, target.health + healamount)
            end
        end)
    end
end

function Upgrades_OnLevelUp(eventData)
    if not Upgrades or not PLAYER0 or not eventData then return end
    local creature = eventData.creature or eventData.Creature or eventData.unit or eventData.Unit or eventData.thing or eventData.Thing
    if not creature or not is_owned_by_player0(creature) then return end
    -- Bonus level-ups from Dark Scholarship should not recursively award Momentum/contract progress.
    if Upgrades._bonus_leveling then return end

    local bonus = training_efficiency_bonus()
    local momentum = momentum_drill_reward()
    if momentum > 0 then
        Upgrades.add_upgrade_gold(momentum)
    end
    Upgrades.advance_bounty_contract("levelup", 1)

    if bonus <= 0 then return end

    local threshold = math.max(10, 100 - bonus * 4)  -- scales threshold down with efficiency: 0->100, 25->0
    Upgrades._training_bonus_progress = (Upgrades._training_bonus_progress or 0) + bonus
    if Upgrades._training_bonus_progress < threshold then return end
    Upgrades._training_bonus_progress = Upgrades._training_bonus_progress - threshold

    if Upgrades._bonus_leveling then return end
    Upgrades._bonus_leveling = true
    pcall(function()
        if creature.isValid and not creature:isValid() then Upgrades._bonus_leveling = false; return end
        if (tonumber(creature.level) or 1) >= 10 then Upgrades._bonus_leveling = false; return end
        creature:level_up(1)
    end)
    Upgrades._bonus_leveling = false
end

function Upgrades_OnApplyDamage(eventData)
    if not Upgrades or not eventData then return end

    if PLAYER0 then Upgrades._recent_combat_turn = PLAYER0.GAME_TURN or 0 end

    local target = eventData.thing or eventData.Thing or eventData.target or eventData.Target or eventData.unit or eventData.Unit
    if not target then return end
    local dealing_player = event_player(eventData)

    if dealing_player then
        if target.ThingIndex then
            Upgrades._recent_damage_sources = Upgrades._recent_damage_sources or {}
            Upgrades._recent_damage_sources[target.ThingIndex] = {
                player = dealing_player,
                turn = PLAYER0 and PLAYER0.GAME_TURN or 0
            }
            if PLAYER0 and dealing_player == PLAYER0 then
                Upgrades._recent_player_damage = Upgrades._recent_player_damage or {}
                Upgrades._recent_player_damage[target.ThingIndex] = PLAYER0.GAME_TURN or 0
            end
        end
    end

    if PLAYER0 and dealing_player == PLAYER0 and not is_owned_by_player0(target) then
        Upgrades._recent_damage_dealt_turn = PLAYER0.GAME_TURN or 0
        -- Kill-profile tracking: player dealt direct damage (creature melee or spell)
        Upgrades._kill_profile = Upgrades._kill_profile or { trap=0, creature=0, spell=0, ranged=0 }
        Upgrades._kill_profile.creature = (Upgrades._kill_profile.creature or 0) + 1

        local bonus = math.max(0, math.floor(combined_scaled_effect({ {9, 1}, {33, 1} }) + 0.5))
        if bonus > 0 then
            pcall(function()
                if target.isValid and not target:isValid() then return end
                if target.health and target.health > 0 then
                    target.health = math.max(1, target.health - bonus)
                end
            end)
        end
        -- Do not return here: rival defensive traits also need to react when
        -- the player damages their creatures.
    end

    local target_is_player_owned = is_owned_by_player0(target)

    -- Sniper trait: extra damage when a Sniper rival damages player creatures.
    -- This must run before the player-owned damage branch returns, otherwise the
    -- trait silently never fires in normal combat.
    if target_is_player_owned and is_active_rival_player(dealing_player) then
        local dealer_idx = player_to_idx(dealing_player)
        if dealer_idx then
            local trait_name = get_rival_trait_name(dealer_idx)
            if trait_name == "Sniper" and target.health and target.health > 0 then
                -- Use the rival's own learned ranks, not the player's Predator's Edge rank.
                local ranks = get_player_ai_ranks(dealing_player)
                local sniper_power = ai_combined_scaled_effect(ranks, { {8, 1}, {19, 1}, {33, 1} })
                local sniper_bonus = math.min(18, math.max(1, math.floor(sniper_power * 0.25 + 0.5)))
                if sniper_bonus > 0 then
                    pcall(function()
                        if target.isValid and not target:isValid() then return end
                        target.health = math.max(1, target.health - sniper_bonus)
                    end)
                end
            elseif trait_name == "Inquisitor" and target.health and target.health > 0 then
                local target_lvl = creature_level_value(target)
                if target_lvl >= 4 then
                    local bonus_dmg = math.floor(target_lvl * 2.5)
                    pcall(function()
                        if target.isValid and not target:isValid() then return end
                        target.health = math.max(1, target.health - bonus_dmg)
                    end)
                end
            end
        end
    end

    if target_is_player_owned then
        Upgrades._recent_damage_taken_turn = PLAYER0 and PLAYER0.GAME_TURN or 0
        local damage = math.max(0, tonumber(eventData.damage or eventData.Damage or eventData.amount or eventData.Amount) or 0)
        local heal_back = math.min(damage, math.min(MAX_HEAL_BACK_FLAT, scaled_effect(11, 1) + scaled_effect(12, 1)))
        if heal_back > 0 then
            pcall(function()
                if target.isValid and not target:isValid() then return end
                if target.health and target.health > 0 then
                    target.health = math.min(target.max_health or target.health, target.health + heal_back)
                end
            end)
        end
        return
    end

    -- Berserker trait: when an AI creature is wounded by the player, grant a
    -- capped strength boost.  V11 stacked the bonus every hit, which could turn
    -- one survivor into an accidental infinite boss during long fights.
    if PLAYER0 and dealing_player == PLAYER0 and target and target.owner and target ~= PLAYER0 then
        local owner_idx = player_to_idx(target.owner)
        if owner_idx then
            local trait_name = get_rival_trait_name(owner_idx)
            
            -- Berserker trait wounded check
            if trait_name == "Berserker" and target.strength then
                local wounded_pct = 1.0 - (tonumber(target.health) or 1) / math.max(1, tonumber(target.max_health) or 1)
                if wounded_pct > 0.25 then
                    local thing_key = target.ThingIndex or tostring(target)
                    Upgrades._berserker_bonus_by_thing = Upgrades._berserker_bonus_by_thing or {}
                    local applied = Upgrades._berserker_bonus_by_thing[thing_key] or 0
                    local desired = math.min(24, math.floor(wounded_pct * 30))
                    local delta = math.max(0, desired - applied)
                    if delta > 0 then
                        Upgrades._berserker_bonus_by_thing[thing_key] = applied + delta
                        pcall(function()
                            if target.isValid and not target:isValid() then return end
                            target.strength = math.max(1, target.strength + delta)
                        end)
                    end
                end
            end

            -- AI Keeper Retaliatory Spell Support (if not Good player)
            if target.owner ~= PLAYER_GOOD then
                local turn = PLAYER0 and PLAYER0.GAME_TURN or 0
                Upgrades._last_retaliation_turn = Upgrades._last_retaliation_turn or {}
                local last_ret = Upgrades._last_retaliation_turn[owner_idx] or 0
                if turn - last_ret > 200 then
                    local attacker = eventData.source or eventData.Source or eventData.caster or eventData.Caster
                    if attacker and is_owned_by_player0(attacker) and attacker.health and attacker.health > 0 then
                        local ranks = get_player_ai_ranks(target.owner)
                        local spell_power = ai_combined_scaled_effect(ranks, { {9, 2}, {33, 1} })
                        local ret_chance = 0.08 + (spell_power * 0.005)
                        ret_chance = math.min(0.25, ret_chance)
                        if math.random() < ret_chance then
                            Upgrades._last_retaliation_turn[owner_idx] = turn
                            local dmg = 15 + math.floor(spell_power * 0.5)
                            pcall(function()
                                if attacker.isValid and not attacker:isValid() then return end
                                attacker.health = math.max(1, attacker.health - dmg)
                            end)
                            if QuickMessage and math.random() < 0.3 then
                                pcall(QuickMessage, "An enemy Keeper targets your creature with lightning!", "QUERY")
                            end
                        end
                    end
                end
            end
        end
    end

    -- Hero Divine Intervention (for PLAYER_GOOD)
    if target_is_player_owned == false and target.owner == PLAYER_GOOD and target.health and target.max_health then
        local hp_pct = target.health / target.max_health
        if hp_pct < 0.40 then
            local turn = PLAYER0 and PLAYER0.GAME_TURN or 0
            local target_idx = target.ThingIndex or tostring(target)
            Upgrades._intervention_stacks = Upgrades._intervention_stacks or {}
            local stacks = Upgrades._intervention_stacks[target_idx] or 0

            if stacks < 5 then
                Upgrades._last_intervention_turn = Upgrades._last_intervention_turn or 0
                if turn - Upgrades._last_intervention_turn > 150 then
                    Upgrades._last_intervention_turn = turn
                    Upgrades._intervention_stacks[target_idx] = stacks + 1
                    pcall(function()
                        if target.isValid and not target:isValid() then return end
                        local heal = math.floor(target.max_health * 0.20)
                        target.health = math.min(target.max_health, target.health + heal)
                        if target.defense then target.defense = target.defense + 10 end
                    end)
                    
                    Upgrades._last_intervention_msg_turn = Upgrades._last_intervention_msg_turn or 0
                    if QuickMessage and (turn - Upgrades._last_intervention_msg_turn > 600) then
                        Upgrades._last_intervention_msg_turn = turn
                        pcall(QuickMessage, "The heroes receive Divine Intervention!", "QUERY")
                    end
                end
            end
        end
    end
end

function Upgrades_OnCreatureDeath(eventData)
    if not Upgrades or not eventData then return end
    local dead = eventData.unit or eventData.Unit or eventData.creature or eventData.Creature or eventData.thing or eventData.Thing
    
    if dead and is_owned_by_player0(dead) then
        if PLAYER0 then
            Upgrades._mortality_score = (Upgrades._mortality_score or 0) + 1
            Upgrades._last_death_turn = PLAYER0.GAME_TURN or 0

            Upgrades.dnc_memory = Upgrades.dnc_memory or {}
            local wave = math.floor((PLAYER0.GAME_TURN or 0) / 1000)
            Upgrades.dnc_memory[wave] = (Upgrades.dnc_memory[wave] or 0) + 1
        end
        local comeback = comeback_pact_refund()
        if comeback > 0 then
            Upgrades.add_upgrade_gold(comeback)
        end
        Upgrades._bounty_recent_losses = math.min(20, (Upgrades._bounty_recent_losses or 0) + 1)
    end

    local idx = dead and dead.ThingIndex
    if idx then
        if Upgrades._berserker_bonus_by_thing then
            Upgrades._berserker_bonus_by_thing[idx] = nil
        end
        if Upgrades._intervention_stacks then
            Upgrades._intervention_stacks[idx] = nil
        end
        if Game and Game._wm_applied then
            Game._wm_applied[idx] = nil
        end
    end
    if not idx or not Upgrades._recent_damage_sources then return end

    local turn = PLAYER0 and PLAYER0.GAME_TURN or 0
    local last_hit_info = Upgrades._recent_damage_sources[idx]
    Upgrades._recent_damage_sources[idx] = nil
    
    if not last_hit_info or (turn - last_hit_info.turn) > 200 then return end
    
    local killer = last_hit_info.player
    if not killer then return end
    
    if dead.owner == killer then return end

    if PLAYER0 and killer == PLAYER0 then
        -- Contract progress must not depend on the tiny per-kill reward rounding up.
        -- At early Bounty Board ranks the direct reward can be 0-1g, but the objective
        -- should still feel responsive and complete normally.
        Upgrades.advance_bounty_contract("kill", 1)
        if creature_level_value(dead) >= 6 then
            Upgrades.advance_bounty_contract("elite", 1)
        end
        if (Upgrades._bounty_recent_losses or 0) > 0 then
            Upgrades._bounty_recent_losses = math.max(0, (Upgrades._bounty_recent_losses or 0) - 1)
            Upgrades.advance_bounty_contract("revenge", 1)
        end

        local base_reward = combined_scaled_effect({ {2, 3}, {7, 1}, {8, 1}, {9, 1}, {10, 1}, {11, 1}, {12, 1}, {31, 4}, {33, 1}, {47, 3} })
        local raw_reward = base_reward * KILL_REWARD_SCALE * (1.0 + bounty_board_bonus() / 100) * (1.0 + rival_contract_bonus())
        local reward = math.min(MAX_SAFE_COST, math.floor(raw_reward + 0.5))
        if base_reward > 0 and Upgrades.get_rank(47) > 0 then reward = math.max(1, reward) end
        if reward > 0 then
            pcall(function() PLAYER0:add_gold(reward) end)
            Upgrades.add_upgrade_gold(reward)
        end
    elseif is_active_rival_player(killer) then
        local killer_idx = player_to_idx(killer)
        if killer_idx then
            local ranks = get_player_ai_ranks(killer)
            local reward = math.min(MAX_SAFE_COST, math.floor(ai_combined_scaled_effect(ranks, { {2, 3}, {7, 1}, {8, 1}, {9, 1}, {10, 1}, {11, 1}, {12, 1}, {31, 4}, {33, 1}, {47, 3} }) * KILL_REWARD_SCALE + 0.5))
            if reward > 0 then
                Upgrades.add_ai_upgrade_gold(killer_idx, reward)
            end
        end

        -- Trait abilities on kill
        -- Paladin: heals nearby allies when an ally falls
        if dead.owner ~= PLAYER0 and dead.owner ~= killer then
            local owner_idx = dead and player_to_idx(dead.owner)
            if owner_idx then
                local trait_name = get_rival_trait_name(owner_idx)
                if trait_name == "Paladin" and GetCreatures then
                    for _, ally in ipairs(GetCreatures() or {}) do
                        local same_owner = (ally.owner == dead.owner) or (dead.owner and dead.owner.playerId and ally.owner and ally.owner.playerId == dead.owner.playerId)
                        if same_owner and ally.health and ally.max_health then
                            pcall(function()
                                if ally.isValid and not ally:isValid() then return end
                                ally.health = math.min(ally.max_health, ally.health + 15)
                            end)
                        end
                    end
                end
            end
        end
        -- Shadow: steals gold from the player when it kills player creatures
        if dead.owner == PLAYER0 and is_owned_by_player0(dead) then
            local killer_trait = get_rival_trait_name(killer_idx)
            if killer_trait == "Shadow" and PLAYER0 and PLAYER0.MONEY then
                local stolen = math.min(50, tonumber(PLAYER0.MONEY) or 0)
                if stolen > 0 then
                    pcall(function() PLAYER0:add_gold(-stolen) end)
                    Upgrades.add_ai_upgrade_gold(killer_idx, stolen)
                end
            end
        end
    end
end

function Upgrades_OnShotHit(eventData)
    if not Upgrades or not PLAYER0 or not eventData then return end
    local shooter = eventData.shooter or eventData.Shooter or eventData.source or eventData.Source
    local target = eventData.target or eventData.Target or eventData.thing or eventData.Thing
    local shot = eventData.shot or eventData.Shot
    if not shooter or not is_owned_by_player0(shooter) or not target or is_owned_by_player0(target) then return end

    -- Kill-profile tracking: ranged attacks
    Upgrades._kill_profile = Upgrades._kill_profile or { trap=0, creature=0, spell=0, ranged=0 }
    Upgrades._kill_profile.ranged = (Upgrades._kill_profile.ranged or 0) + 1

    local shot_key = shot and shot.ThingIndex
    if shot_key then
        Upgrades._boosted_shots = Upgrades._boosted_shots or {}
        if Upgrades._boosted_shots[shot_key] then return end
        local turn = PLAYER0 and PLAYER0.GAME_TURN or 0
        Upgrades._boosted_shots[shot_key] = turn
        if (turn % 200) == 0 then
            for key, seen_turn in pairs(Upgrades._boosted_shots) do
                if (turn - (seen_turn or 0)) > 600 then
                    Upgrades._boosted_shots[key] = nil
                end
            end
        end
    end

    local bonus = math.max(0, math.floor(combined_scaled_effect({ {9, 1}, {33, 1} }) + 0.5))
    if bonus <= 0 then return end
    pcall(function()
        if target.isValid and not target:isValid() then return end
        if target.health and target.health > 0 then
            target.health = math.max(1, target.health - bonus)
        end
    end)
end

function Upgrades_ApplyGameplayEffects()
    if Upgrades and Upgrades.apply_gameplay_effects then
        pcall(Upgrades.apply_gameplay_effects)
    end
    if Upgrades and Upgrades.apply_rival_rolls then
        pcall(Upgrades.apply_rival_rolls)
    end
end

function Upgrades.check_procedural_synergy()
    local tab_ranks = {0,0,0,0,0,0}
    for id, r in pairs(Game.upgrades_ranks or {}) do
        local u = Upgrades._by_id[id]
        if u and u.tab then
            tab_ranks[u.tab] = tab_ranks[u.tab] + r
        end
    end
    
    local t1, t2 = 1, 2
    if tab_ranks[2] > tab_ranks[1] then
        t1, t2 = 2, 1
    end
    for i = 3, 6 do
        if tab_ranks[i] > tab_ranks[t1] then
            t2 = t1
            t1 = i
        elseif tab_ranks[i] > tab_ranks[t2] then
            t2 = i
        end
    end
    
    if tab_ranks[t1] > 20 and tab_ranks[t2] > 20 then
        Upgrades.procedural_synergy_tabs = {t1, t2}
    else
        Upgrades.procedural_synergy_tabs = nil
    end
end

function Upgrades_InflationDecay()
    if not Upgrades or not Upgrades.inflation then return end
    for id, v in pairs(Upgrades.inflation) do
        if v > 0 then Upgrades.inflation[id] = math.max(0, v - 0.0010) end
    end
    -- Decay mortality score so it doesn't permanently bias ROI
    if Upgrades._mortality_score and Upgrades._mortality_score > 0 then
        local turn = PLAYER0 and PLAYER0.GAME_TURN or 0
        local last_death = Upgrades._last_death_turn or 0
        -- Only decay if no deaths have occurred recently (within 5000 ticks)
        if turn - last_death > 5000 then
            Upgrades._mortality_score = math.max(0, Upgrades._mortality_score - 1)
        end
    end
end

function Upgrades_SilentSave()
    if Upgrades and Upgrades.save and Upgrades._dirty then
        local ok, err = pcall(Upgrades.save)
        if not ok then
            print("Upgrades: " .. tostring(err))
        end
    end
end

ai_buy_max = function(player)
    local p_idx = player_to_idx(player)
    if not p_idx then return end
    
    local gold = Upgrades.get_ai_upgrade_gold(p_idx)
    if gold <= 0 then return end
    
    local ranks = get_player_ai_ranks(player)
    local spent = 0
    local iterations = 0
    local MAX_ITER = 50
    local bought_something = false
    -- Per-rank inflation simulation: each rank purchased in this call adds 0.0010
    -- to the effective price scale, matching the player's inflation mechanic.
    local simulated_inflation = 0
    
    local available_ids = {}
    for _, u in ipairs(UPGRADES) do
        if type(u.hidden) ~= "function" then
            table.insert(available_ids, u.id)
        end
    end
    if #available_ids == 0 then return end

    local profile = make_ai_upgrade_profile(player == PLAYER_GOOD, player)

    -- Strategic saving: identify the best high-value upgrade and consider saving for it.
    -- If the best upgrade's ROI weight far exceeds the cheapest affordable ones,
    -- the AI should skip cheap buys and stockpile gold.
    local saving_goal_id, saving_goal_cost, saving_goal_weight = nil, math.huge, 0
    local cheapest_cost = math.huge
    for _, id in ipairs(available_ids) do
        local u = Upgrades._by_id[id]
        local rank = ranks[id] or 0
        local cost = safe_upgrade_cost(u.base, math.max(1.01, (tonumber(Upgrades.price_scale) or 1.15)), rank)
        if cost < cheapest_cost then cheapest_cost = cost end
        local w = ai_upgrade_roll_weight(id, profile, 0.45, 2.20) * (UPGRADE_STRENGTH_WEIGHTS[id] or 1.0)
        if w > saving_goal_weight and cost > gold * 0.5 then
            saving_goal_weight = w
            saving_goal_cost = cost
            saving_goal_id = id
        end
    end
    -- Only save if the target is significantly more impactful than cheap fillers
    local patience_threshold = 1.8  -- how many cheap purchases the goal must be worth
    local patience = saving_goal_id and (saving_goal_weight / math.max(1, saving_goal_cost)) > (1.0 / math.max(1, cheapest_cost)) * patience_threshold
    
    while iterations < MAX_ITER do
        iterations = iterations + 1
        
        local choices = {}
        local total_weight = 0
        local effective_scale = math.max(1.01, (tonumber(Upgrades.price_scale) or 1.15) * (1.0 + simulated_inflation))
        
        for _, id in ipairs(available_ids) do
            local u = Upgrades._by_id[id]
            local rank = ranks[id] or 0
            -- Use the inflation-adjusted effective scale so AI costs match
            -- what the player would pay for equivalent ranks.
            local cost = safe_upgrade_cost(u.base, effective_scale, rank)
            
            local w = ai_upgrade_roll_weight(id, profile, 0.45, 2.20)
            if math.random() < 0.10 then
                w = w * random_range(1.50, 3.50)
            end
            
            -- Intelligent Saving for AI Rivals: Include unaffordable options, but penalize them
            if cost > (gold - spent) then
                local ratio = math.max(1, gold - spent) / cost
                w = w * (ratio ^ 0.85)
            end

            choices[#choices + 1] = { id = id, cost = cost, weight = w }
            total_weight = total_weight + w
        end
        
        if #choices == 0 then break end
        
        local roll = math.random() * total_weight
        local selected = choices[#choices]
        local current = 0
        for _, choice in ipairs(choices) do
            current = current + choice.weight
            if roll <= current then
                selected = choice
                break
            end
        end
        
        if selected then
            if selected.cost > (gold - spent) then
                -- The best tactical choice is unaffordable. The AI will save up for it!
                break
            end
            
            -- Strategic patience: if saving for a high-value upgrade, skip cheap
            -- purchases that would delay reaching the goal.
            if patience and saving_goal_id and selected.id ~= saving_goal_id then
                local remaining = (gold - spent)
                if remaining + selected.cost >= saving_goal_cost * 0.85 then
                    -- Close to the goal: skip this purchase and save instead
                    break
                end
            end
            
            spent = spent + selected.cost
            ranks[selected.id] = (ranks[selected.id] or 0) + 1
            simulated_inflation = simulated_inflation + 0.0010
            bought_something = true
        end
    end
    
    if spent > 0 then
        deduct_ai_upgrade_gold(p_idx, spent)
        if bought_something then
            apply_rival_player_effects(player)
        end
    end
end

local function mark_auto_buy_startup_grace()
    local turn = math.max(0, tonumber(PLAYER0 and PLAYER0.GAME_TURN) or 0)
    local interval = math.max(1, tonumber(Upgrades.buymax_auto_interval) or 6000)
    Upgrades.buymax_auto_block_until_turn = turn + interval
end

function Upgrades_AutoBuyMax()
    if not Upgrades then return end
    local turn = math.max(0, tonumber(PLAYER0 and PLAYER0.GAME_TURN) or 0)
    if turn < (tonumber(Upgrades.buymax_auto_block_until_turn) or 0) then
        return
    end

    if Upgrades and GetCreatures then
        for _, p in ipairs(computer_player_list()) do
            if is_active_rival_player(p) then
                ai_buy_max(p)
            end
        end
    end

    if not Upgrades.buymax_auto_enabled then return end

    local purchases, spent = Upgrades.buy_max()
    if not purchases or spent <= 0 then
        if Upgrades._saving_for_id then
            local u = Upgrades._by_id[Upgrades._saving_for_id]
            local turn = (PLAYER0 and PLAYER0.GAME_TURN) or 0
            if u and (turn - (Upgrades._last_save_announce_turn or 0)) > 6000 then
                pcall(QuickMessage, "Auto Buy: Saving up for " .. upgrade_display_name(u) .. "...", "QUERY")
                Upgrades._last_save_announce_turn = turn
            end
        end
        return
    end

    local top_id, top_count, bought_total = nil, 0, 0
    for id, count in pairs(purchases) do
        bought_total = bought_total + count
        if count > top_count then
            top_id = id
            top_count = count
        end
    end

    local top_name = top_id and Upgrades._by_id[top_id] and upgrade_display_name(Upgrades._by_id[top_id]) or "Unknown"
    local top_str = top_id and (" (Top: " .. top_name .. " x" .. top_count .. ")") or ""
    pcall(QuickMessage, "Auto Buy: " .. tostring(bought_total) .. " ranks" .. top_str, "QUERY")
end

function Upgrades_AnnounceAutoBuyMax()
    if not Upgrades or not PLAYER0 or not Upgrades.buymax_auto_enabled then return end

    local turn = PLAYER0.GAME_TURN or 0
    if Upgrades.buymax_auto_announced_turn == turn then return end
    Upgrades.buymax_auto_announced_turn = turn

    if type(Upgrades.buymax_auto_startup_skip_announcement) == "number" and Upgrades.buymax_auto_startup_skip_announcement > 0 then
        Upgrades.buymax_auto_startup_skip_announcement = Upgrades.buymax_auto_startup_skip_announcement - 1
        return
    end

    pcall(QuickMessage, "Auto Buy ON: 5m adaptive ROI.", "QUERY")
end

-- ─────────────────────────────────────────────
-- Initialization
-- ─────────────────────────────────────────────

function Upgrades_OnChat(eventData) pcall(Upgrades.OnChat, eventData) end

function Upgrades_ApplyOnLoad()
    if Upgrades and Upgrades.apply_all then
        mark_auto_buy_startup_grace()
        Upgrades.apply_all()
        enforce_computer_creature_caps()
        Upgrades_ApplyRivalCreatureStats()
        Upgrades_AnnounceAutoBuyMax()
    end
end

function Upgrades.init()
    math.randomseed(os.time())
    math.random()
    math.random()

    Upgrades.load()
    mark_auto_buy_startup_grace()
    Upgrades.apply_all()
    enforce_computer_creature_caps()
    Upgrades_AnnounceAutoBuyMax()

    if CreateTrigger and not Upgrades.trigger_registered then
        pcall(CreateTrigger, "ChatMsg", "Upgrades_OnChat", {})
        pcall(CreateTrigger, "LevelUp", "Upgrades_OnLevelUp", {})
        pcall(CreateTrigger, "Death", "Upgrades_OnCreatureDeath", {})
        pcall(CreateTrigger, "PowerCast", "Upgrades_OnPowerCast", {})
        pcall(CreateTrigger, "ApplyDamage", "Upgrades_OnApplyDamage", {})
        pcall(CreateTrigger, "ShotHitThing", "Upgrades_OnShotHit", {})
        Upgrades.trigger_registered = true
    end

    if RegisterTimerEvent and not Upgrades.timer_registered then
        safe_call(RegisterTimerEvent, "Upgrades_ApplyOnLoad", 30, false)
        safe_call(RegisterTimerEvent, "Upgrades_ApplyOnLoad", 200, false)
        safe_call(RegisterTimerEvent, "Upgrades_InitRivals",              8,   false)
        safe_call(RegisterTimerEvent, "Upgrades_ApplyRivalCreatureStats", 250, true)
        safe_call(RegisterTimerEvent, "Upgrades_SilentSave", 300, true)
        safe_call(RegisterTimerEvent, "Upgrades_EconomyPulse", 200, true)
        safe_call(RegisterTimerEvent, "Upgrades_ProgressPulse", 100, true)
        safe_call(RegisterTimerEvent, "Upgrades_ApplyGameplayEffects", 100, true)
        safe_call(RegisterTimerEvent, "Upgrades_InflationDecay", 1000, true)
        safe_call(RegisterTimerEvent, "Upgrades_AutoBuyMax", Upgrades.buymax_auto_interval or 600, true)
        Upgrades.timer_registered = true
    end
end

_G.Upgrades = Upgrades
Upgrades.init()
return Upgrades
