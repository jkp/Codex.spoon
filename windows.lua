local Rect <const> = hs.geometry.rect
local Screen <const> = hs.screen
local Spaces <const> = hs.spaces
local Timer <const> = hs.timer
local Window <const> = hs.window

local Windows = {}
Windows.__index = Windows

-- Spoon reference (set by init)
local codex = nil

---@enum Direction
local Direction <const> = {
    LEFT = -1,
    RIGHT = 1,
    UP = -2,
    DOWN = 2,
    NEXT = 3,
    PREVIOUS = -3,
    WIDTH = 4,
    HEIGHT = 5,
    ASCENDING = 6,
    DESCENDING = 7,
}
Windows.Direction = Direction

---initialize module with reference to Codex
---@param spoon Codex
function Windows.init(spoon)
    codex = spoon
end

---return the first window that's completely on the screen
---@param space Space space to lookup windows
---@param screen_frame Frame the coordinates of the screen
---@pram direction Direction|nil either LEFT or RIGHT
---@return Window|nil
function Windows.getFirstVisibleWindow(space, screen_frame, direction)
    direction = direction or Direction.LEFT
    local on_screen_distance = math.huge
    local on_screen_closest = nil
    local off_screen_distance = -math.huge
    local off_screen_closest = nil

    for _, windows in ipairs(codex.state.windowList(space)) do
        local window = windows[1] -- take first window in column
        local d = (function()
            if direction == Direction.LEFT then
                return window:frame().x - screen_frame.x
            elseif direction == Direction.RIGHT then
                return screen_frame.x2 - window:frame().x2
            end
        end)() or math.huge
        if d >= 0 and d < on_screen_distance then
            on_screen_distance = d
            on_screen_closest = window
        end
        if d < 0 and d > off_screen_distance then
            off_screen_distance = d
            off_screen_closest = window
        end
    end

    return on_screen_closest or off_screen_closest
end

---get the gap value for the specified side
---@param side string "top", "bottom", "left", or "right"
---@return number gap size in pixels
function Windows.getGap(side)
    local gap = codex.window_gap
    if type(gap) == "number" then
        return gap            -- backward compatibility with single number
    elseif type(gap) == "table" then
        return gap[side] or 8 -- default to 8 if missing
    else
        return 8              -- fallback default
    end
end

---get the tileable bounds for a screen
---@param screen Screen
---@return Frame
function Windows.getCanvas(screen)
    local screen_frame = screen:frame()
    local screen_full_frame = screen:fullFrame()
    local left_gap = Windows.getGap("left")
    local right_gap = Windows.getGap("right")
    local top_gap = Windows.getGap("top")
    local bottom_gap = Windows.getGap("bottom")
    local external_bar = codex.external_bar
    local external_bar_top = external_bar and external_bar.top
    local external_bar_bottom = external_bar and external_bar.bottom
    local frame_top = external_bar_top and screen_full_frame.y + external_bar_top or screen_frame.y
    local frame_bottom = external_bar_bottom and screen_full_frame.y2 - external_bar_bottom or screen_frame.y2
    local frame_height = frame_bottom - frame_top

    return Rect(
        screen_frame.x + left_gap,
        frame_top + top_gap,
        screen_frame.w - (left_gap + right_gap),
        frame_height - (top_gap + bottom_gap)
    )
end

---get all windows across all spaces and retile them
function Windows.refreshWindows()
    local function _ms(t) return math.floor((hs.timer.absoluteTime() - t) / 1e6) end

    -- get all windows across spaces
    local _t = hs.timer.absoluteTime()
    local all_windows = codex.window_filter:getWindows()
    print(string.format("[refreshWindows] getWindows: %dms (%d wins)", _ms(_t), #all_windows))

    local retile_spaces = {} -- spaces that need to be retiled
    _t = hs.timer.absoluteTime()
    for _, window in ipairs(all_windows) do
        if codex.state.isHidden(window:id()) then goto continue end
        local index = codex.state.windowIndex(window)
        if codex.floating.isFloating(window) then
            -- ignore floating windows
        elseif not index then
            -- add window
            local space = Windows.addWindow(window)
            if space then retile_spaces[space] = true end
        elseif index.space ~= Spaces.windowSpaces(window)[1] then
            -- move to window list in new space, don't focus nearby window
            Windows.removeWindow(window, true)
            local space = Windows.addWindow(window)
            if space then retile_spaces[space] = true end
        end
        ::continue::
    end
    print(string.format("[refreshWindows] add loop: %dms", _ms(_t)))

    -- retile spaces
    _t = hs.timer.absoluteTime()
    for space, _ in pairs(retile_spaces) do codex:tileSpace(space) end
    print(string.format("[refreshWindows] tileSpace: %dms", _ms(_t)))
end

---add a new window to be tracked and automatically tiled
---@param add_window Window new window to be added
---@return Space|nil space that contains new window
function Windows.addWindow(add_window)
    -- don't add windows that are parked by virtual workspaces
    if add_window:id() and codex.state.isHidden(add_window:id()) then return end

    -- A window with no tabs will have a tabCount of 0 or 1
    -- A new tab for a window will have tabCount equal to the total number of tabs
    -- All existing tabs in a window will have their tabCount reset to 0
    -- We can't query whether an exiting hs.window is a tab or not after creation
    local apple <const> = "com.apple"
    local safari <const> = "com.apple.Safari"
    if add_window:tabCount() > 1
        and add_window:application():bundleID():sub(1, #apple) == apple
        and add_window:application():bundleID():sub(1, #safari) ~= safari then
        -- It's mostly built-in Apple apps like Finder and Terminal whose tabs
        -- show up as separate windows. Third party apps like Microsoft Office
        -- use tabs that are all contained within one window and tile fine.
        hs.notify.show("Codex", "Windows with tabs are not supported!",
            "See https://github.com/jkp/Codex.spoon/issues/39")
        return
    end

    -- ignore windows that have a zoom button, but are not maximizable
    if not add_window:isMaximizable() then
        codex.logger.d("ignoring non-maximizable window")
        return
    end

    -- check if window is already in window list
    if codex.state.windowIndex(add_window) then return end

    local space = Spaces.windowSpaces(add_window)[1]
    if not space then
        codex.logger.e("add window does not have a space")
        return
    end

    -- find where to insert window
    local add_column = 1

    -- when addWindow() is called from a window created event:
    -- focused_window from previous window focused event will not be add_window
    -- hs.window.focusedWindow() will return add_window
    -- new window focused event for add_window has not happened yet
    if codex.state.prev_focused_window and
        ((codex.state.windowIndex(codex.state.prev_focused_window) or {}).space == space) and
        (codex.state.prev_focused_window:id() ~= add_window:id()) then -- insert to the right
        add_column = codex.state.windowIndex(codex.state.prev_focused_window).col + 1
    else
        local x = add_window:frame().center.x
        for col, windows in ipairs(codex.state.windowList(space)) do
            if x < windows[1]:frame().center.x then
                add_column = col     -- insert left of window
                break                -- add_window will take this window's column
            else                     -- everything after insert column will be pushed right
                add_column = col + 1 -- insert right of window
            end
        end
    end

    -- add window
    table.insert(codex.state.windowList(space), add_column, { add_window })

    -- subscribe to window moved events
    codex.state.uiWatcherCreate(add_window)

    return space
end

---remove a window from being tracked and automatically tiled
---@param remove_window Window window to be removed
---@param skip_new_window_focus boolean|nil don't focus a nearby window if true
---@return Space|nil space that contained removed window
function Windows.removeWindow(remove_window, skip_new_window_focus)
    -- get index of window and remove
    local remove_index = codex.state.windowIndex(remove_window, true)
    if not remove_index then
        codex.logger.e("remove index not found")
        return
    end

    if not skip_new_window_focus then -- find nearby window to focus
        for _, direction in ipairs({
            Direction.DOWN, Direction.UP, Direction.LEFT, Direction.RIGHT,
        }) do if Windows.focusWindow(direction, remove_index) then break end end
    end

    -- remove window
    assert(remove_window == table.remove(
        codex.state.windowList(remove_index.space, remove_index.col), remove_index.row)
    )

    -- remove watcher
    codex.state.uiWatcherDelete(remove_window:id())

    -- clear window position
    codex.state.xPositions(remove_index.space)[remove_window:id()] = nil

    -- clear dangling reference
    if codex.state.prev_focused_window == remove_window then
        codex.state.prev_focused_window = nil
    end

    return remove_index.space -- return space for removed window
end

---move focus to a new window next to the currently focused window
---@param direction Direction use either Direction UP, DOWN, LEFT, or RIGHT
---@param focused_index Index index of focused window within the windowList
function Windows.focusWindow(direction, focused_index)
    if not focused_index then
        -- get current focused window
        local focused_window = Window.focusedWindow()
        if not focused_window then
            codex.logger.d("focused window not found")
            return
        end

        -- get focused window index
        focused_index = codex.state.windowIndex(focused_window)
    end

    if not focused_index then
        codex.logger.e("focused index not found")
        return
    end

    -- get new focused window
    local new_focused_window = nil
    if direction == Direction.LEFT or direction == Direction.RIGHT then
        -- walk down column, looking for match in neighbor column
        for row = focused_index.row, 1, -1 do
            new_focused_window = codex.state.windowList(focused_index.space, focused_index.col + direction, row)
            if new_focused_window then break end
        end
    elseif direction == Direction.UP or direction == Direction.DOWN then
        new_focused_window = codex.state.windowList(focused_index.space, focused_index.col,
            focused_index.row + (direction // 2))
    elseif direction == Direction.NEXT or direction == Direction.PREVIOUS then
        local diff = direction // Direction.NEXT -- convert to 1/-1
        local new_row_index = focused_index.row + diff

        -- first try above/below in same row
        new_focused_window = codex.state.windowList(focused_index.space, focused_index.col,
            focused_index.row + diff)

        if not new_focused_window then
            -- get the bottom row in the previous column, or the first row in the next column
            local adjacent_column = codex.state.windowList(focused_index.space, focused_index.col + diff)
            if adjacent_column then
                local col_idx = 1
                if diff < 0 then col_idx = #adjacent_column end
                new_focused_window = adjacent_column[col_idx]
            end
        end
    end

    if not new_focused_window then
        codex.logger.d("new focused window not found")
        return
    end

    -- focus new window, windowFocused event will be emited immediately
    new_focused_window:focus()

    -- try to prevent MacOS from stealing focus away to another window
    Timer.doAfter(Window.animationDuration, function()
        if Window.focusedWindow() ~= new_focused_window then
            codex.logger.df("refocusing window %s", new_focused_window)
            new_focused_window:focus()
        end
    end)

    return new_focused_window
end

---focus a window at a specified position
---@param n number window number from left to right and up to down on the current screen
function Windows.focusWindowAt(n)
    local screen = Screen.mainScreen()
    local space = Spaces.activeSpaces()[screen:getUUID()]
    local columns = codex.state.windowList(space)
    if #columns == 0 then return end

    local i = 1
    for col = 1, #columns do
        local column = columns[col]
        for row = 1, #column do
            if i == n then
                column[row]:focus()
                return
            end
            i = i + 1
        end
    end
end

---swap the focused window with a window next to it
---if swapping horizontally and the adjacent window is in a column, swap the
---entire column. if swapping vertically and the focused window is in a column,
---swap positions within the column
---@param direction Direction use Direction LEFT, RIGHT, UP, or DOWN
function Windows.swapWindows(direction)
    local focused_window = Window.focusedWindow()
    if not focused_window then
        codex.logger.d("focused window not found")
        return
    end

    local focused_index = codex.state.windowIndex(focused_window)
    if not focused_index then
        codex.logger.e("focused index not found")
        return
    end

    if direction == Direction.LEFT or direction == Direction.RIGHT then
        local columns = codex.state.windowList(focused_index.space)
        if not columns then
            codex.logger.ef("no windows on space %d", focused_index.space)
            return
        end

        local current_column = focused_index.col
        if not columns[current_column] then
            codex.logger.ef("no current column %d on space %d", current_column, focused_index.space)
            return
        end

        local target_column = focused_index.col + direction
        if not columns[target_column] then
            codex.logger.ef("no target column %d on space %d", target_column, focused_index.space)
            return
        end

        -- move focused window to target column location
        local focused_frame = focused_window:frame()
        local target_frame = columns[target_column][1]:frame()
        focused_frame.x = target_frame.x
        Windows.moveWindow(focused_window, focused_frame)

        -- remove then insert column of windows to swap
        local windows = table.remove(columns, current_column)
        table.insert(columns, target_column, windows)
    elseif direction == Direction.UP or direction == Direction.DOWN then
        local windows = codex.state.windowList(focused_index.space, focused_index.col)
        if not windows then
            codex.logger.ef("no windows in column %d on space %d", focused_index.col, focused_index.space)
            return
        end

        local current_row = focused_index.row
        local target_row = focused_index.row + (direction // 2)

        -- remove and insert to swap
        local window = table.remove(windows, current_row)
        table.insert(windows, target_row, window)
    end

    -- update layout
    codex:tileSpace(focused_index.space)
end

---move the focused window to the center of the screen, horizontally
---don't resize the window or change it's vertical position
function Windows.centerWindow()
    -- get current focused window
    local focused_window = Window.focusedWindow()
    if not focused_window then
        codex.logger.d("focused window not found")
        return
    end

    -- get global coordinates
    local focused_frame = focused_window:frame()
    local screen_frame = focused_window:screen():frame()

    -- center window
    focused_frame.x = screen_frame.x + (screen_frame.w // 2) -
        (focused_frame.w // 2)
    Windows.moveWindow(focused_window, focused_frame)

    -- update layout
    local space = Spaces.windowSpaces(focused_window)[1]
    codex:tileSpace(space)
end

---set the focused window to the width of the screen and cache the original width
---restore the original window size if called again, don't change the height
function Windows.toggleWindowFullWidth()
    local width_cache = {}
    return function(self)
        -- get current focused window
        local focused_window = Window.focusedWindow()
        if not focused_window then
            self.logger.d("focused window not found")
            return
        end

        local canvas = Windows.getCanvas(focused_window:screen())
        local focused_frame = focused_window:frame()
        local id = focused_window:id()

        local width = width_cache[id]
        if width then
            -- restore window width
            focused_frame.x = canvas.x + ((canvas.w - width) / 2)
            focused_frame.w = width
            width_cache[id] = nil
        else
            -- set window to fullscreen width
            width_cache[id] = focused_frame.w
            focused_frame.x, focused_frame.w = canvas.x, canvas.w
        end

        -- update layout
        Windows.moveWindow(focused_window, focused_frame)
        local space = Spaces.windowSpaces(focused_window)[1]
        codex:tileSpace(space)
    end
end

---find the next window size in the cycle for a given dimension
---@param area_size number available area size (canvas width or height)
---@param frame_size number current window size in the dimension
---@param cycle_dir Direction ASCENDING or DESCENDING
---@param dimension Direction WIDTH or HEIGHT
---@return number|nil new size
local function findNewSize(area_size, frame_size, cycle_dir, dimension)
    local gap = (dimension == Direction.WIDTH)
        and (Windows.getGap("left") + Windows.getGap("right")) / 2
        or (Windows.getGap("top") + Windows.getGap("bottom")) / 2

    local sizes = {}
    for i, ratio in ipairs(codex.window_ratios) do
        sizes[i] = ratio * (area_size + gap) - gap
    end

    if cycle_dir == Direction.ASCENDING then
        for _, size in ipairs(sizes) do
            if size > frame_size + 10 then return size end
        end
        return sizes[1]
    elseif cycle_dir == Direction.DESCENDING then
        for i = #sizes, 1, -1 do
            if sizes[i] < frame_size - 10 then return sizes[i] end
        end
        return sizes[#sizes]
    end

    codex.logger.e("cycle_direction must be either Direction.ASCENDING or Direction.DESCENDING")
    return nil
end

---resize the width or height of the window, keeping the other dimension the
---same. cycles through the ratios specified in Codex.window_ratios
---@param direction Direction use Direction.WIDTH or Direction.HEIGHT
---@param cycle_direction Direction use Direction.ASCENDING or DESCENDING
function Windows.cycleWindowSize(direction, cycle_direction)
    -- get current focused window
    local focused_window = Window.focusedWindow()
    if not focused_window then
        codex.logger.d("focused window not found")
        return
    end

    local canvas = Windows.getCanvas(focused_window:screen())
    local focused_frame = focused_window:frame()

    if direction == Direction.WIDTH then
        local new_width = findNewSize(canvas.w, focused_frame.w, cycle_direction, Direction.WIDTH)
        focused_frame.x = focused_frame.x + ((focused_frame.w - new_width) // 2)
        focused_frame.w = new_width
    elseif direction == Direction.HEIGHT then
        local new_height = findNewSize(canvas.h, focused_frame.h, cycle_direction, Direction.HEIGHT)
        focused_frame.y = math.max(canvas.y,
            focused_frame.y + ((focused_frame.h - new_height) // 2))
        focused_frame.h = new_height
        focused_frame.y = focused_frame.y -
            math.max(0, focused_frame.y2 - canvas.y2)
    else
        codex.logger.e(
            "direction must be either Direction.WIDTH or Direction.HEIGHT")
        return
    end

    -- apply new size
    Windows.moveWindow(focused_window, focused_frame)

    -- update layout
    local space = Spaces.windowSpaces(focused_window)[1]
    codex:tileSpace(space)
end

---resize the focused window in a direction by scale amount
---@param direction Direction Direction.WIDTH or Direction.HEIGHT
---@param scale number the percent to change the window size by
function Windows.increaseWindowSize(direction, scale)
    -- get current focused window
    local focused_window = Window.focusedWindow()
    if not focused_window then
        codex.logger.d("focused window not found")
        return
    end

    local canvas = Windows.getCanvas(focused_window:screen())
    local focused_frame = focused_window:frame()

    if direction == Direction.WIDTH then
        local diff = canvas.w * 0.1 * scale
        local new_size = math.max(diff, math.min(canvas.w, focused_frame.w + diff))

        focused_frame.w = new_size
        focused_frame.x = focused_frame.x + ((focused_frame.w - new_size) // 2)
    elseif direction == Direction.HEIGHT then
        local diff = canvas.h * 0.1 * scale
        local new_size = math.max(diff, math.min(canvas.h, focused_frame.h + diff))

        focused_frame.h = new_size
        focused_frame.y = focused_frame.y -
            math.max(0, focused_frame.y2 - canvas.y2)
    end

    -- apply new size
    Windows.moveWindow(focused_window, focused_frame)

    -- update layout
    local space = Spaces.windowSpaces(focused_window)[1]
    codex:tileSpace(space)
end

---tile a column of windows so they each have an equal height
---@param windows Window[]
local function tile_column_equaly(windows)
    -- final column frames should be equal in height
    local first_window = windows[1]
    local num_windows = #windows
    local canvas = Windows.getCanvas(first_window:screen())
    local bottom_gap = Windows.getGap("bottom")
    local bounds = {
        x = first_window:frame().x,
        x2 = nil,
        y = canvas.y,
        y2 = canvas.y2,
    }
    local h = math.max(0, canvas.h - ((num_windows - 1) * bottom_gap)) // num_windows
    codex.tiling.tileColumn(windows, bounds, h)
end

---take the current focused window and move it into the bottom of
---the column to the left
function Windows.slurpWindow()
    -- get current focused window
    local focused_window = Window.focusedWindow()
    if not focused_window then
        codex.logger.d("focused window not found")
        return
    end

    -- get window index
    local focused_index = codex.state.windowIndex(focused_window)
    if not focused_index then
        codex.logger.e("focused index not found")
        return
    end

    -- get current column
    local current_column = codex.state.windowList(focused_index.space, focused_index.col)
    if not current_column then
        codex.logger.ef("current column %d not found on space %d", focused_index.col, focused_index.space)
        return
    end

    -- get column to left
    local target_index = focused_index.col - 1
    local target_column = codex.state.windowList(focused_index.space, target_index)
    if not target_column then
        codex.logger.df("target column %d not found on space %d", target_index, focused_index.space)
        return
    end

    -- remove window and append to end of target column
    assert(focused_window == table.remove(current_column, focused_index.row))
    table.insert(target_column, focused_window)

    -- final column frames should be equal in height
    local final_column = codex.state.windowList(focused_index.space, target_index)
    tile_column_equaly(final_column)

    -- update layout
    codex:tileSpace(focused_index.space)
end

---remove focused window from it's current column and place into
---a new column to the right
function Windows.barfWindow()
    -- get current focused window
    local focused_window = Window.focusedWindow()
    if not focused_window then
        codex.logger.d("focused window not found")
        return
    end

    -- get window index
    local focused_index = codex.state.windowIndex(focused_window)
    if not focused_index then
        codex.logger.e("focused index not found")
        return
    end

    -- get column
    local current_column = codex.state.windowList(focused_index.space, focused_index.col)
    if not current_column then
        codex.logger.ef("current column %d not found on space %d", focused_index.col, focused_index.space)
        return
    elseif #current_column == 1 then
        codex.logger.d("only window in column")
        return
    end

    -- remove window and insert in new column
    local target_column = focused_index.col + 1
    assert(focused_window == table.remove(current_column, focused_index.row))
    table.insert(codex.state.windowList(focused_index.space), target_column, { focused_window })

    -- move focused window to target column location
    local focused_frame = focused_window:frame()
    focused_frame.x = focused_frame.x2 + Windows.getGap("right")
    Windows.moveWindow(focused_window, focused_frame)

    -- remaining column frames should be equal in height
    local final_column = codex.state.windowList(focused_index.space, focused_index.col)
    tile_column_equaly(final_column)

    -- update layout
    codex:tileSpace(focused_index.space)
end

---move and resize a window to the coordinates specified by the frame
---disable watchers while window is moving and re-enable after
---@param window Window window to move
---@param frame Frame coordinates to set window size and location
function Windows.moveWindow(window, frame)
    -- greater than 0.017 hs.window animation step time
    local padding <const> = 0.02
    local id = window:id()

    -- don't reposition windows parked by virtual workspaces
    if id and codex.state.isHidden(id) then return end

    if frame == window:frame() then
        codex.logger.v("no change in window frame")
        return
    end

    codex.state.uiWatcherStop(id)
    window:setFrame(frame)
    Timer.doAfter(Window.animationDuration + padding, function()
        codex.state.uiWatcherStart(id)
    end)
end

return Windows
