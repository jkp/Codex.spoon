-- transport.lua — native winmove binary interaction layer
--
-- Wraps all communication with the winmove shim: sync batch moves,
-- async fire-and-forget parking, and parallel frame reads.

local JSON <const> = hs.json
local Window <const> = hs.window

local Transport = {}

-- Binary path (resolved in init)
local WINMOVE_BIN = nil

-- Spoon reference (set by init)
local codex = nil

-- Module-scope reference to prevent GC of async task
local active_async_task = nil

---initialize transport module
---@param spoon table Codex spoon instance
function Transport.init(spoon)
    codex = spoon
    WINMOVE_BIN = hs.spoons.resourcePath("winmove")

    -- Auto-build winmove if binary is missing
    if not hs.fs.attributes(WINMOVE_BIN, "mode") then
        local src = hs.spoons.resourcePath("winmove.swift")
        codex.logger.d("building winmove from source...")
        os.execute(string.format('swiftc -O -o %q %q -framework ApplicationServices', WINMOVE_BIN, src))
    end
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
function Transport.moveWindows(ops)
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

---batch move windows asynchronously (fire-and-forget via hs.task)
---@param ops table[] array of {id=wid, pid=pid, x=, y=, w=, h=}
function Transport.moveWindowsAsync(ops)
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
            codex.logger.ef("async park failed: %s", stdErr or "")
        end
    end, { tmpfile })
    active_async_task:start()
end

---batch read window frames via winmove read_only mode (parallel per-app AX calls)
---@param entries table[] array of {id=wid, pid=pid}
---@return table<number, table> frames mapping window id to {x, y, w, h}
function Transport.readFrames(entries)
    local frames = {}
    if not entries or #entries == 0 then return frames end

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
    if #json_ops == 0 then return frames end

    -- Write to temp file (winmove reads file arg, we read its stdout)
    local tmpfile = os.tmpname()
    local f = io.open(tmpfile, "w")
    if not f then return frames end
    f:write(JSON.encode(json_ops))
    f:close()

    local pipe = io.popen(WINMOVE_BIN .. " " .. tmpfile, "r")
    if not pipe then os.remove(tmpfile); return frames end
    local output = pipe:read("*a")
    pipe:close()
    os.remove(tmpfile)

    if output and #output > 0 then
        local decoded = JSON.decode(output)
        if decoded then
            for _, frame in ipairs(decoded) do
                frames[frame.wid] = {
                    x = frame.x, y = frame.y,
                    w = frame.w, h = frame.h,
                }
            end
        end
    end

    return frames
end

return Transport
