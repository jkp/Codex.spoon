-- scratch.lua — lightweight floating WM for scratch workspace
--
-- Thin wrappers around hs.window's built-in moveToUnit + directional focus.
-- Snap cycles through half -> quarter -> quarter on repeated presses (Rectangle-style).

local Scratch = {}

-- Spoon reference (set by init)
local codex = nil
local scratch_name = nil

---initialize scratch module with reference to the Codex spoon
---@param spoon table Codex spoon instance
function Scratch.init(spoon)
    codex = spoon
end

---set up scratch workspace
---@param name string scratch workspace name
function Scratch.setup(name)
    scratch_name = name
    codex.workspaces.setupScratch(name)
end

---get candidate windows on the scratch workspace
---@return userdata[] list of hs.window objects
local function candidates()
    if not codex or not scratch_name then return {} end
    local ids = codex.workspaces.windowIds(scratch_name)
    local wins = {}
    for id in pairs(ids) do
        local win = hs.window.get(id)
        if win then wins[#wins + 1] = win end
    end
    return wins
end

-- Snap cycles: each direction has a half then two quarters.
-- Repeated presses advance through the cycle.
local snap_cycles = {
    left   = { {0, 0, 0.5, 1}, {0, 0, 0.5, 0.5}, {0, 0.5, 0.5, 0.5} },
    right  = { {0.5, 0, 0.5, 1}, {0.5, 0, 0.5, 0.5}, {0.5, 0.5, 0.5, 0.5} },
    top    = { {0, 0, 1, 0.5}, {0, 0, 0.5, 0.5}, {0.5, 0, 0.5, 0.5} },
    bottom = { {0, 0.5, 1, 0.5}, {0, 0.5, 0.5, 0.5}, {0.5, 0.5, 0.5, 0.5} },
}

---check if two unit rects match within tolerance
---@param u table {x,y,w,h} current unit rect
---@param t table {x,y,w,h} array target
---@return boolean
local function matchesUnit(u, t)
    local eps = 0.05
    return math.abs(u.x - t[1]) < eps
       and math.abs(u.y - t[2]) < eps
       and math.abs(u.w - t[3]) < eps
       and math.abs(u.h - t[4]) < eps
end

---snap focused window with cycling: half -> quarter -> quarter -> half...
---@param direction string "left"|"right"|"top"|"bottom"
function Scratch.snap(direction)
    local win = hs.window.focusedWindow()
    if not win then return end

    local screen = win:screen()
    if not screen then return end
    local sf = screen:frame()
    local wf = win:frame()

    local cycle = snap_cycles[direction]
    if not cycle then return end

    -- Current unit rect
    local u = {
        x = (wf.x - sf.x) / sf.w,
        y = (wf.y - sf.y) / sf.h,
        w = wf.w / sf.w,
        h = wf.h / sf.h,
    }

    -- Find current position in cycle, advance to next
    local target = cycle[1]
    for i, pos in ipairs(cycle) do
        if matchesUnit(u, pos) then
            target = cycle[(i % #cycle) + 1]
            break
        end
    end

    win:moveToUnit(target)
end

---maximize focused window
function Scratch.maximize()
    local win = hs.window.focusedWindow()
    if not win then return end
    win:moveToUnit({ x = 0, y = 0, w = 1, h = 1 })
end

---center focused window at 2/3 size
function Scratch.center()
    local win = hs.window.focusedWindow()
    if not win then return end
    win:moveToUnit({ x = 1/6, y = 1/6, w = 2/3, h = 2/3 })
end

-- Size ratios for width/height cycling
local size_steps = { 1/3, 1/2, 2/3 }

---find current value in steps, return next (with tolerance)
---@param val number current ratio
---@return number next ratio
local function nextStep(val)
    local eps = 0.05
    for i, s in ipairs(size_steps) do
        if math.abs(val - s) < eps then
            return size_steps[(i % #size_steps) + 1]
        end
    end
    return size_steps[1]
end

---cycle width: 1/3 -> 1/2 -> 2/3, anchored at left edge, clamped to screen
function Scratch.cycle_width()
    local win = hs.window.focusedWindow()
    if not win then return end
    local screen = win:screen()
    if not screen then return end
    local sf = screen:frame()
    local wf = win:frame()

    local cur_w = wf.w / sf.w
    local new_w = nextStep(cur_w)
    local x = (wf.x - sf.x) / sf.w
    -- Clamp so window stays on screen
    if x + new_w > 1 then x = 1 - new_w end

    win:moveToUnit({ x = x, y = (wf.y - sf.y) / sf.h, w = new_w, h = wf.h / sf.h })
end

---cycle height: 1/3 -> 1/2 -> 2/3, anchored at top edge, clamped to screen
function Scratch.cycle_height()
    local win = hs.window.focusedWindow()
    if not win then return end
    local screen = win:screen()
    if not screen then return end
    local sf = screen:frame()
    local wf = win:frame()

    local cur_h = wf.h / sf.h
    local new_h = nextStep(cur_h)
    local y = (wf.y - sf.y) / sf.h
    -- Clamp so window stays on screen
    if y + new_h > 1 then y = 1 - new_h end

    win:moveToUnit({ x = (wf.x - sf.x) / sf.w, y = y, w = wf.w / sf.w, h = new_h })
end

-- Center cycle: always centered, increasing sizes
local center_sizes = { 1/3, 1/2, 2/3, 5/6 }

---cycle centered window through sizes: 1/3 -> 1/2 -> 2/3 -> 5/6
function Scratch.cycle_center()
    local win = hs.window.focusedWindow()
    if not win then return end
    local screen = win:screen()
    if not screen then return end
    local sf = screen:frame()
    local wf = win:frame()

    -- Detect current size (use width as the proxy — centered windows are square-ratio)
    local cur_w = wf.w / sf.w
    local eps = 0.05
    local new_size = center_sizes[1]
    for i, s in ipairs(center_sizes) do
        if math.abs(cur_w - s) < eps then
            new_size = center_sizes[(i % #center_sizes) + 1]
            break
        end
    end

    local margin = (1 - new_size) / 2
    win:moveToUnit({ x = margin, y = margin, w = new_size, h = new_size })
end

---directional focus within scratch workspace windows
---@param direction string "left"|"right"|"up"|"down"
function Scratch.focus(direction)
    local win = hs.window.focusedWindow()
    if not win then return end

    local cands = candidates()

    if direction == "left" then
        win:focusWindowWest(cands, false, false)
    elseif direction == "right" then
        win:focusWindowEast(cands, false, false)
    elseif direction == "up" then
        win:focusWindowNorth(cands, false, false)
    elseif direction == "down" then
        win:focusWindowSouth(cands, false, false)
    end
end

return Scratch
