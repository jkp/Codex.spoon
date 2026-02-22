local Fnutils <const> = hs.fnutils

local Actions = {}
Actions.__index = Actions

-- Spoon reference (set by init)
local codex = nil

---initialize modules with reference to Codex
---@param spoon Codex
function Actions.init(spoon)
    codex = spoon
end

---supported window movement actions
function Actions.actions()
    local Direction = codex.windows.Direction
    return {
        start_events = Fnutils.partial(codex.start, codex),
        stop_events = Fnutils.partial(codex.stop, codex),
        refresh_windows = codex.windows.refreshWindows,
        dump_state = codex.state.dump,
        toggle_floating = codex.floating.toggleFloating,
        focus_floating = codex.floating.focusFloating,
        focus_left = Fnutils.partial(codex.windows.focusWindow, Direction.LEFT),
        focus_right = Fnutils.partial(codex.windows.focusWindow, Direction.RIGHT),
        focus_up = Fnutils.partial(codex.windows.focusWindow, Direction.UP),
        focus_down = Fnutils.partial(codex.windows.focusWindow, Direction.DOWN),
        focus_prev = Fnutils.partial(codex.windows.focusWindow, Direction.PREVIOUS),
        focus_next = Fnutils.partial(codex.windows.focusWindow, Direction.NEXT),
        swap_left = Fnutils.partial(codex.windows.swapWindows, Direction.LEFT),
        swap_right = Fnutils.partial(codex.windows.swapWindows, Direction.RIGHT),
        swap_up = Fnutils.partial(codex.windows.swapWindows, Direction.UP),
        swap_down = Fnutils.partial(codex.windows.swapWindows, Direction.DOWN),
        center_window = codex.windows.centerWindow,
        full_width = codex.windows.toggleWindowFullWidth(),
        increase_width = Fnutils.partial(codex.windows.increaseWindowSize, Direction.WIDTH, 1),
        decrease_width = Fnutils.partial(codex.windows.increaseWindowSize, Direction.WIDTH, -1),
        increase_height = Fnutils.partial(codex.windows.increaseWindowSize, Direction.HEIGHT, 1),
        decrease_height = Fnutils.partial(codex.windows.increaseWindowSize, Direction.HEIGHT, -1),
        cycle_width = Fnutils.partial(codex.windows.cycleWindowSize, Direction.WIDTH, Direction.ASCENDING),
        cycle_height = Fnutils.partial(codex.windows.cycleWindowSize, Direction.HEIGHT, Direction.ASCENDING),
        reverse_cycle_width = Fnutils.partial(codex.windows.cycleWindowSize, Direction.WIDTH,
            Direction.DESCENDING),
        reverse_cycle_height = Fnutils.partial(codex.windows.cycleWindowSize, Direction.HEIGHT,
            Direction.DESCENDING),
        slurp_in = codex.windows.slurpWindow,
        barf_out = codex.windows.barfWindow,
        switch_space_l = Fnutils.partial(codex.space.incrementSpace, Direction.LEFT),
        switch_space_r = Fnutils.partial(codex.space.incrementSpace, Direction.RIGHT),
        switch_space_1 = Fnutils.partial(codex.space.switchToSpace, 1),
        switch_space_2 = Fnutils.partial(codex.space.switchToSpace, 2),
        switch_space_3 = Fnutils.partial(codex.space.switchToSpace, 3),
        switch_space_4 = Fnutils.partial(codex.space.switchToSpace, 4),
        switch_space_5 = Fnutils.partial(codex.space.switchToSpace, 5),
        switch_space_6 = Fnutils.partial(codex.space.switchToSpace, 6),
        switch_space_7 = Fnutils.partial(codex.space.switchToSpace, 7),
        switch_space_8 = Fnutils.partial(codex.space.switchToSpace, 8),
        switch_space_9 = Fnutils.partial(codex.space.switchToSpace, 9),
        move_window_1 = Fnutils.partial(codex.space.moveWindowToSpace, 1),
        move_window_2 = Fnutils.partial(codex.space.moveWindowToSpace, 2),
        move_window_3 = Fnutils.partial(codex.space.moveWindowToSpace, 3),
        move_window_4 = Fnutils.partial(codex.space.moveWindowToSpace, 4),
        move_window_5 = Fnutils.partial(codex.space.moveWindowToSpace, 5),
        move_window_6 = Fnutils.partial(codex.space.moveWindowToSpace, 6),
        move_window_7 = Fnutils.partial(codex.space.moveWindowToSpace, 7),
        move_window_8 = Fnutils.partial(codex.space.moveWindowToSpace, 8),
        move_window_9 = Fnutils.partial(codex.space.moveWindowToSpace, 9),
        focus_window_1 = Fnutils.partial(codex.windows.focusWindowAt, 1),
        focus_window_2 = Fnutils.partial(codex.windows.focusWindowAt, 2),
        focus_window_3 = Fnutils.partial(codex.windows.focusWindowAt, 3),
        focus_window_4 = Fnutils.partial(codex.windows.focusWindowAt, 4),
        focus_window_5 = Fnutils.partial(codex.windows.focusWindowAt, 5),
        focus_window_6 = Fnutils.partial(codex.windows.focusWindowAt, 6),
        focus_window_7 = Fnutils.partial(codex.windows.focusWindowAt, 7),
        focus_window_8 = Fnutils.partial(codex.windows.focusWindowAt, 8),
        focus_window_9 = Fnutils.partial(codex.windows.focusWindowAt, 9),
    }
end

---bind userdefined hotkeys to Codex actions
---use Codex.default_hotkeys for suggested defaults
---@param mapping Mapping table of actions and hotkeys
function Actions.bindHotkeys(mapping)
    local spec = Actions.actions()
    hs.spoons.bindHotkeysToSpec(spec, mapping)
end

return Actions
