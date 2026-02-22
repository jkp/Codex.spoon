---@diagnostic disable

local M = {}

-- Window registry for hs.window.get(id) lookups
M._window_registry = {}

-- Timer auto-execute: when true, doAfter callbacks fire immediately
M._auto_execute_timers = false

-- Captured timer callbacks for manual triggering
M._timer_callbacks = {}

-- Absolute time counter for hs.timer.absoluteTime mock
M._absolute_time = 0

function M.register_window(win)
    M._window_registry[win:id()] = win
end

function M.clear_window_registry()
    M._window_registry = {}
end

function M.mock_screen()
    return {
        frame = function() return { x = 0, y = 32, w = 1000, h = 668, x2 = 1000, y2 = 700, center = { x = 500, y = 366 } } end,
        fullFrame = function() return { x = 0, y = 0, w = 1000, h = 800, x2 = 1000, y2 = 800, center = { x = 500, y = 400 } } end,
        getUUID = function() return "mock_screen_uuid" end,
    }
end

function M.mock_window(id, title, frame, app_name, app_pid)
    frame = frame or { x = 0, y = 0, w = 100, h = 100 }
    frame.center = { x = frame.x + frame.w / 2, y = frame.y + frame.h / 2 }
    frame.x2 = frame.x + frame.w
    frame.y2 = frame.y + frame.h
    app_name = app_name or "Terminal"
    app_pid = app_pid or (1000 + id)
    local win
    win = {
        id = function() return id end,
        title = function() return title end,
        frame = function() return frame end,
        application = function()
            return {
                bundleID = function() return "com.apple.Terminal" end,
                title = function() return app_name end,
                pid = function() return app_pid end,
                allWindows = function() return { win } end,
            }
        end,
        tabCount = function() return 0 end,
        isMaximizable = function() return true end,
        newWatcher = function()
            return {
                start = function() end,
                stop = function() end,
            }
        end,
        focus = function() end,
        setFrame = function(new_frame) frame = new_frame end,
        screen = function() return M.mock_screen() end,
        moveToUnit = function(self_or_rect, maybe_rect)
            -- Handle both win:moveToUnit(rect) and win.moveToUnit(rect)
            local rect = maybe_rect or self_or_rect
            local sf = M.mock_screen():frame()
            local ux, uy, uw, uh
            if rect[1] ~= nil then
                ux, uy, uw, uh = rect[1], rect[2], rect[3], rect[4]
            else
                ux, uy, uw, uh = rect.x, rect.y, rect.w, rect.h
            end
            frame = {
                x = sf.x + ux * sf.w,
                y = sf.y + uy * sf.h,
                w = uw * sf.w,
                h = uh * sf.h,
            }
            frame.x2 = frame.x + frame.w
            frame.y2 = frame.y + frame.h
            frame.center = { x = frame.x + frame.w / 2, y = frame.y + frame.h / 2 }
        end,
        focusWindowWest = function(_, _) end,
        focusWindowEast = function(_, _) end,
        focusWindowNorth = function(_, _) end,
        focusWindowSouth = function(_, _) end,
    }
    return win
end

function M.get_mock_codex(modules)
    return {
        state = modules.State,
        windows = modules.Windows,
        floating = modules.Floating,
        tiling = modules.Tiling,
        space = modules.Space,
        events = {
            windowEventHandler = function() end,
            paused = false,
        },
        transport = {
            moveWindows = function(ops) end,
            moveWindowsAsync = function(ops) end,
            readFrames = function(entries) return {} end,
        },
        window_filter = {
            getWindows = function() return {} end,
        },
        logger = {
            d = function(...) end,
            e = function(...) end,
            i = function(...) end,
            v = function(...) end,
            df = function(...) end,
            vf = function(...) end,
            ef = function(...) end,
        },
        screen_margin = 8,
        window_gap = 8,
        tileSpace = function(space) if modules.Tiling then modules.Tiling.tileSpace(space) end end,
    }
end

-- IO stubs to prevent actual file/process operations
local saved_io = {}

function M.stub_io()
    saved_io.popen = io.popen
    saved_io.open = io.open
    saved_io.tmpname = os.tmpname
    saved_io.remove = os.remove
    saved_io.execute = os.execute

    io.popen = function(cmd, mode)
        return {
            write = function(self, data) end,
            read = function(self, fmt) return "" end,
            close = function(self) end,
        }
    end
    io.open = function(path, mode)
        return {
            write = function(self, data) end,
            close = function(self) end,
        }
    end
    os.tmpname = function() return "/tmp/mock_tmp" end
    os.remove = function(path) end
    os.execute = function(cmd) return true end
end

function M.restore_io()
    if saved_io.popen then io.popen = saved_io.popen end
    if saved_io.open then io.open = saved_io.open end
    if saved_io.tmpname then os.tmpname = saved_io.tmpname end
    if saved_io.remove then os.remove = saved_io.remove end
    if saved_io.execute then os.execute = saved_io.execute end
    saved_io = {}
end

function M.init_mocks(modules)
    -- Reset mock state
    M._window_registry = {}
    M._auto_execute_timers = false
    M._timer_callbacks = {}
    M._absolute_time = 0

    _G.hs = {
        spaces = {
            windowSpaces = function(_) return { 1 } end,
            spaceType = function(_) return "user" end,
            spaceDisplay = function(_) return "mock_screen_uuid" end,
            focusedSpace = function() return 1 end,
            allSpaces = function() return { mock_screen_uuid = { 1, 2, 3 } } end,
            activeSpaces = function() return { mock_screen_uuid = 1 } end,
        },
        screen = {
            find = function(_) return M.mock_screen() end,
            mainScreen = function() return M.mock_screen() end,
            allScreens = function() return { M.mock_screen() } end,
            watcher = {
                new = function(fn)
                    return {
                        _fn = fn,
                        _running = false,
                        start = function(self) self._running = true; return self end,
                        stop = function(self) self._running = false; return self end,
                    }
                end,
            },
        },
        uielement = {
            watcher = {
                windowMoved = "windowMoved",
                windowResized = "windowResized",
            },
        },
        window = {
            animationDuration = 0.0,
            focusedWindow = function() return nil end,
            get = function(id) return M._window_registry[id] end,
            filter = {
                new = function()
                    local filter = {
                        _subscriptions = {},
                        setDefaultFilter = function(self) return self end,
                        subscribe = function(self, event, fn)
                            self._subscriptions[event] = fn
                            return self
                        end,
                        unsubscribeAll = function(self)
                            self._subscriptions = {}
                            return self
                        end,
                        getWindows = function() return {} end,
                    }
                    return filter
                end,
                windowVisible = "windowVisible",
                windowDestroyed = "windowDestroyed",
                windowFocused = "windowFocused",
                windowNotVisible = "windowNotVisible",
                windowFullscreened = "windowFullscreened",
                windowUnfullscreened = "windowUnfullscreened",
            },
        },
        geometry = {
            rect = function(x, y, w, h) return { x = x, y = y, w = w, h = h, x2 = x + w, y2 = y + h } end,
        },
        spoons = {
            resourcePath = function(file) return "./" .. file end,
        },
        fnutils = {
            partial = function(func, ...)
                local args = { ... }
                return function(...)
                    local all_args = {}
                    for i = 1, #args do all_args[i] = args[i] end
                    local arg_n = #args
                    local varargs = { ... }
                    for i = 1, #varargs do all_args[arg_n + i] = varargs[i] end
                    return func(table.unpack(all_args))
                end
            end,
            ifilter = function(t, fn)
                local nt = {}
                for _, v in ipairs(t) do if fn(v) then nt[#nt + 1] = v end end
                return nt
            end,
        },
        logger = {
            new = function(_)
                return {
                    d = function(...) end,
                    e = function(...) end,
                    i = function(...) end,
                    v = function(...) end,
                    df = function(...) end,
                    vf = function(...) end,
                    ef = function(...) end,
                }
            end,
        },
        eventtap = {
            event = {
                types = {
                    mouseMoved = "mouseMoved",
                    leftMouseDown = "leftMouseDown",
                    leftMouseUp = "leftMouseUp",
                    leftMouseDragged = "leftMouseDragged",
                },
                newMouseEvent = function(_, _) return { post = function() end } end,
            },
        },
        timer = {
            secondsSinceEpoch = function() return 0 end,
            doUntil = function(c, t, d) c() end,
            absoluteTime = function()
                M._absolute_time = M._absolute_time + 1000000  -- increment by 1ms in ns
                return M._absolute_time
            end,
            doAfter = function(delay, fn)
                local timer = {
                    _fn = fn,
                    _delay = delay,
                    _stopped = false,
                    stop = function(self) self._stopped = true end,
                }
                M._timer_callbacks[#M._timer_callbacks + 1] = timer
                if M._auto_execute_timers then
                    fn()
                end
                return timer
            end,
        },
        mouse = {
            absolutePosition = function(_) end,
        },
        settings = {
            set = function(_, _) end,
            get = function(_) return {} end,
        },
        notify = {
            show = function(_, _, _, _) end,
        },
        json = {
            encode = function(t)
                -- Minimal JSON encoder for tests
                if type(t) ~= "table" then return tostring(t) end
                return "{}"
            end,
            decode = function(s)
                if not s or s == "" then return nil end
                return {}
            end,
        },
        fs = {
            attributes = function(path, attr)
                -- Pretend winmove binary exists
                return "file"
            end,
        },
        task = {
            new = function(bin, callback, args)
                local task = {
                    _bin = bin,
                    _callback = callback,
                    _args = args,
                    start = function(self)
                        if callback then callback(0, "", "") end
                        return self
                    end,
                }
                return task
            end,
        },
        application = {
            find = function(name)
                return nil
            end,
            launchOrFocus = function(name) end,
        },
    }

    setmetatable(hs.screen, {
        __call = function(_, uuid)
            if uuid == "mock_screen_uuid" then
                return M.mock_screen()
            end
            return nil
        end,
    })
end

return M
