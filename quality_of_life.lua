-- quality_of_life.lua
-- Lightweight in-game polish hooks for KeeperFX sessions.
-- Keeps bonuses conservative, defensive, and optional-API safe.

QualityOfLife = QualityOfLife or {}
QualityOfLife.version = "v1-safe-session-polish"
QualityOfLife.enabled = true
QualityOfLife.timer_registered = QualityOfLife.timer_registered or false
QualityOfLife.heartbeat_interval_ticks = 1200 -- once per minute at 20 ticks/sec
QualityOfLife.last_heartbeat_turn = QualityOfLife.last_heartbeat_turn or -1
QualityOfLife.last_low_gold_turn = QualityOfLife.last_low_gold_turn or -1
QualityOfLife.low_gold_cooldown_ticks = 6000
QualityOfLife.low_gold_threshold = 750
QualityOfLife.low_gold_grant = 250
QualityOfLife.low_gold_max_grants = 3
QualityOfLife.low_gold_grants_used = QualityOfLife.low_gold_grants_used or 0

local function safe_call(fn, ...)
    if type(fn) ~= "function" then return false end
    local ok, err = pcall(fn, ...)
    if not ok then
        print("QualityOfLife: " .. tostring(err))
        return false
    end
    return true
end

local function show_message(message)
    if type(QuickMessage) == "function" then
        safe_call(QuickMessage, message, "SPELL")
    else
        print("QualityOfLife: " .. tostring(message))
    end
end

local function current_turn()
    return (PLAYER0 and tonumber(PLAYER0.GAME_TURN)) or 0
end

function QualityOfLife.has_player()
    return PLAYER0 ~= nil
end

function QualityOfLife.get_gold()
    return math.max(0, math.floor(tonumber((PLAYER0 and PLAYER0.MONEY) or 0) or 0))
end

function QualityOfLife.add_gold(amount)
    if not PLAYER0 then return false end
    local value = math.floor(tonumber(amount) or 0)
    if value == 0 then return false end
    if type(PLAYER0.add_gold) == "function" then
        return safe_call(function() PLAYER0:add_gold(value) end)
    end
    return false
end

function QualityOfLife.low_gold_safety_net()
    if not QualityOfLife.has_player() then return end
    if QualityOfLife.low_gold_grants_used >= QualityOfLife.low_gold_max_grants then return end

    local turn = current_turn()
    if QualityOfLife.last_low_gold_turn >= 0 and turn - QualityOfLife.last_low_gold_turn < QualityOfLife.low_gold_cooldown_ticks then
        return
    end

    local gold = QualityOfLife.get_gold()
    if gold > QualityOfLife.low_gold_threshold then return end

    if QualityOfLife.add_gold(QualityOfLife.low_gold_grant) then
        QualityOfLife.low_gold_grants_used = QualityOfLife.low_gold_grants_used + 1
        QualityOfLife.last_low_gold_turn = turn
        show_message("Keeper safety stipend: +" .. tostring(QualityOfLife.low_gold_grant) .. " gold.")
    end
end

function QualityOfLife.sync_upgrade_gold_trickle()
    -- Tiny drip reward for active play. It nudges progression without competing with offline rewards or upgrades.
    if not Upgrades or type(Upgrades.add_upgrade_gold) ~= "function" then return end
    local creatures = math.max(0, tonumber((PLAYER0 and PLAYER0.TOTAL_CREATURES) or 0) or 0)
    local rooms = math.max(0, tonumber((PLAYER0 and PLAYER0.TOTAL_ROOMS) or 0) or 0)
    local drip = math.min(25, math.floor(1 + creatures * 0.15 + rooms * 0.10))
    if drip > 0 then
        safe_call(Upgrades.add_upgrade_gold, drip)
        if type(Upgrades.save) == "function" then safe_call(Upgrades.save) end
    end
end

function QualityOfLife.heartbeat()
    if not QualityOfLife.enabled or not QualityOfLife.has_player() then return end
    local turn = current_turn()
    if QualityOfLife.last_heartbeat_turn == turn then return end
    QualityOfLife.last_heartbeat_turn = turn

    QualityOfLife.low_gold_safety_net()
    QualityOfLife.sync_upgrade_gold_trickle()
end

function QualityOfLife_Heartbeat()
    if QualityOfLife and QualityOfLife.heartbeat then
        QualityOfLife.heartbeat()
    end
end

function QualityOfLife.ensure_registered()
    if QualityOfLife.timer_registered or not RegisterTimerEvent then return end
    RegisterTimerEvent("QualityOfLife_Heartbeat", QualityOfLife.heartbeat_interval_ticks, true)
    QualityOfLife.timer_registered = true
end

function QualityOfLife.init()
    QualityOfLife.ensure_registered()
end

_G.QualityOfLife = QualityOfLife
QualityOfLife.init()
return QualityOfLife