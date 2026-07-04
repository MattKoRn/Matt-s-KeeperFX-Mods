# KeeperFX Mod Notes

These Lua scripts run inside KeeperFX. Game callbacks, player objects, and configuration functions are provided by that runtime.

## Editing checklist

- Keep changes small and focused.
- Preserve defensive guards around optional runtime APIs.
- Avoid committing generated `.dat`, `.log`, or save files.
- Check scripts in-game after logic changes.
- For `quality_of_life.lua`, verify the minute heartbeat registers once, the low-gold stipend does not repeat more than three times per session, and active-play Upgrade Gold trickle remains conservative.
