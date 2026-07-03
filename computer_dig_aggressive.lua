-- computer_dig_aggressive.lua
-- Makes PLAYER0 auto-dig toward
-- hero fortress hearts, rival keeper hearts, hero gates, and the lord of the land.
-- Hooks into the game tick system via periodic ComputerDigToLocation commands.

ComputerDigAggressive = ComputerDigAggressive or {}

-- How often to issue dig orders (20 ticks = 1 second).
ComputerDigAggressive.INTERVAL = 3000
-- Dig toward rival keeper hearts too
ComputerDigAggressive.DIG_TO_RIVAL_KEEPERS = true
-- Try to find hero gates to dig toward
ComputerDigAggressive.DIG_TO_HERO_GATES = true

ComputerDigAggressive.initialized = ComputerDigAggressive.initialized or false
ComputerDigAggressive.last_turn_run = ComputerDigAggressive.last_turn_run or 0

local function is_player_alive(player)
    if not player then return false end
    if player.DUNGEON_DESTROYED and player.DUNGEON_DESTROYED >= 1 then return false end
    return true
end

local function has_dungeon_heart(player)
    if not player then return false end
    if player.heart == nil or player.heart == 0 then return false end
    return true
end

local function get_targets_for(digger)
    local targets = {}
    if PLAYER_GOOD and is_player_alive(PLAYER_GOOD) then
        table.insert(targets, PLAYER_GOOD)
    end
    if ComputerDigAggressive.DIG_TO_RIVAL_KEEPERS then
        local rivals = {PLAYER1,PLAYER2,PLAYER3,PLAYER4,PLAYER5,PLAYER6,PLAYER7,PLAYER8,PLAYER9}
        for _, rival in ipairs(rivals) do
            if rival ~= digger and is_player_alive(rival) and has_dungeon_heart(rival) then
                table.insert(targets, rival)
            end
        end
    end
    if ComputerDigAggressive.DIG_TO_HERO_GATES then
        local ok, things = pcall(GetThingsOfClass, "Object")
        if ok and things then
            for _, thing in ipairs(things) do
                if thing.model == "HERO_GATE" and thing.stl_x and thing.stl_y then
                    table.insert(targets, {stl_x=thing.stl_x, stl_y=thing.stl_y, is_location=true})
                end
            end
        end
    end
    return targets
end

function ComputerDigAggressive_OnTick(eventData, triggerData)
    local current_turn = 0
    if PLAYER0 and PLAYER0.GAME_TURN then current_turn = PLAYER0.GAME_TURN end
    if current_turn == ComputerDigAggressive.last_turn_run then return end
    ComputerDigAggressive.last_turn_run = current_turn
    if not is_player_alive(PLAYER0) then return end
    local targets = get_targets_for(PLAYER0)
    if #targets == 0 then return end
    for _, target in ipairs(targets) do
        local ok, err
        if type(target) == "table" and target.is_location then
            ok, err = pcall(ComputerDigToLocation, PLAYER0, PLAYER0, target.stl_x)
        else
            ok, err = pcall(ComputerDigToLocation, PLAYER0, PLAYER0, target)
        end
        if ok then break end
    end
end

function ComputerDigAggressive_Init()
    if ComputerDigAggressive.initialized then return end
    if not RegisterTimerEvent then return end
    if not ComputerDigToLocation then return end
    local ok, err = pcall(RegisterTimerEvent, "ComputerDigAggressive_OnTick", ComputerDigAggressive.INTERVAL, true)
    if ok then
        ComputerDigAggressive.initialized = true
    end
end

ComputerDigAggressive_Init()
