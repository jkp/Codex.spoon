--- === Codex.spoon ===
---
--- Tile windows horizontally. Forked from PaperWM.spoon, inspired by PaperWM.
--- Codex: bound pages that replaced paper scrolls — scrolling within
--- workspaces, flipping between them.
---
--- # Usage
---
--- `Codex:start()` will begin automatically tiling new and existing windows.
--- `Codex:stop()` will release control over windows.
---
--- Set window gaps using `Codex.window_gap`:
--- - As a single number: same gap for all sides
--- - As a table with specific sides: `{top=8, bottom=8, left=8, right=8}`
---
--- For example:
--- ```
--- Codex.window_gap = 10  -- 10px gap on all sides
--- -- or
--- Codex.window_gap = {top=10, bottom=8, left=12, right=12}
--- ```
---
--- Overwrite `Codex.window_filter` to ignore specific applications. For example:
---
--- ```
--- Codex.window_filter = Codex.window_filter:setAppFilter("Finder", false)
--- Codex:start() -- restart for new window filter to take effect
--- ```
---
--- # Limitations
---
--- MacOS does not allow a window to be moved fully off-screen. Windows that would
--- be tiled off-screen are placed in a margin on the left and right edge of the
--- screen. They are still visible and clickable.
---
--- It's difficult to detect when a window is dragged from one space or screen to
--- another. Use the move_window_N commands to move windows between spaces and
--- screens.
---
--- Arrange screens vertically to prevent windows from bleeding into other screens.
---
---
--- Download: [https://github.com/jkp/Codex.spoon](https://github.com/jkp/Codex.spoon)
local Spaces <const> = hs.spaces

local Codex = {}
Codex.__index = Codex

-- Metadata
Codex.name = "Codex"
Codex.version = "1.0"
Codex.author = "Michael Mogenson, Jamie Kirkpatrick"
Codex.homepage = "https://github.com/jkp/Codex.spoon"
Codex.license = "MIT - https://opensource.org/licenses/MIT"

-- Types

---@alias Codex table Codex module object
---@alias Window userdata a ui.window
---@alias Frame table hs.geometry.rect
---@alias Index { row: number, col: number, space: number }
---@alias Space number a Mission Control space ID
---@alias Screen userdata hs.screen
---@alias Mapping { [string]: (table | string)[]}

-- logger
Codex.logger = hs.logger.new(Codex.name)

-- Load modules
Codex.config = dofile(hs.spoons.resourcePath("config.lua"))
Codex.state = dofile(hs.spoons.resourcePath("state.lua"))
Codex.windows = dofile(hs.spoons.resourcePath("windows.lua"))
Codex.space = dofile(hs.spoons.resourcePath("space.lua"))
Codex.events = dofile(hs.spoons.resourcePath("events.lua"))
Codex.actions = dofile(hs.spoons.resourcePath("actions.lua"))
Codex.floating = dofile(hs.spoons.resourcePath("floating.lua"))
Codex.tiling = dofile(hs.spoons.resourcePath("tiling.lua"))
Codex.transport = dofile(hs.spoons.resourcePath("transport.lua"))
Codex.workspaces = dofile(hs.spoons.resourcePath("workspaces.lua"))
Codex.scratch = dofile(hs.spoons.resourcePath("scratch.lua"))

-- Initialize modules
Codex.windows.init(Codex)
Codex.space.init(Codex)
Codex.events.init(Codex)
Codex.actions.init(Codex)
Codex.state.init(Codex)
Codex.floating.init(Codex)
Codex.tiling.init(Codex)
Codex.transport.init(Codex)
Codex.workspaces.init(Codex)
Codex.scratch.init(Codex)

-- Apply config
for k, v in pairs(Codex.config) do
    Codex[k] = v
end

---start automatic window tiling
---@return Codex
function Codex:start()
    -- check for some settings
    if not Spaces.screensHaveSeparateSpaces() then
        self.logger.e(
            "please check 'Displays have separate Spaces' in System Preferences -> Mission Control")
    end

    -- clear state
    self.state.clear();

    -- restore floating windows
    self.floating.restoreFloating()

    -- populate window list, index table, ui_watchers, and set initial layout
    self.windows.refreshWindows()

    -- start event listeners
    self.events.start()

    return self
end

---stop automatic window tiling
---@return Codex
function Codex:stop()
    -- stop events
    self.events.stop()

    -- fit all windows within the bounds of the screen
    for _, window in ipairs(self.window_filter:getWindows()) do
        window:setFrameInScreenBounds()
    end

    return self
end

function Codex:tileSpace(space)
    self.tiling.tileSpace(space)
end

function Codex:bindHotkeys(mapping)
    self.actions.bindHotkeys(mapping)
end

---dispatch: run scratch_fn on scratch workspace, tiling_fn otherwise
---@param scratch_fn function action for scratch workspace
---@param tiling_fn function action for tiling workspaces
---@return function
function Codex:dispatch(scratch_fn, tiling_fn)
    return function()
        if self.workspaces and self.workspaces.scratchName()
           and self.workspaces.currentSpace() == self.workspaces.scratchName() then
            scratch_fn()
        else
            tiling_fn()
        end
    end
end

return Codex
