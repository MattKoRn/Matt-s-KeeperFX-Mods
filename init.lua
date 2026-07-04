-- init.lua
-- Entry point for the full Lua API. Requires and assembles all core modules.
-- Recommended to be required by the engine or scripts that need full API access.

Game = Game or {}

require "core.serialisation"
require "triggers.Events"
require "triggers.Builtins"
require "triggers.TriggerSystem"
require "classes.Pos3d"
require "classes.Creature"
require "classes.Thing"
require "classes.Slab"
require "managers.CreatureManager"
require "managers.ThingManager"
require "managers.RoomManager"
require "gamelogic.ShotFunctions"
require "utils.Debug"
require "auto_camera"
require "offline_progress"
require "upgrades"
require "world_modifiers"
require "computer_dig_aggressive"
