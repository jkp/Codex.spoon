-- workspaces.lua — virtual workspaces via off-screen window parking
--
-- Each workspace is a separate horizontal scrolling strip managed by Codex.
-- Only the active workspace's windows are tiled on-screen. Inactive workspace
-- windows are parked off-screen (AeroSpace-style). Codex's event handler
-- ignores parked windows via State.isHidden().

local JSON <const> = hs.json
local Spaces <const> = hs.spaces
local Screen <const> = hs.screen
local Timer <const> = hs.timer
local Window <const> = hs.window
local WindowFilter <const> = hs.window.filter

local Workspaces = {}

-- Spoon reference (set by init)
local codex = nil

-- Binary path (resolved in init)
local WINMOVE_BIN = nil

-- Data structures
local ws_windows = {}    -- name -> { [window_id] = true }
local win_ws = {}        -- window_id -> workspace name
local win_pid = {}       -- window_id -> pid (cached to avoid AX lookups)
local ws_snapshots = {}  -- name -> Codex snapshot (window_list + x_positions)
local ws_frames = {}     -- window_id -> saved {x, y, w, h} frame
local ws_focused = {}    -- name -> last focused window id
local current = nil      -- active workspace name
local switching = false  -- re-entrancy guard for switchTo
local focus_timer = nil  -- debounce timer for onWindowFocused
local app_rules = {}     -- appName -> workspace name
local screen_changed = false  -- set by screen watcher, forces retile on next switch
local screen_watcher = nil    -- hs.screen.watcher instance
local scratch_name = nil -- name of the scratch workspace (no tiling)
local pre_scratch = nil  -- workspace we came from before entering scratch
local ws_filter = nil    -- separate window filter for workspace lifecycle hooks

---user callback, called with workspace name after switching
---@type fun(name: string)|nil
Workspaces.onSwitch = nil

---initialize workspaces module with reference to the Codex spoon
---@param spoon table Codex spoon instance
function Workspaces.init(spoon)
    codex = spoon
    WINMOVE_BIN = hs.spoons.resourcePath("winmove")

    -- Auto-build winmove if binary is missing
    if not hs.fs.attributes(WINMOVE_BIN, "mode") then
        local src = hs.spoons.resourcePath("winmove.swift")
        print("[ws] building winmove from source...")
        os.execute(string.format('swiftc -O -o %q %q -framework ApplicationServices', WINMOVE_BIN, src))
    end
end

---park coordinates at the bottom-right corner of the visible screen
---window top-left lands at the corner so the rest hangs off-screen,
---but macOS doesn't clamp because top-left is technically on-screen (by 1px).
---this is exactly how AeroSpace hides windows.
---@return number, number x, y
local function parkCoords()
    local screen = Screen.mainScreen()
    if not screen then return 9999, 9999 end
    local sf = screen:frame()
    return sf.x2 - 1, sf.y2 - 1
end

---build JSON ops array from move ops (shared by sync and async)
---@param ops table[] array of {id=wid, pid=pid, x=, y=, w=, h=}
---@return table[] json-ready ops
local function buildJsonOps(ops)
    local json_ops = {}
    for _, op in ipairs(ops) do
        local pid = op.pid
        if not pid then
            local win = Window.get(op.id)
            if win then
                local app = win:application()
                if app then pid = app:pid() end
            end
        end
        if pid then
            json_ops[#json_ops + 1] = {
                wid = op.id, pid = pid,
                x = op.x, y = op.y, w = op.w, h = op.h,
            }
        end
    end
    return json_ops
end

---batch move/resize windows via the native winmove shim (sync, parallel per-app AX calls)
---@param ops table[] array of {id=wid, pid=pid, x=, y=, w=, h=}
local function batchMoveWindows(ops)
    if #ops == 0 then return end

    local json_ops = buildJsonOps(ops)
    if #json_ops == 0 then return end

    local json_str = JSON.encode(json_ops)
    local pipe = io.popen(WINMOVE_BIN, "w")
    if pipe then
        pipe:write(json_str)
        pipe:close()
    end
end

-- Module-scope reference to prevent GC of async task
local active_async_task = nil

---batch move windows asynchronously (fire-and-forget via hs.task)
---@param ops table[] array of {id=wid, pid=pid, x=, y=, w=, h=}
local function batchMoveWindowsAsync(ops)
    if #ops == 0 then return end

    local json_ops = buildJsonOps(ops)
    if #json_ops == 0 then return end

    -- Write JSON to temp file
    local tmpfile = os.tmpname()
    local f = io.open(tmpfile, "w")
    if not f then return end
    f:write(JSON.encode(json_ops))
    f:close()

    -- Launch winmove as async subprocess
    active_async_task = hs.task.new(WINMOVE_BIN, function(exitCode, stdOut, stdErr)
        os.remove(tmpfile)
        active_async_task = nil
        if exitCode ~= 0 then
            print("[ws] async park failed: " .. (stdErr or ""))
        end
    end, { tmpfile })
    active_async_task:start()
end

---batch read window frames via winmove read_only mode (parallel per-app AX calls)
---populates ws_frames for each window
---@param entries table[] array of {id=wid, pid=pid}
local function batchReadFrames(entries)
    if not entries or #entries == 0 then return end

    local json_ops = {}
    for _, entry in ipairs(entries) do
        if entry.pid then
            json_ops[#json_ops + 1] = {
                wid = entry.id, pid = entry.pid,
                x = 0, y = 0, w = 0, h = 0,
                read_only = true,
            }
        end
    end
    if #json_ops == 0 then return end

    -- Write to temp file (winmove reads file arg, we read its stdout)
    local tmpfile = os.tmpname()
    local f = io.open(tmpfile, "w")
    if not f then return end
    f:write(JSON.encode(json_ops))
    f:close()

    local pipe = io.popen(WINMOVE_BIN .. " " .. tmpfile, "r")
    if not pipe then os.remove(tmpfile); return end
    local output = pipe:read("*a")
    pipe:close()
    os.remove(tmpfile)

    if output and #output > 0 then
        local frames = JSON.decode(output)
        if frames then
            for _, frame in ipairs(frames) do
                ws_frames[frame.wid] = {
                    x = frame.x, y = frame.y,
                    w = frame.w, h = frame.h,
                }
            end
        end
    end
end

---remove a window from a stored snapshot (for cleanup on window destruction)
---@param name string workspace name
---@param dead_id number window id to remove
local function removeFromSnapshot(name, dead_id)
    local snap = ws_snapshots[name]
    if not snap or not snap.window_list then return end

    -- Walk the snapshot's window_list and remove the dead window
    for col = #snap.window_list, 1, -1 do
        local rows = snap.window_list[col]
        for row = #rows, 1, -1 do
            local win = rows[row]
            if win and win.id and win:id() == dead_id then
                table.remove(rows, row)
            end
        end
        if #rows == 0 then table.remove(snap.window_list, col) end
    end

    -- Remove from x_positions
    if snap.x_positions then
        snap.x_positions[dead_id] = nil
    end
end

---validate a snapshot, removing any stale window references
---checks against ws_windows tracking (no AX calls) instead of Window.get()
---@param snap table|nil snapshot to validate
---@param ws_name string workspace name to validate against
---@return table|nil cleaned snapshot
local function validateSnapshot(snap, ws_name)
    if not snap or not snap.window_list then return snap end

    local tracked = ws_windows[ws_name] or {}

    for col = #snap.window_list, 1, -1 do
        local rows = snap.window_list[col]
        for row = #rows, 1, -1 do
            local win = rows[row]
            local id = win and win.id and win:id()
            if not id or not tracked[id] then
                table.remove(rows, row)
                if id and snap.x_positions then
                    snap.x_positions[id] = nil
                end
            end
        end
        if #rows == 0 then table.remove(snap.window_list, col) end
    end

    return snap
end

---initialize workspaces
---@param names string[] workspace names
---@param rules table<string,string> appName -> workspace name mapping
function Workspaces.setup(names, rules)
    for _, name in ipairs(names) do
        ws_windows[name] = {}
    end
    current = names[1]

    -- Build app rules
    for appName, wsName in pairs(rules or {}) do
        app_rules[appName] = wsName
    end

    -- Block focus-triggered workspace switches during setup
    switching = true

    -- Assign existing windows to workspaces based on app rules
    local all_windows = codex.window_filter:getWindows()
    for _, win in ipairs(all_windows) do
        local app = win:application()
        if app then
            local wsName = app_rules[app:title()] or current
            local id = win:id()
            if id then
                ws_windows[wsName] = ws_windows[wsName] or {}
                ws_windows[wsName][id] = true
                win_ws[id] = wsName
                win_pid[id] = app:pid()
            end
        end
    end

    -- Park windows not on the initial workspace off-screen
    Timer.doAfter(1.0, function()
        local screen = Screen.mainScreen()
        if not screen then switching = false; return end
        local space = Spaces.activeSpaces()[screen:getUUID()]
        if not space then switching = false; return end

        local park_x, park_y = parkCoords()

        -- Pause events to avoid per-window retiling
        codex.events.paused = true

        -- Remove non-current workspace windows from tiling and collect park ops
        local park_ops = {}
        for name, ids in pairs(ws_windows) do
            if name ~= current then
                for id in pairs(ids) do
                    local win = Window.get(id)
                    if win then
                        -- Remove from tiling (skip focus)
                        codex.windows.removeWindow(win, true)
                        -- Mark hidden
                        codex.state.setHidden(id, true)
                        codex.state.uiWatcherStop(id)
                        -- Save frame before parking
                        ws_frames[id] = win:frame()
                        park_ops[#park_ops + 1] = {
                            id = id, pid = win_pid[id],
                            x = park_x, y = park_y, w = 0, h = 0,
                        }
                    end
                end
            end
        end

        -- Park all at once via native shim
        batchMoveWindows(park_ops)

        -- Now snapshot current workspace (which only has current ws windows)
        ws_snapshots[current] = codex.state.snapshotSpace(space)

        codex.events.paused = false
        codex:tileSpace(space)

        -- Allow focus-triggered workspace switches now that setup is complete
        switching = false
    end)

    -- Watch for screen geometry changes (resolution, display added/removed)
    screen_watcher = hs.screen.watcher.new(function()
        screen_changed = true
        print("[ws] screen geometry changed, will retile on next switch")
    end)
    screen_watcher:start()

    -- Window lifecycle hooks (separate filter to avoid double-firing with Codex's)
    ws_filter = WindowFilter.new():setDefaultFilter()
    ws_filter:subscribe(WindowFilter.windowVisible, function(win) Workspaces.onWindowCreated(win) end)
    ws_filter:subscribe(WindowFilter.windowDestroyed, function(win) Workspaces.onWindowDestroyed(win) end)
    ws_filter:subscribe(WindowFilter.windowFocused, function(win) Workspaces.onWindowFocused(win) end)
end

---switch to a workspace
---@param name string workspace to switch to
function Workspaces.switchTo(name)
    if not ws_windows[name] or name == current or switching then return end
    switching = true

    local t0 = hs.timer.absoluteTime()

    local screen = Screen.mainScreen()
    if not screen then switching = false; return end
    local space = Spaces.activeSpaces()[screen:getUUID()]
    if not space then switching = false; return end

    local park_x, park_y = parkCoords()

    -- Pause events for atomic switch
    codex.events.paused = true

    local old = current
    current = name

    -- 1. Save last focused window for old workspace
    local focused = Window.focusedWindow()
    if focused and focused:id() then
        ws_focused[old] = focused:id()
    end

    -- 2. Stop UI watchers for old workspace windows
    for id in pairs(ws_windows[old] or {}) do
        codex.state.uiWatcherStop(id)
    end

    -- 3. Save current window frames (parallel via winmove read_only)
    local read_ops = {}
    for id in pairs(ws_windows[old] or {}) do
        if win_pid[id] then
            read_ops[#read_ops + 1] = { id = id, pid = win_pid[id] }
        end
    end
    batchReadFrames(read_ops)

    -- 4. Snapshot state for old workspace
    ws_snapshots[old] = codex.state.snapshotSpace(space)

    -- 5. Update hidden state
    for id in pairs(ws_windows[name] or {}) do
        codex.state.setHidden(id, nil)
    end
    for id in pairs(ws_windows[old] or {}) do
        codex.state.setHidden(id, true)
    end

    local t_prep = hs.timer.absoluteTime()

    -- 6. Build restore ops (sync) and park ops (async)
    local restore_ops = {}
    for id in pairs(ws_windows[name] or {}) do
        local f = ws_frames[id]
        if f then
            restore_ops[#restore_ops + 1] = {
                id = id, pid = win_pid[id],
                x = f.x, y = f.y, w = f.w, h = f.h,
            }
            ws_frames[id] = nil
        end
    end
    local park_ops = {}
    for id in pairs(ws_windows[old] or {}) do
        park_ops[#park_ops + 1] = {
            id = id, pid = win_pid[id],
            x = park_x, y = park_y, w = 0, h = 0,
        }
    end

    -- 7a. Restore new workspace windows (sync — user needs to see these)
    batchMoveWindows(restore_ops)

    local t_move = hs.timer.absoluteTime()

    -- 7b. Park old workspace windows (async — invisible, fire-and-forget)
    batchMoveWindowsAsync(park_ops)

    local t_async = hs.timer.absoluteTime()

    -- 7c. Ensure all scratch windows are floating
    if name == scratch_name then
        for id in pairs(ws_windows[name] or {}) do
            codex.state.is_floating[id] = true
        end
    end

    -- 8–10. Restore state, watchers, tileSpace — skip for scratch
    local snap = nil
    local did_tile = false
    local t_validate = hs.timer.absoluteTime()
    local t_restore_snap = t_validate
    local t_watchers = t_validate
    local t_tile = t_validate

    if name ~= scratch_name then
        snap = validateSnapshot(ws_snapshots[name], name)
        t_validate = hs.timer.absoluteTime()

        if snap and snap.window_list and #snap.window_list > 0 then
            codex.state.restoreSpace(space, snap)
        else
            codex.state.restoreSpace(space, nil)
        end

        t_restore_snap = hs.timer.absoluteTime()

        codex.state.ensureWatchers(space)

        t_watchers = hs.timer.absoluteTime()

        if not snap or not snap.window_list or #snap.window_list == 0 or screen_changed then
            codex.events.paused = false
            codex:tileSpace(space)
            codex.windows.refreshWindows()
            screen_changed = false
            did_tile = true
        end

        t_tile = hs.timer.absoluteTime()
    end

    -- 11. Focus last-focused window (while events still paused to prevent tileSpace cascade)
    --     Use window refs from snapshot to avoid expensive Window.get() / allWindows() AX query
    local focus_win = nil
    local focus_id = ws_focused[name]
    if name == scratch_name then
        -- Scratch windows aren't in the snapshot (they're floating), so look them up directly.
        -- Try the last-focused window first, then fall back to any window on scratch.
        if focus_id and ws_windows[name][focus_id] then
            focus_win = Window.get(focus_id)
        end
        if not focus_win then
            for id in pairs(ws_windows[name] or {}) do
                focus_win = Window.get(id)
                if focus_win then break end
            end
        end
    elseif snap and snap.window_list then
        for _, col in ipairs(snap.window_list) do
            for _, win in ipairs(col) do
                if win and win.id then
                    local id = win:id()
                    if id == focus_id then
                        focus_win = win
                        break
                    end
                    -- Remember first window as fallback
                    if not focus_win then focus_win = win end
                end
            end
            if focus_win and focus_win:id() == focus_id then break end
        end
    end

    local t_lookup = hs.timer.absoluteTime()

    if focus_win then
        focus_win:focus()
    end

    -- 12. Now unpause events (keep paused on scratch) and clear switching guard
    if name ~= scratch_name then
        codex.events.paused = false
    end
    switching = false

    -- 13. Notify via callback
    if Workspaces.onSwitch then Workspaces.onSwitch(name) end

    local t_end = hs.timer.absoluteTime()
    local function ms(a, b) return math.floor((b - a) / 1e6) end
    local tile_str = did_tile and "tile" or "skip"
    print(string.format("[ws] switchTo %s: prep=%dms restore=%dms validate=%dms watchers=%dms %s=%dms lookup=%dms focus=%dms total=%dms ops=%d/%d",
        name, ms(t0, t_prep), ms(t_prep, t_move),
        ms(t_async, t_validate), ms(t_restore_snap, t_watchers),
        tile_str, ms(t_watchers, t_tile),
        ms(t_tile, t_lookup), ms(t_lookup, t_end),
        ms(t0, t_end), #restore_ops, #park_ops))
end

---move the focused window to a different workspace
---@param name string target workspace
function Workspaces.moveWindowTo(name)
    print("[ws] moveWindowTo: " .. name)
    local win = Window.focusedWindow()
    if not win then print("[ws] moveWindowTo: no focused window"); return end
    if not ws_windows[name] then print("[ws] moveWindowTo: unknown workspace " .. name); return end
    local id = win:id()
    if not id then print("[ws] moveWindowTo: no window id"); return end

    local src = win_ws[id]
    print("[ws] moveWindowTo: window " .. id .. " src=" .. (src or "untracked") .. " dst=" .. name)
    if src == name then print("[ws] moveWindowTo: already on target"); return end

    -- Remove from source workspace
    if src and ws_windows[src] then
        ws_windows[src][id] = nil
    end

    -- Add to target workspace
    ws_windows[name][id] = true
    win_ws[id] = name

    -- Float/unfloat based on scratch workspace
    if name == scratch_name then
        codex.state.is_floating[id] = true
    elseif src == scratch_name then
        codex.state.is_floating[id] = nil
    end

    -- If target is not current workspace, park the window
    if name ~= current then
        local screen = Screen.mainScreen()
        if screen then
            -- Find adjacent window in tiling order BEFORE removing
            local neighbor = nil
            local idx = codex.state.windowIndex(win)
            if idx then
                local space = Spaces.activeSpaces()[screen:getUUID()]
                if space then
                    local col_wins = codex.state.windowList(space, idx.col)
                    if col_wins then
                        -- Try same column, adjacent row
                        neighbor = codex.state.windowList(space, idx.col, idx.row - 1)
                            or codex.state.windowList(space, idx.col, idx.row + 1)
                    end
                    if not neighbor then
                        -- Try adjacent column
                        local prev_col = codex.state.windowList(space, idx.col - 1)
                        local next_col = codex.state.windowList(space, idx.col + 1)
                        if prev_col then neighbor = prev_col[1] end
                        if not neighbor and next_col then neighbor = next_col[1] end
                    end
                end
            end

            -- Remove from tiling (skip focus)
            codex.windows.removeWindow(win, true)
            -- Park off-screen
            codex.state.setHidden(id, true)
            codex.state.uiWatcherStop(id)
            local park_x, park_y = parkCoords()
            ws_frames[id] = win:frame()
            batchMoveWindows({
                { id = id, pid = win_pid[id], x = park_x, y = park_y, w = 0, h = 0 }
            })
            -- Update snapshot for current workspace
            local space = Spaces.activeSpaces()[screen:getUUID()]
            if space then
                ws_snapshots[current] = codex.state.snapshotSpace(space)
                codex:tileSpace(space)
            end

            -- Focus the neighbor we found before removing
            if neighbor then
                neighbor:focus()
            end
        end
    end
end

---assign a window to the correct workspace (called on window creation)
---@param win userdata hs.window
function Workspaces.onWindowCreated(win)
    if not win or not win.id then return end
    local id = win:id()
    if not id or win_ws[id] then return end  -- already tracked

    local app = win:application()
    local wsName = current
    if app then
        win_pid[id] = app:pid()
        wsName = app_rules[app:title()] or current
    end

    ws_windows[wsName] = ws_windows[wsName] or {}
    ws_windows[wsName][id] = true
    win_ws[id] = wsName

    -- Auto-float windows on the scratch workspace
    if wsName == scratch_name then
        codex.state.is_floating[id] = true
    end

    -- If window belongs to a non-current workspace, park it after tiling finishes
    if wsName ~= current then
        local screen = Screen.mainScreen()
        if screen then
            Timer.doAfter(0.1, function()
                local w = Window.get(id)
                if not w then return end
                codex.state.setHidden(id, true)
                codex.state.uiWatcherStop(id)
                codex.windows.removeWindow(w, true)
                local park_x, park_y = parkCoords()
                ws_frames[id] = w:frame()
                batchMoveWindows({
                    { id = id, pid = win_pid[id], x = park_x, y = park_y, w = 0, h = 0 }
                })
                local space = Spaces.activeSpaces()[screen:getUUID()]
                if space then codex:tileSpace(space) end
            end)
        end
    end
end

---clean up when a window is destroyed
---@param win userdata hs.window
function Workspaces.onWindowDestroyed(win)
    if not win or not win.id then return end
    local id = win:id()
    if not id then return end

    local wsName = win_ws[id]
    if wsName and ws_windows[wsName] then
        ws_windows[wsName][id] = nil
    end
    -- Clean up the snapshot for this workspace
    if wsName then removeFromSnapshot(wsName, id) end
    win_ws[id] = nil
    win_pid[id] = nil
    ws_frames[id] = nil
    codex.state.setHidden(id, nil)
    -- Clear last-focused reference if it was this window
    if wsName and ws_focused[wsName] == id then
        ws_focused[wsName] = nil
    end
end

---handle window focus — switch workspace if focused window is on a different one
---@param win userdata hs.window
function Workspaces.onWindowFocused(win)
    if switching then return end
    if not win or not win.id then return end
    local id = win:id()
    if not id then return end

    -- Track last-focused on current workspace
    local wsName = win_ws[id]
    if wsName == current then
        ws_focused[current] = id
        return
    end

    -- Debounce: only switch if focus settles on a window from another workspace.
    if focus_timer then focus_timer:stop() end
    focus_timer = Timer.doAfter(0.3, function()
        focus_timer = nil
        local now_focused = Window.focusedWindow()
        if now_focused and now_focused:id() == id and win_ws[id] and win_ws[id] ~= current then
            Workspaces.switchTo(win_ws[id])
        end
    end)
end

---get current workspace name
---@return string
function Workspaces.currentSpace()
    return current
end

---get the scratch workspace name
---@return string|nil
function Workspaces.scratchName()
    return scratch_name
end

---get window ids for a workspace
---@param name string|nil workspace name, defaults to current
---@return table<number, true>
function Workspaces.windowIds(name)
    return ws_windows[name or current] or {}
end

---list windows on a workspace
---@param name string|nil workspace name, defaults to current
---@return string[]
function Workspaces.listWindows(name)
    name = name or current
    local result = {}
    for id in pairs(ws_windows[name] or {}) do
        local win = Window.get(id)
        if win then
            local app = win:application()
            local appName = app and app:title() or "?"
            result[#result + 1] = appName .. ": " .. win:title() .. " [" .. id .. "]"
        end
    end
    return result
end

---debug dump of all workspace state
function Workspaces.dump()
    local output = { "=== Workspaces ===" }
    table.insert(output, "current: " .. (current or "nil"))
    for name, ids in pairs(ws_windows) do
        local marker = name == current and " *" or ""
        local wins = {}
        for id in pairs(ids) do
            local win = Window.get(id)
            local title = win and win:title() or "gone"
            local hidden = codex.state.isHidden(id) and " [hidden]" or ""
            local focused = ws_focused[name] == id and " [focused]" or ""
            wins[#wins + 1] = string.format("%s(%d)%s%s", title, id, hidden, focused)
        end
        table.insert(output, string.format("  %s%s: %s", name, marker, table.concat(wins, ", ")))
    end
    print(table.concat(output, "\n"))
end

---mark a workspace as the scratch (no-tiling) workspace
---@param name string workspace name to use as scratch
function Workspaces.setupScratch(name)
    scratch_name = name
end

---toggle between scratch workspace and previous workspace
function Workspaces.toggleScratch()
    if not scratch_name then return end
    if current == scratch_name then
        Workspaces.switchTo(pre_scratch or "personal")
    else
        pre_scratch = current
        Workspaces.switchTo(scratch_name)
    end
end

return Workspaces
