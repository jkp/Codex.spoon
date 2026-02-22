local Window <const> = hs.window
local Screen <const> = hs.screen
local Spaces <const> = hs.spaces

local Tiling = {}
Tiling.__index = Tiling

-- Spoon reference (set by init)
local codex = nil

---initialize module with reference to Codex
---@param spoon Codex
function Tiling.init(spoon)
    codex = spoon
end

---update the virtual x position for a table of windows on the specified space
---@param space Space
---@param windows Window[]
local function update_virtual_positions(space, windows, x)
    local x_positions = codex.state.xPositions(space)
    for _, window in ipairs(windows) do
        x_positions[window:id()] = x
    end
end

---tile a column of window by moving and resizing
---@param windows Window[] column of windows
---@param bounds Frame bounds to constrain column of tiled windows
---@param h number|nil set windows to specified height
---@param w number|nil set windows to specified width
---@param id number|nil id of window to set specific height
---@param h4id number|nil specific height for provided window id
---@return number width of tiled column
function Tiling.tileColumn(windows, bounds, h, w, id, h4id)
    local last_window, frame
    local bottom_gap = codex.windows.getGap("bottom")

    for _, window in ipairs(windows) do
        frame = window:frame()
        w = w or frame.w -- take given width or width of first window
        if bounds.x then -- set either left or right x coord
            frame.x = bounds.x
        elseif bounds.x2 then
            frame.x = bounds.x2 - w
        end
        if h then              -- set height if given
            if id and h4id and window:id() == id then
                frame.h = h4id -- use this height for window with id
            else
                frame.h = h    -- use this height for all other windows
            end
        end
        frame.y = bounds.y
        frame.w = w
        frame.y2 = math.min(frame.y2, bounds.y2) -- don't overflow bottom of bounds
        codex.windows.moveWindow(window, frame)
        bounds.y = math.min(frame.y2 + bottom_gap, bounds.y2)
        last_window = window
    end
    -- expand last window height to bottom
    if frame.y2 ~= bounds.y2 then
        frame.y2 = bounds.y2
        codex.windows.moveWindow(last_window, frame)
    end
    return w -- return width of column
end

---tile all column in a space by moving and resizing windows
---@param space Space
function Tiling.tileSpace(space)
    if not space or Spaces.spaceType(space) ~= "user" then
        codex.logger.e("current space invalid")
        return
    end

    -- find screen for space
    local screen = Screen(Spaces.spaceDisplay(space))
    if not screen then
        codex.logger.e("no screen for space")
        return
    end

    -- if focused window is in space, tile from that
    local focused_window = Window.focusedWindow()
    local anchor_window = (function()
        if focused_window and not codex.floating.isFloating(focused_window) and Spaces.windowSpaces(focused_window)[1] == space then
            return focused_window
        else
            return codex.windows.getFirstVisibleWindow(space, screen:frame())
        end
    end)()

    if not anchor_window then
        codex.logger.e("no anchor window in space")
        return
    end

    local anchor_index = codex.state.windowIndex(anchor_window)
    if not anchor_index then
        codex.logger.e("anchor index not found, refreshing windows")
        codex.windows.refreshWindows() -- try refreshing the windows
        return                                  -- bail
    end

    -- get some global coordinates
    local screen_frame <const> = screen:frame()
    local left_margin <const> = screen_frame.x + codex.screen_margin
    local right_margin <const> = screen_frame.x2 - codex.screen_margin
    local canvas <const> = codex.windows.getCanvas(screen)

    -- position anchor window on screen
    local anchor_frame = anchor_window:frame()
    anchor_frame.w = math.min(anchor_frame.w, canvas.w)
    anchor_frame.h = math.min(anchor_frame.h, canvas.h)

    local columns = codex.state.windowList(space)
    local num_cols = #columns

    if codex.right_anchor_last and anchor_index.col == num_cols and num_cols > 1 then
        -- Last column: right-anchor
        anchor_frame.x = canvas.x2 - anchor_frame.w
    elseif anchor_index.col > 1 and codex.sticky_pairs then
        -- Determine if anchor was left-anchored: check scroll direction first,
        -- then fall back to saved x_position (survives workspace switches)
        local prev = codex.state.prev_prev_focused_window
        local prev_index = prev and codex.state.windowIndex(prev)
        local scrolled_left = prev_index
            and prev_index.space == anchor_index.space
            and prev_index.col > anchor_index.col
        if not scrolled_left and not prev_index then
            local saved_x = codex.state.xPositions(space)[anchor_window:id()]
            scrolled_left = saved_x and saved_x == canvas.x
        end

        if scrolled_left then
            -- Scrolled left: left-anchor to maintain continuity with right neighbor
            anchor_frame.x = canvas.x
        else
            -- Default/scrolled right: shift right to show left neighbor
            local left_col = columns[anchor_index.col - 1]
            local left_w = left_col[1]:frame().w
            local left_gap = codex.windows.getGap("left")
            if left_w + left_gap + anchor_frame.w <= canvas.w then
                anchor_frame.x = canvas.x + left_w + left_gap
            else
                anchor_frame.x = canvas.x
            end
        end
    else
        -- First column or only column: left-anchor
        anchor_frame.x = canvas.x
    end
    anchor_frame.x2 = anchor_frame.x + anchor_frame.w

    -- adjust anchor window column
    local column = codex.state.windowList(space, anchor_index.col)
    if not column then
        codex.logger.e("no anchor window column")
        return
    end

    if #column == 1 then
        anchor_frame.y, anchor_frame.h = canvas.y, canvas.h
        codex.windows.moveWindow(anchor_window, anchor_frame)
    else
        local n = #column - 1 -- number of other windows in column
        local bottom_gap = codex.windows.getGap("bottom")
        local h =
            math.max(0, canvas.h - anchor_frame.h - (n * bottom_gap)) // n
        local bounds = {
            x = anchor_frame.x,
            x2 = nil,
            y = canvas.y,
            y2 = canvas.y2,
        }
        Tiling.tileColumn(column, bounds, h, anchor_frame.w, anchor_window:id(), anchor_frame.h)
    end
    update_virtual_positions(space, column, anchor_frame.x)

    local right_gap = codex.windows.getGap("right")
    local left_gap = codex.windows.getGap("left")

    -- tile windows from anchor right
    local x = anchor_frame.x2 + right_gap
    for col = anchor_index.col + 1, #(codex.state.windowList(space)) do
        local bounds = {
            x = math.min(x, right_margin),
            x2 = nil,
            y = canvas.y,
            y2 = canvas.y2,
        }
        local column = codex.state.windowList(space, col)
        local width = Tiling.tileColumn(column, bounds)
        update_virtual_positions(space, column, x)
        x = x + width + right_gap
    end

    -- tile windows from anchor left
    local x2 = anchor_frame.x - left_gap
    for col = anchor_index.col - 1, 1, -1 do
        local bounds = {
            x = nil,
            x2 = math.max(x2, left_margin),
            y = canvas.y,
            y2 = canvas.y2,
        }
        local column = codex.state.windowList(space, col)
        local width = Tiling.tileColumn(column, bounds)
        update_virtual_positions(space, column, x2 - width)
        x2 = x2 - width - left_gap
    end
end

return Tiling
