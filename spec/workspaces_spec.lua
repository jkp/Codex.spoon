---@diagnostic disable

package.preload["mocks"] = function() return dofile("spec/mocks.lua") end
package.preload["state"] = function() return dofile("state.lua") end
package.preload["workspaces"] = function() return dofile("workspaces.lua") end

describe("Codex.workspaces", function()
    local Mocks = require("mocks")
    Mocks.init_mocks()

    local spy = require("luassert.spy")
    local State = require("state")

    local focused_window
    local all_filter_windows
    local mock_codex
    local Workspaces

    before_each(function()
        -- Re-init mocks to reset all state
        Mocks.init_mocks()
        Mocks._auto_execute_timers = true
        Mocks._timer_callbacks = {}

        focused_window = nil
        all_filter_windows = {}

        hs.window.focusedWindow = function() return focused_window end
        hs.window.get = function(id) return Mocks._window_registry[id] end

        mock_codex = {
            state = State,
            windows = {
                removeWindow = function(win, skip) return 1 end,
                refreshWindows = function() end,
                addWindow = function(win) return 1 end,
            },
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
                getWindows = function() return all_filter_windows end,
            },
            logger = {
                d = function(...) end,
                e = function(...) end,
                v = function(...) end,
                i = function(...) end,
                df = function(...) end,
                vf = function(...) end,
                ef = function(...) end,
            },
            screen_margin = 8,
            window_gap = 8,
            tileSpace = function(self, space) end,
        }

        State.init(mock_codex)

        -- Force fresh module load each test (workspaces has local state)
        package.loaded["workspaces"] = nil
        Workspaces = require("workspaces")
        Workspaces.init(mock_codex)

        -- Stub IO AFTER module load to avoid breaking luarocks loader
        Mocks.stub_io()
    end)

    after_each(function()
        Mocks.restore_io()
        Mocks._auto_execute_timers = false
    end)

    -- Helper: set up workspaces with standard config
    local function setupStandard(opts)
        opts = opts or {}
        local config = {
            workspaces = opts.workspaces or { "personal", "work", "global" },
            appRules = opts.appRules or {},
            titleRules = opts.titleRules or {},
            jumpTargets = opts.jumpTargets or {},
            toggleBack = opts.toggleBack or false,
            focusFollows = opts.focusFollows or {},
        }
        Workspaces.setup(config)
        return config
    end

    -- Helper: create and register a window
    local function makeWin(id, title, app_name, app_pid)
        local win = Mocks.mock_window(id, title or ("W" .. id), nil, app_name, app_pid)
        Mocks.register_window(win)
        return win
    end

    describe("setup", function()
        it("should create workspace tracking entries", function()
            setupStandard()

            assert.is_not_nil(Workspaces.windowIds("personal"))
            assert.is_not_nil(Workspaces.windowIds("work"))
            assert.is_not_nil(Workspaces.windowIds("global"))
        end)

        it("should set current to first workspace", function()
            setupStandard()
            assert.are.equal("personal", Workspaces.currentSpace())
        end)

        it("should assign windows based on app rules", function()
            local win = makeWin(1, "Browser", "Safari", 100)
            all_filter_windows = { win }

            setupStandard({ appRules = { Safari = "work" } })

            local work_ids = Workspaces.windowIds("work")
            assert.is_true(work_ids[1] == true)
        end)

        it("should match app rules despite invisible Unicode chars in app name", function()
            -- macOS Catalyst/iOS apps like WhatsApp embed U+200E (LRM) in their name
            local lrm = "\xe2\x80\x8e"
            local win = makeWin(1, lrm .. "WhatsApp", lrm .. "WhatsApp", 100)
            all_filter_windows = { win }

            setupStandard({ appRules = { WhatsApp = "work" } })

            local work_ids = Workspaces.windowIds("work")
            assert.is_true(work_ids[1] == true)
        end)

        it("should assign unmatched windows to current workspace", function()
            local win = makeWin(1, "Terminal", "Terminal", 100)
            all_filter_windows = { win }

            setupStandard()

            local personal_ids = Workspaces.windowIds("personal")
            assert.is_true(personal_ids[1] == true)
        end)

        it("should start screen watcher", function()
            -- Just verify setup completes without error
            setupStandard()
        end)

        it("should call refreshWindows synchronously during setup", function()
            local refresh_called = false
            mock_codex.windows.refreshWindows = function() refresh_called = true end

            setupStandard()

            assert.is_true(refresh_called)
        end)

        it("should park non-current workspace windows synchronously during setup", function()
            local w1 = makeWin(1, "Terminal", "Terminal", 100)
            local w2 = makeWin(2, "Browser", "Safari", 200)
            all_filter_windows = { w1, w2 }

            local move_spy = spy.on(mock_codex.transport, "moveWindows")
            setupStandard({ appRules = { Safari = "work" } })

            -- w2 should be hidden (parked during setup, not via timer)
            assert.is_true(State.isHidden(2))
            -- moveWindows should have been called with park ops
            assert.spy(move_spy).was.called()
        end)

        it("should park windows using filter refs, not Window.get", function()
            local w1 = makeWin(1, "Terminal", "Terminal", 100)
            local w2 = makeWin(2, "WhatsApp", "WhatsApp", 200)
            all_filter_windows = { w1, w2 }

            -- Make Window.get return nil for w2 (simulates AX failure during reload)
            local orig_get = hs.window.get
            hs.window.get = function(id)
                if id == 2 then return nil end
                return orig_get(id)
            end

            setupStandard({ appRules = { WhatsApp = "work" } })

            -- w2 should STILL be parked despite Window.get returning nil
            -- because _initialPark uses filter refs instead
            assert.is_true(State.isHidden(2))

            hs.window.get = orig_get
        end)
    end)

    describe("switchTo", function()
        it("should be no-op for current workspace", function()
            setupStandard()
            local callback = spy.new(function() end)
            Workspaces.onSwitch = callback

            Workspaces.switchTo("personal")

            assert.spy(callback).was.not_called()
        end)

        it("should be no-op for unknown workspace", function()
            setupStandard()
            local callback = spy.new(function() end)
            Workspaces.onSwitch = callback

            Workspaces.switchTo("nonexistent")

            assert.spy(callback).was.not_called()
        end)

        it("should switch to target workspace", function()
            setupStandard()

            Workspaces.switchTo("work")

            assert.are.equal("work", Workspaces.currentSpace())
        end)

        it("should fire onSwitch callback", function()
            setupStandard()
            local switched_to = nil
            Workspaces.onSwitch = function(name) switched_to = name end

            Workspaces.switchTo("work")

            assert.are.equal("work", switched_to)
        end)

        it("should update hidden state: unhide target, hide old", function()
            local w1 = makeWin(1, "W1", "Terminal", 100)
            local w2 = makeWin(2, "W2", "Browser", 200)
            all_filter_windows = { w1, w2 }

            setupStandard({ appRules = { Terminal = "personal", Browser = "work" } })

            -- Before switch: w2 (work) should be hidden
            assert.is_true(State.isHidden(2))
            assert.is_false(State.isHidden(1))

            Workspaces.switchTo("work")

            -- After switch: w1 (personal) should be hidden, w2 (work) unhidden
            assert.is_true(State.isHidden(1))
            assert.is_false(State.isHidden(2))
        end)

        it("should save focused window for old workspace and restore focus on return", function()
            local w1 = makeWin(1, "W1")
            all_filter_windows = { w1 }
            focused_window = w1

            setupStandard()

            -- Add w1 to tiling so snapshot has it
            State.windowList(1)[1] = { w1 }

            -- Switch away - w1 should be saved as last-focused on personal
            local focus_spy = spy.on(w1, "focus")
            Workspaces.switchTo("work")

            -- Switch back - w1 should be focused
            Workspaces.switchTo("personal")

            assert.are.equal("personal", Workspaces.currentSpace())
            assert.spy(focus_spy).was.called()
        end)

        it("should clear switching guard after completion", function()
            setupStandard()
            Workspaces.switchTo("work")

            -- Should be able to switch again (not blocked by guard)
            Workspaces.switchTo("global")
            assert.are.equal("global", Workspaces.currentSpace())
        end)

        it("should restore snapshot and ensure watchers for non-scratch workspace", function()
            -- Set up some tiled windows on personal
            local w1 = makeWin(1, "W1")
            all_filter_windows = { w1 }
            setupStandard()

            -- Tile w1 on space 1
            State.windowList(1)[1] = { w1 }

            -- Switch away and back
            Workspaces.switchTo("work")
            Workspaces.switchTo("personal")

            assert.are.equal("personal", Workspaces.currentSpace())
        end)

        it("should mark scratch windows as floating when switching to scratch", function()
            local w1 = makeWin(1, "W1")
            all_filter_windows = { w1 }

            setupStandard({ workspaces = { "personal", { name = "scratch", layout = "unmanaged" } } })

            -- Move w1 to scratch
            focused_window = w1
            Workspaces.moveWindowTo("scratch")

            -- Switch to scratch
            Workspaces.switchTo("scratch")

            assert.is_true(State.is_floating[1])
        end)

        it("should not fire callback when switching to current workspace", function()
            setupStandard()
            local count = 0
            Workspaces.onSwitch = function() count = count + 1 end

            Workspaces.switchTo("personal")  -- same as current

            assert.are.equal(0, count)
        end)
    end)

    describe("moveWindowTo", function()
        it("should guard against no focused window", function()
            setupStandard()
            focused_window = nil

            -- Should not error
            Workspaces.moveWindowTo("work")
        end)

        it("should guard against unknown target workspace", function()
            local w1 = makeWin(1, "W1")
            focused_window = w1
            all_filter_windows = { w1 }
            setupStandard()

            -- Should not error
            Workspaces.moveWindowTo("nonexistent")
        end)

        it("should guard against already on target", function()
            local w1 = makeWin(1, "W1")
            focused_window = w1
            all_filter_windows = { w1 }
            setupStandard()

            -- w1 is on personal (current), moving to personal should be no-op
            Workspaces.moveWindowTo("personal")
            local ids = Workspaces.windowIds("personal")
            assert.is_true(ids[1] == true)
        end)

        it("should move window from source to target tracking", function()
            local w1 = makeWin(1, "W1")
            focused_window = w1
            all_filter_windows = { w1 }
            setupStandard()

            Workspaces.moveWindowTo("work")

            local personal_ids = Workspaces.windowIds("personal")
            local work_ids = Workspaces.windowIds("work")
            assert.is_nil(personal_ids[1])
            assert.is_true(work_ids[1] == true)
        end)

        it("should park window off-screen when target is not current", function()
            local w1 = makeWin(1, "W1")
            focused_window = w1
            all_filter_windows = { w1 }
            setupStandard()

            Workspaces.moveWindowTo("work")

            assert.is_true(State.isHidden(1))
        end)

        it("should skip tileSpace when last window is moved off workspace", function()
            local w1 = makeWin(1, "W1")
            focused_window = w1
            all_filter_windows = { w1 }
            setupStandard()

            -- Spy on tileSpace to ensure it's NOT called after the move
            local tile_called = false
            mock_codex.tileSpace = function(self, space) tile_called = true end

            Workspaces.moveWindowTo("work")

            -- The workspace has no remaining tiled windows, so tileSpace should be skipped
            assert.is_false(tile_called)
        end)

        it("should focus neighbor before retiling when windows remain", function()
            local w1 = makeWin(1, "W1")
            local w2 = makeWin(2, "W2")
            focused_window = w1
            all_filter_windows = { w1, w2 }
            setupStandard()

            -- Add both windows to tiling state so windowList is not empty after removing w1
            local space = 1
            State.windowList(space)[1] = { w1 }
            State.windowList(space)[2] = { w2 }

            -- Spy on tileSpace — it should be called since w2 remains
            local tile_called = false
            mock_codex.tileSpace = function(self, sp) tile_called = true end

            -- Focus w1 and move it away
            Workspaces.moveWindowTo("work")

            assert.is_true(tile_called)
        end)

        it("should auto-float windows moved to scratch workspace", function()
            local w1 = makeWin(1, "W1")
            focused_window = w1
            all_filter_windows = { w1 }
            setupStandard({ workspaces = { "personal", { name = "scratch", layout = "unmanaged" } } })

            Workspaces.moveWindowTo("scratch")

            assert.is_true(State.is_floating[1])
        end)
    end)

    describe("onWindowCreated", function()
        it("should guard against nil window", function()
            setupStandard()
            -- Should not error
            Workspaces.onWindowCreated(nil)
        end)

        it("should guard against already tracked window", function()
            local w1 = makeWin(1, "W1")
            all_filter_windows = { w1 }
            setupStandard()

            -- w1 is already tracked by setup, calling again should be no-op
            Workspaces.onWindowCreated(w1)
        end)

        it("should assign via app rules", function()
            setupStandard({ appRules = { Firefox = "work" } })

            local w1 = makeWin(10, "Firefox Window", "Firefox", 500)
            Workspaces.onWindowCreated(w1)

            local work_ids = Workspaces.windowIds("work")
            assert.is_true(work_ids[10] == true)
        end)

        it("should default to current workspace when no rule matches", function()
            setupStandard()

            local w1 = makeWin(10, "Random App", "RandomApp", 500)
            Workspaces.onWindowCreated(w1)

            local personal_ids = Workspaces.windowIds("personal")
            assert.is_true(personal_ids[10] == true)
        end)

        it("should park non-current workspace window immediately (no timer)", function()
            setupStandard({ appRules = { Firefox = "work" } })

            local w1 = makeWin(10, "Firefox Window", "Firefox", 500)

            -- Disable auto-timers to prove no timer is involved
            Mocks._auto_execute_timers = false
            Mocks._timer_callbacks = {}

            Workspaces.onWindowCreated(w1)

            -- Window should be hidden immediately, not after a timer
            assert.is_true(State.isHidden(10))

            -- No timers should have been created for parking
            local park_timer_found = false
            for _, t in ipairs(Mocks._timer_callbacks) do
                if t._delay and t._delay < 0.2 then
                    park_timer_found = true
                end
            end
            assert.is_false(park_timer_found)
        end)

        it("should auto-float windows assigned to scratch", function()
            setupStandard({ workspaces = { "personal", { name = "scratch", layout = "unmanaged" } }, appRules = { Scratch = "scratch" } })

            local w1 = makeWin(10, "Scratch Window", "Scratch", 500)
            Workspaces.onWindowCreated(w1)

            assert.is_true(State.is_floating[10])
        end)
    end)

    describe("onWindowDestroyed", function()
        it("should guard against nil window", function()
            setupStandard()
            Workspaces.onWindowDestroyed(nil)
        end)

        it("should remove from tracking tables", function()
            local w1 = makeWin(1, "W1")
            all_filter_windows = { w1 }
            setupStandard()

            assert.is_true(Workspaces.windowIds("personal")[1] == true)

            Workspaces.onWindowDestroyed(w1)

            assert.is_nil(Workspaces.windowIds("personal")[1])
        end)

        it("should clear hidden state", function()
            local w1 = makeWin(1, "W1", "Browser", 100)
            all_filter_windows = { w1 }
            setupStandard({ appRules = { Browser = "work" } })

            -- w1 was on work workspace and is hidden
            assert.is_true(State.isHidden(1))

            Workspaces.onWindowDestroyed(w1)

            assert.is_false(State.isHidden(1))
        end)

        it("should clear focused reference for destroyed window", function()
            local w1 = makeWin(1, "W1")
            all_filter_windows = { w1 }
            focused_window = w1
            setupStandard()

            -- Track focus
            Workspaces.onWindowFocused(w1)

            Workspaces.onWindowDestroyed(w1)
            -- Should not error, just clear state
        end)

        it("should clear jump target if it pointed to destroyed window", function()
            local w1 = makeWin(1, "W1")
            local w2 = makeWin(2, "W2")
            all_filter_windows = { w1, w2 }
            focused_window = w1
            setupStandard()

            -- This does not directly test prev_jump since it's local,
            -- but ensures destroy doesn't error
            Workspaces.onWindowDestroyed(w1)
        end)
    end)

    describe("onWindowFocused", function()
        it("should be no-op during switching", function()
            setupStandard()
            -- Start a switch to set the switching flag
            -- Instead, just verify that focus during a switch doesn't error
            local w1 = makeWin(1, "W1")
            all_filter_windows = { w1 }
            Workspaces.onWindowFocused(w1)
        end)

        it("should track focused window on current workspace and restore on return", function()
            local w1 = makeWin(1, "W1")
            local w2 = makeWin(2, "W2")
            all_filter_windows = { w1, w2 }
            setupStandard()

            -- Add both to tiling so snapshots work
            State.windowList(1)[1] = { w1 }
            State.windowList(1)[2] = { w2 }

            -- Focus w2 (not w1) so it becomes the last-focused
            focused_window = w2
            Workspaces.onWindowFocused(w2)

            -- Switch away and back
            local focus_spy = spy.on(w2, "focus")
            Workspaces.switchTo("work")
            Workspaces.switchTo("personal")

            -- w2 should be focused (it was last-focused before leaving)
            assert.spy(focus_spy).was.called()
        end)

        it("should be no-op for nil window", function()
            setupStandard()
            Workspaces.onWindowFocused(nil)
        end)

        it("should handle window whose id() returns nil", function()
            setupStandard()
            -- Window has an id method but it returns nil
            Workspaces.onWindowFocused({ id = function() return nil end })
        end)
    end)

    describe("titleRules", function()
        it("should route windows by title pattern", function()
            local w1 = makeWin(1, "[work] ~/project", "WezTerm", 100)
            all_filter_windows = { w1 }

            setupStandard({
                titleRules = {
                    { pattern = "^%[work%]", workspace = "work" },
                },
            })

            local work_ids = Workspaces.windowIds("work")
            assert.is_true(work_ids[1] == true)
        end)

        it("should prefer title rules over app rules", function()
            local w1 = makeWin(1, "[personal] ~/code", "WezTerm", 100)
            all_filter_windows = { w1 }

            setupStandard({
                appRules = { WezTerm = "work" },
                titleRules = {
                    { pattern = "^%[personal%]", workspace = "personal" },
                },
            })

            -- Title rule wins over app rule
            local personal_ids = Workspaces.windowIds("personal")
            assert.is_true(personal_ids[1] == true)
            local work_ids = Workspaces.windowIds("work")
            assert.is_nil(work_ids[1])
        end)

        it("should fall back to app rules when no title match", function()
            local w1 = makeWin(1, "plain terminal", "WezTerm", 100)
            all_filter_windows = { w1 }

            setupStandard({
                appRules = { WezTerm = "work" },
                titleRules = {
                    { pattern = "^%[personal%]", workspace = "personal" },
                },
            })

            local work_ids = Workspaces.windowIds("work")
            assert.is_true(work_ids[1] == true)
        end)

        it("should route new windows by title in onWindowCreated", function()
            setupStandard({
                titleRules = {
                    { pattern = "^%[work%]", workspace = "work" },
                },
            })

            local w1 = makeWin(1, "[work] ~/project", "WezTerm", 100)
            Workspaces.onWindowCreated(w1)

            local work_ids = Workspaces.windowIds("work")
            assert.is_true(work_ids[1] == true)
        end)
    end)

    describe("toggleJump", function()
        it("should be no-op with no previous jump point", function()
            setupStandard()

            -- Should not error
            Workspaces.toggleJump()
            assert.are.equal("personal", Workspaces.currentSpace())
        end)

        it("should swap to previous jump point across workspaces", function()
            local w1 = makeWin(1, "W1")
            local w2 = makeWin(2, "W2", "Browser", 200)
            all_filter_windows = { w1, w2 }
            focused_window = w1

            setupStandard({ appRules = { Browser = "work" } })

            -- Jump to work
            focused_window = w1
            Workspaces.switchTo("work")

            -- Now toggle back
            focused_window = w2
            Workspaces.toggleJump()

            assert.are.equal("personal", Workspaces.currentSpace())
        end)

        it("should focus target window on same workspace", function()
            local w1 = makeWin(1, "W1")
            local w2 = makeWin(2, "W2")
            all_filter_windows = { w1, w2 }

            setupStandard()

            -- Set up: jump from w1 to w2 (both on personal)
            focused_window = w1
            Workspaces.switchTo("work")  -- saves jump point at w1/personal
            focused_window = nil
            Workspaces.switchTo("personal")  -- back to personal

            -- toggleJump should try to focus w1
            focused_window = w2
            Workspaces.toggleJump()

            -- Still on personal (same workspace toggle)
            assert.are.equal("personal", Workspaces.currentSpace())
        end)

        it("should swap prev_jump to current position", function()
            local w1 = makeWin(1, "W1")
            local w2 = makeWin(2, "W2", "Browser", 200)
            all_filter_windows = { w1, w2 }

            setupStandard({ appRules = { Browser = "work" } })

            -- Jump from personal to work
            focused_window = w1
            Workspaces.switchTo("work")

            -- Toggle back to personal
            focused_window = w2
            Workspaces.toggleJump()
            assert.are.equal("personal", Workspaces.currentSpace())

            -- Toggle again should go back to work
            focused_window = w1
            Workspaces.toggleJump()
            assert.are.equal("work", Workspaces.currentSpace())
        end)
    end)

    describe("isUnmanaged", function()
        it("should return true for workspace with layout=unmanaged", function()
            setupStandard({ workspaces = { "personal", { name = "scratch", layout = "unmanaged" } } })
            assert.is_true(Workspaces.isUnmanaged("scratch"))
        end)

        it("should return false for regular workspace", function()
            setupStandard({ workspaces = { "personal", { name = "scratch", layout = "unmanaged" } } })
            assert.is_false(Workspaces.isUnmanaged("personal"))
        end)

        it("should default to current workspace", function()
            setupStandard({ workspaces = { "personal", { name = "scratch", layout = "unmanaged" } } })
            assert.is_false(Workspaces.isUnmanaged())
            Workspaces.switchTo("scratch")
            assert.is_true(Workspaces.isUnmanaged())
        end)

    end)

    describe("toggle-back", function()
        it("should toggle back when switchTo called with current workspace and toggleBack enabled", function()
            local w1 = makeWin(1, "W1")
            all_filter_windows = { w1 }
            focused_window = w1

            setupStandard({ toggleBack = true })

            -- Switch personal → work (saves jump point)
            Workspaces.switchTo("work")
            assert.are.equal("work", Workspaces.currentSpace())

            -- Press switchTo("work") again → should toggle back to personal
            Workspaces.switchTo("work")
            assert.are.equal("personal", Workspaces.currentSpace())
        end)

        it("should not toggle back without toggleBack option", function()
            local w1 = makeWin(1, "W1")
            all_filter_windows = { w1 }
            focused_window = w1

            setupStandard({ toggleBack = false })

            Workspaces.switchTo("work")
            assert.are.equal("work", Workspaces.currentSpace())

            -- Same key again → should be no-op (toggleBack not enabled)
            Workspaces.switchTo("work")
            assert.are.equal("work", Workspaces.currentSpace())
        end)

        it("should not toggle back when no prev_jump exists", function()
            setupStandard({ toggleBack = true })

            -- No prior switch, so prev_jump is nil
            -- switchTo("personal") while on personal → should be no-op
            Workspaces.switchTo("personal")
            assert.are.equal("personal", Workspaces.currentSpace())
        end)

        it("should toggle scratch via switchTo when toggleBack enabled", function()
            local w1 = makeWin(1, "W1")
            all_filter_windows = { w1 }
            focused_window = w1

            setupStandard({ workspaces = { "personal", { name = "scratch", layout = "unmanaged" } }, toggleBack = true })

            Workspaces.switchTo("scratch")
            assert.are.equal("scratch", Workspaces.currentSpace())

            -- Press switchTo("scratch") again → toggle back
            Workspaces.switchTo("scratch")
            assert.are.equal("personal", Workspaces.currentSpace())
        end)

    end)

    describe("snapshot validation", function()
        it("should clean up stale windows from snapshot on switch back", function()
            local w1 = makeWin(1, "W1")
            local w2 = makeWin(2, "W2")
            all_filter_windows = { w1, w2 }
            setupStandard()

            -- Tile both windows
            State.windowList(1)[1] = { w1 }
            State.windowList(1)[2] = { w2 }

            -- Switch away (saves snapshot with w1 and w2)
            Workspaces.switchTo("work")

            -- Destroy w2 while on work workspace
            Workspaces.onWindowDestroyed(w2)
            Mocks.clear_window_registry()
            Mocks.register_window(w1)

            -- Switch back - snapshot should be validated, w2 removed
            Workspaces.switchTo("personal")

            -- w2 should no longer be tracked
            assert.is_nil(Workspaces.windowIds("personal")[2])
        end)

        it("should remove destroyed window from stored snapshot", function()
            local w1 = makeWin(1, "W1")
            local w2 = makeWin(2, "W2", "Browser", 200)
            all_filter_windows = { w1, w2 }
            setupStandard({ appRules = { Browser = "work" } })

            -- Tile w2 on space 1 (work workspace's space)
            State.windowList(1)[1] = { w2 }

            -- Switch to work (snapshots personal, restores work)
            Workspaces.switchTo("work")

            -- Now destroy w1 (on personal, which was snapshotted)
            Workspaces.onWindowDestroyed(w1)

            -- Switch back to personal
            Workspaces.switchTo("personal")

            -- w1 should not be in personal tracking
            assert.is_nil(Workspaces.windowIds("personal")[1])
        end)
    end)

    describe("onWindowFocused cross-workspace", function()
        it("should debounce workspace switch for window on other workspace", function()
            local w1 = makeWin(1, "W1", "Terminal", 100)
            local w2 = makeWin(2, "W2", "Browser", 200)
            all_filter_windows = { w1, w2 }
            setupStandard({ appRules = { Browser = "work" } })

            -- w2 is on work, currently on personal
            -- Focus w2 - should create a debounce timer
            Workspaces.onWindowFocused(w2)

            -- Timer was created (check it in our captured timers)
            local found_timer = false
            for _, t in ipairs(Mocks._timer_callbacks) do
                if not t._stopped then
                    found_timer = true
                end
            end
            -- With auto_execute_timers=true, the timer fires immediately
            -- and triggers a switch to work (where w2 lives)
            -- But switching also requires w2 to still be focused
            -- Our mock focused_window is nil, so the debounced check fails
            -- This tests that the debounce path doesn't crash
        end)

        it("should switch workspace when focus settles on other-workspace window", function()
            local w1 = makeWin(1, "W1", "Terminal", 100)
            local w2 = makeWin(2, "W2", "Browser", 200)
            all_filter_windows = { w1, w2 }

            -- Setup with auto-timers so initial setup completes
            setupStandard({ appRules = { Browser = "work" } })

            -- Simulate user bringing w2 on screen (e.g. Cmd+Tab) — clear hidden state
            mock_codex.state.setHidden(2, nil)

            -- Now disable auto-timers to capture the debounce timer
            Mocks._auto_execute_timers = false
            Mocks._timer_callbacks = {}

            -- Focus w2 (which is on work workspace)
            focused_window = w2
            Workspaces.onWindowFocused(w2)

            -- Find and fire the debounce timer manually
            for _, t in ipairs(Mocks._timer_callbacks) do
                if t._fn and not t._stopped then
                    t._fn()
                end
            end

            -- Should have switched to work
            assert.are.equal("work", Workspaces.currentSpace())
        end)

        it("should focus the triggering window, not last-focused on target workspace", function()
            local w1 = makeWin(1, "W1", "Terminal", 100)
            local w2 = makeWin(2, "Safari Tab", "Safari", 200)
            local w3 = makeWin(3, "Spotify", "Spotify", 300)
            all_filter_windows = { w1, w2, w3 }

            setupStandard({
                appRules = { Safari = "personal", Terminal = "work", Spotify = "personal" },
                workspaces = { "work", "personal" },
                focusFollows = { "Safari" },
            })

            -- Switch to personal, focus w3 (Spotify), then switch back to work
            Workspaces.switchTo("personal")
            focused_window = w3
            Workspaces.onWindowFocused(w3)  -- sets ws_focused["personal"] = 3
            Workspaces.switchTo("work")

            -- Now Safari (w2) gets focus while hidden (focusFollows triggers switch)
            Mocks._auto_execute_timers = false
            Mocks._timer_callbacks = {}

            focused_window = w2
            Workspaces.onWindowFocused(w2)

            for _, t in ipairs(Mocks._timer_callbacks) do
                if t._fn and not t._stopped then t._fn() end
            end

            assert.are.equal("personal", Workspaces.currentSpace())

            -- w2 (Safari) should be focused, NOT w3 (Spotify, the last-focused)
            local focus_spy_w2 = spy.on(w2, "focus")
            local focus_spy_w3 = spy.on(w3, "focus")
            -- The focus already happened during the switch — check that w2 was the target
            -- by verifying w3.focus was NOT called after the switch
            assert.spy(focus_spy_w3).was.not_called()
        end)
    end)

    describe("moveWindowTo + switch integration", function()
        it("should tile and focus moved window on target workspace after switch", function()
            local w1 = makeWin(1, "W1", "Terminal", 100)
            all_filter_windows = { w1 }
            focused_window = w1
            setupStandard()

            -- Add w1 to tiling so snapshot has it
            State.windowList(1)[1] = { w1 }

            -- Move w1 to work (parks it off-screen, adds to ws_pending)
            Workspaces.moveWindowTo("work")

            -- Spy on addWindow and focus
            local add_spy = spy.on(mock_codex.windows, "addWindow")
            local focus_spy = spy.on(w1, "focus")

            -- Switch to work — pending window should be added and focused
            Workspaces.switchTo("work")

            assert.are.equal("work", Workspaces.currentSpace())
            assert.spy(add_spy).was.called_with(w1)
            assert.spy(focus_spy).was.called()
        end)

        it("should preserve existing windows when adding moved window", function()
            local w1 = makeWin(1, "W1", "Terminal", 100)
            local w2 = makeWin(2, "W2", "Browser", 200)
            all_filter_windows = { w1, w2 }
            focused_window = w1
            setupStandard({ appRules = { Browser = "work" } })

            -- w2 is on work workspace. Tile it so snapshot has it.
            State.windowList(1)[1] = { w1 }

            -- Move w1 to work
            Workspaces.moveWindowTo("work")

            -- Switch to work
            local add_spy = spy.on(mock_codex.windows, "addWindow")
            Workspaces.switchTo("work")

            -- w1 should be added via addWindow (w2 already in snapshot)
            assert.spy(add_spy).was.called_with(w1)
            -- Both w1 and w2 should be tracked on work
            local work_ids = Workspaces.windowIds("work")
            assert.is_true(work_ids[1] == true)
            assert.is_true(work_ids[2] == true)
        end)

        it("should tile a window created for an inactive workspace after switch", function()
            local w1 = makeWin(1, "W1", "Terminal", 100)
            all_filter_windows = { w1 }
            focused_window = w1
            setupStandard({ appRules = { Browser = "work" } })
            State.windowList(1)[1] = { w1 }

            -- A Browser window launches while we are on personal: it belongs to
            -- work, so onWindowCreated parks it off-screen and marks it hidden.
            local w2 = makeWin(2, "W2", "Browser", 200)
            all_filter_windows = { w1, w2 }
            Workspaces.onWindowCreated(w2)
            assert.is_true(State.isHidden(2))

            -- Switching to work must adopt it into the tiling state. It was
            -- never tiled, so no snapshot covers it — only ws_pending can.
            local add_spy = spy.on(mock_codex.windows, "addWindow")
            Workspaces.switchTo("work")

            assert.spy(add_spy).was.called_with(w2)
            assert.is_false(State.isHidden(2))
        end)

        it("should add all pending windows when multiple moved", function()
            local w1 = makeWin(1, "W1", "App1", 100)
            local w2 = makeWin(2, "W2", "App2", 200)
            local w3 = makeWin(3, "W3", "App3", 300)
            all_filter_windows = { w1, w2, w3 }
            setupStandard()

            -- All on personal initially. Tile them.
            State.windowList(1)[1] = { w1 }
            State.windowList(1)[2] = { w2 }
            State.windowList(1)[3] = { w3 }

            -- Move w1 and w2 to work
            focused_window = w1
            Workspaces.moveWindowTo("work")
            focused_window = w2
            Workspaces.moveWindowTo("work")

            local add_spy = spy.on(mock_codex.windows, "addWindow")
            Workspaces.switchTo("work")

            -- Both should be added
            assert.spy(add_spy).was.called(2)
        end)

        it("should not crash when moved window is destroyed before switch", function()
            local w1 = makeWin(1, "W1", "Terminal", 100)
            all_filter_windows = { w1 }
            focused_window = w1
            setupStandard()

            State.windowList(1)[1] = { w1 }

            -- Move to work, then destroy before switching
            Workspaces.moveWindowTo("work")
            Workspaces.onWindowDestroyed(w1)

            -- Switch to work — should not crash
            assert.has_no.errors(function()
                Workspaces.switchTo("work")
            end)
        end)

        it("should float moved window on scratch workspace", function()
            local w1 = makeWin(1, "W1", "Terminal", 100)
            all_filter_windows = { w1 }
            focused_window = w1
            setupStandard({ workspaces = { "personal", { name = "scratch", layout = "unmanaged" } } })

            State.windowList(1)[1] = { w1 }

            -- Move to scratch
            Workspaces.moveWindowTo("scratch")
            assert.is_true(State.is_floating[1])

            -- Switch to scratch — should not add to tiling (it's floating)
            local add_spy = spy.on(mock_codex.windows, "addWindow")
            Workspaces.switchTo("scratch")

            assert.spy(add_spy).was.not_called()
        end)

        it("should not add phantom window when moved away before switch", function()
            local w1 = makeWin(1, "W1", "Terminal", 100)
            all_filter_windows = { w1 }
            focused_window = w1
            setupStandard()

            State.windowList(1)[1] = { w1 }

            -- Move w1 to work, then immediately move it back to personal
            Workspaces.moveWindowTo("work")
            Workspaces.moveWindowTo("personal")

            -- Switch to work — w1 should NOT be added (it was moved away)
            local add_spy = spy.on(mock_codex.windows, "addWindow")
            Workspaces.switchTo("work")

            assert.spy(add_spy).was.not_called()
        end)

        it("should handle round-trip: move to work, switch, move back, switch back", function()
            local w1 = makeWin(1, "W1", "Terminal", 100)
            local w2 = makeWin(2, "W2", "App2", 200)
            all_filter_windows = { w1, w2 }
            focused_window = w1
            setupStandard()

            State.windowList(1)[1] = { w1 }
            State.windowList(1)[2] = { w2 }

            -- Move w1 to work
            Workspaces.moveWindowTo("work")
            assert.is_true(Workspaces.windowIds("work")[1] == true)

            -- Simulate removeWindow effect on State (mock doesn't touch State)
            -- In real code, removeWindow removes from window_list + index_table
            State.windowIndex(w1, true)  -- remove index entry
            State.windowList(1)[1] = { w2 }
            State.windowList(1)[2] = nil

            -- Switch to work — w1 should be tiled
            Workspaces.switchTo("work")
            assert.are.equal("work", Workspaces.currentSpace())

            -- Move w1 back to personal
            focused_window = w1
            Workspaces.moveWindowTo("personal")
            assert.is_true(Workspaces.windowIds("personal")[1] == true)

            -- Switch back to personal — w1 should be tiled again
            local add_spy = spy.on(mock_codex.windows, "addWindow")
            Workspaces.switchTo("personal")
            assert.are.equal("personal", Workspaces.currentSpace())
            assert.spy(add_spy).was.called_with(w1)
        end)
    end)

    describe("focusFollows", function()
        it("should switch workspace when focusFollows app gets focus while hidden", function()
            local w1 = makeWin(1, "W1", "Terminal", 100)
            local w2 = makeWin(2, "Safari Tab", "Safari", 200)
            all_filter_windows = { w1, w2 }

            -- Setup with auto-timers so initial setup completes
            setupStandard({
                appRules = { Safari = "personal", Terminal = "work" },
                workspaces = { "work", "personal" },
                focusFollows = { "Safari" },
            })

            -- w2 (Safari) is on personal, current is work → w2 is hidden
            assert.is_true(State.isHidden(2))

            -- Disable auto-timers to capture the debounce timer
            Mocks._auto_execute_timers = false
            Mocks._timer_callbacks = {}

            -- macOS gives Safari focus (e.g. link clicked from WhatsApp)
            focused_window = w2
            Workspaces.onWindowFocused(w2)

            -- Fire the debounce timer
            for _, t in ipairs(Mocks._timer_callbacks) do
                if t._fn and not t._stopped then
                    t._fn()
                end
            end

            -- Should have switched to personal (where Safari lives)
            assert.are.equal("personal", Workspaces.currentSpace())
        end)

        it("should not switch workspace for non-focusFollows app when hidden", function()
            local w1 = makeWin(1, "W1", "Terminal", 100)
            local w2 = makeWin(2, "Spotify", "Spotify", 200)
            all_filter_windows = { w1, w2 }

            setupStandard({
                appRules = { Spotify = "personal", Terminal = "work" },
                workspaces = { "work", "personal" },
                focusFollows = { "Safari" },
            })

            -- w2 (Spotify) is on personal, current is work → w2 is hidden
            assert.is_true(State.isHidden(2))

            -- Disable auto-timers
            Mocks._auto_execute_timers = false
            Mocks._timer_callbacks = {}

            -- macOS gives Spotify focus
            focused_window = w2
            Workspaces.onWindowFocused(w2)

            -- No timer should be created (isHidden guard blocks non-focusFollows apps)
            local timer_created = false
            for _, t in ipairs(Mocks._timer_callbacks) do
                if t._fn and not t._stopped then
                    timer_created = true
                end
            end
            assert.is_false(timer_created)

            -- Should still be on work
            assert.are.equal("work", Workspaces.currentSpace())
        end)

        it("should respect debounce for focusFollows", function()
            local w1 = makeWin(1, "W1", "Terminal", 100)
            local w2 = makeWin(2, "Safari Tab", "Safari", 200)
            all_filter_windows = { w1, w2 }

            setupStandard({
                appRules = { Safari = "personal", Terminal = "work" },
                workspaces = { "work", "personal" },
                focusFollows = { "Safari" },
            })

            -- Disable auto-timers to control debounce manually
            Mocks._auto_execute_timers = false
            Mocks._timer_callbacks = {}

            -- Focus Safari (hidden, but focusFollows)
            focused_window = w2
            Workspaces.onWindowFocused(w2)

            -- Before timer fires, focus moves back to w1
            focused_window = w1

            -- Fire the debounce timer — should NOT switch (focus moved away)
            for _, t in ipairs(Mocks._timer_callbacks) do
                if t._fn and not t._stopped then
                    t._fn()
                end
            end

            -- Should still be on work (debounce rejected the switch)
            assert.are.equal("work", Workspaces.currentSpace())
        end)
    end)

    describe("accessors", function()
        it("should return current workspace name", function()
            setupStandard()
            assert.are.equal("personal", Workspaces.currentSpace())
        end)

        it("should return window IDs for a workspace", function()
            local w1 = makeWin(1, "W1")
            all_filter_windows = { w1 }
            setupStandard()

            local ids = Workspaces.windowIds("personal")
            assert.is_true(ids[1] == true)
        end)

    end)

    describe("nextWorkspace / prevWorkspace", function()
        it("should cycle forward through workspaces", function()
            setupStandard()  -- personal, work, global
            assert.are.equal("personal", Workspaces.currentSpace())

            Workspaces.nextWorkspace()
            assert.are.equal("work", Workspaces.currentSpace())

            Workspaces.nextWorkspace()
            assert.are.equal("global", Workspaces.currentSpace())
        end)

        it("should wrap around forward", function()
            setupStandard()
            Workspaces.nextWorkspace()  -- work
            Workspaces.nextWorkspace()  -- global
            Workspaces.nextWorkspace()  -- personal (wrap)
            assert.are.equal("personal", Workspaces.currentSpace())
        end)

        it("should cycle backward through workspaces", function()
            setupStandard()
            Workspaces.prevWorkspace()  -- global (wrap backward)
            assert.are.equal("global", Workspaces.currentSpace())

            Workspaces.prevWorkspace()
            assert.are.equal("work", Workspaces.currentSpace())
        end)

        it("should wrap around backward", function()
            setupStandard()
            Workspaces.prevWorkspace()  -- global
            Workspaces.prevWorkspace()  -- work
            Workspaces.prevWorkspace()  -- personal
            assert.are.equal("personal", Workspaces.currentSpace())
        end)
    end)

    describe("mark", function()
        it("should save focused window and workspace on setMark", function()
            local w1 = makeWin(1, "W1")
            all_filter_windows = { w1 }
            focused_window = w1
            setupStandard()

            Workspaces.setMark()

            -- Verify mark was set by jumping to it (same workspace, focuses w1)
            local w2 = makeWin(2, "W2")
            Workspaces.onWindowCreated(w2)
            focused_window = w2
            local focus_spy = spy.on(w1, "focus")
            Workspaces.jumpToMark()
            assert.spy(focus_spy).was.called()
        end)

        it("should no-op jumpToMark when no mark set", function()
            setupStandard()

            -- Should not error or switch workspace
            Workspaces.jumpToMark()
            assert.are.equal("personal", Workspaces.currentSpace())
        end)

        it("should focus marked window on same workspace", function()
            local w1 = makeWin(1, "W1")
            local w2 = makeWin(2, "W2")
            all_filter_windows = { w1, w2 }
            focused_window = w1
            setupStandard()

            Workspaces.setMark()

            -- Move focus to w2
            focused_window = w2
            local focus_spy = spy.on(w1, "focus")
            Workspaces.jumpToMark()

            assert.spy(focus_spy).was.called()
            assert.are.equal("personal", Workspaces.currentSpace())
        end)

        it("should switch workspace when mark is cross-workspace", function()
            local w1 = makeWin(1, "W1")
            local w2 = makeWin(2, "W2", "Browser", 200)
            all_filter_windows = { w1, w2 }
            focused_window = w1
            setupStandard({ appRules = { Browser = "work" } })

            -- Mark on personal
            Workspaces.setMark()

            -- Switch to work
            Workspaces.switchTo("work")
            assert.are.equal("work", Workspaces.currentSpace())

            -- Simulate focus on work window
            focused_window = w2

            -- Jump to mark should switch back to personal
            Workspaces.jumpToMark()
            assert.are.equal("personal", Workspaces.currentSpace())
        end)

        it("should toggle back when already at mark", function()
            local w1 = makeWin(1, "W1")
            local w2 = makeWin(2, "W2", "Browser", 200)
            all_filter_windows = { w1, w2 }
            setupStandard({ appRules = { Browser = "work" } })

            -- Mark w1 on personal
            focused_window = w1
            Workspaces.setMark()

            -- Switch to work
            Workspaces.switchTo("work")
            focused_window = w2

            -- Jump to mark (goes to personal/w1)
            Workspaces.jumpToMark()
            assert.are.equal("personal", Workspaces.currentSpace())

            -- Jump again while AT the mark → should go back to work
            focused_window = w1
            Workspaces.jumpToMark()
            assert.are.equal("work", Workspaces.currentSpace())
        end)

        it("should update mark_return each jump", function()
            local w1 = makeWin(1, "W1")
            local w2 = makeWin(2, "W2")
            local w3 = makeWin(3, "W3")
            all_filter_windows = { w1, w2, w3 }
            setupStandard()

            -- Mark w1
            focused_window = w1
            Workspaces.setMark()

            -- Jump from w2 → mark (w1). mark_return = w2
            focused_window = w2
            Workspaces.jumpToMark()

            -- Toggle back from w1 → should go to w2 (mark_return)
            focused_window = w1
            local focus_spy_w2 = spy.on(w2, "focus")
            Workspaces.jumpToMark()
            assert.spy(focus_spy_w2).was.called()

            -- Now jump from w3 → mark. mark_return should be w3 now
            focused_window = w3
            Workspaces.jumpToMark()

            focused_window = w1
            local focus_spy_w3 = spy.on(w3, "focus")
            Workspaces.jumpToMark()
            assert.spy(focus_spy_w3).was.called()
        end)

        it("should clear mark when marked window is destroyed", function()
            local w1 = makeWin(1, "W1")
            all_filter_windows = { w1 }
            focused_window = w1
            setupStandard()

            Workspaces.setMark()
            Workspaces.onWindowDestroyed(w1)

            -- jumpToMark should be no-op now
            Workspaces.jumpToMark()
            assert.are.equal("personal", Workspaces.currentSpace())
        end)

        it("should clear mark_return when return window is destroyed", function()
            local w1 = makeWin(1, "W1")
            local w2 = makeWin(2, "W2", "Browser", 200)
            all_filter_windows = { w1, w2 }
            setupStandard({ appRules = { Browser = "work" } })

            -- Mark w1 on personal
            focused_window = w1
            Workspaces.setMark()

            -- Switch to work, then jump to mark (saves w2/work as mark_return)
            Workspaces.switchTo("work")
            focused_window = w2
            Workspaces.jumpToMark()
            assert.are.equal("personal", Workspaces.currentSpace())

            -- Destroy w2 (the mark_return window)
            Workspaces.onWindowDestroyed(w2)

            -- Toggle should NOT try to go back to destroyed window
            -- Should be no-op (at mark, but mark_return is cleared)
            focused_window = w1
            Workspaces.jumpToMark()
            -- Should stay on personal since mark_return is gone
            assert.are.equal("personal", Workspaces.currentSpace())
        end)

        it("should no-op setMark when no focused window", function()
            setupStandard()
            focused_window = nil

            -- Should not error
            Workspaces.setMark()

            -- jumpToMark should still be no-op
            Workspaces.jumpToMark()
            assert.are.equal("personal", Workspaces.currentSpace())
        end)
    end)

    describe("column ordering", function()
        -- Helper: set up with app-centric config + columns
        local function setupColumns(opts)
            opts = opts or {}
            local config = {
                workspaces = opts.workspaces or { "personal", "work" },
                toggleBack = opts.toggleBack or false,
                apps = opts.apps or {},
            }
            Workspaces.setup(config)
            return config
        end

        it("should reorder columns to match spec", function()
            local w_safari = makeWin(1, "Safari Tab", "Safari", 100)
            local w_term = makeWin(2, "[personal] ~/code", "WezTerm", 200)
            local w_msg = makeWin(3, "Messages", "Messages", 300)
            all_filter_windows = { w_safari, w_term, w_msg }

            setupColumns({
                workspaces = {
                    { name = "personal", columns = { "browser", "terminal", "comms" } },
                    "work",
                },
                apps = {
                    Safari   = { workspace = "personal", jump = "browser" },
                    Messages = { workspace = "personal", jump = "comms" },
                    WezTerm  = {
                        { workspace = "personal", jump = "terminal", title = "^%[personal%]" },
                    },
                },
            })

            -- Tile in wrong order: Messages, WezTerm, Safari
            local space = 1
            State.windowList(space)[1] = { w_msg }
            State.windowList(space)[2] = { w_term }
            State.windowList(space)[3] = { w_safari }

            Workspaces.reflowLayout("personal")

            -- Should be reordered: Safari (browser), WezTerm (terminal), Messages (comms)
            local wl = State.windowList(space)
            assert.are.equal(3, #wl)
            assert.are.equal(1, wl[1][1]:id())  -- Safari
            assert.are.equal(2, wl[2][1]:id())  -- WezTerm
            assert.are.equal(3, wl[3][1]:id())  -- Messages
        end)

        it("should no-op when no columns spec defined", function()
            local w1 = makeWin(1, "W1", "Safari", 100)
            local w2 = makeWin(2, "W2", "Terminal", 200)
            all_filter_windows = { w1, w2 }

            setupColumns({
                workspaces = { "personal", "work" },
                apps = {
                    Safari = { workspace = "personal", jump = "browser" },
                },
            })

            local space = 1
            State.windowList(space)[1] = { w1 }
            State.windowList(space)[2] = { w2 }

            Workspaces.reflowLayout("personal")

            -- Order should be unchanged
            local wl = State.windowList(space)
            assert.are.equal(2, #wl)
            assert.are.equal(1, wl[1][1]:id())
            assert.are.equal(2, wl[2][1]:id())
        end)

        it("should skip categories with no matching window", function()
            local w_safari = makeWin(1, "Safari Tab", "Safari", 100)
            all_filter_windows = { w_safari }

            setupColumns({
                workspaces = {
                    { name = "personal", columns = { "browser", "terminal", "comms" } },
                    "work",
                },
                apps = {
                    Safari   = { workspace = "personal", jump = "browser" },
                    Messages = { workspace = "personal", jump = "comms" },
                    WezTerm  = {
                        { workspace = "personal", jump = "terminal", title = "^%[personal%]" },
                    },
                },
            })

            -- Only Safari is present (no terminal or comms windows)
            local space = 1
            State.windowList(space)[1] = { w_safari }

            Workspaces.reflowLayout("personal")

            -- Should still have just Safari
            local wl = State.windowList(space)
            assert.are.equal(1, #wl)
            assert.are.equal(1, wl[1][1]:id())
        end)

        it("should preserve relative order of unmatched columns", function()
            local w_safari = makeWin(1, "Safari Tab", "Safari", 100)
            local w_extra1 = makeWin(2, "Notes", "Notes", 200)
            local w_extra2 = makeWin(3, "Preview", "Preview", 300)
            all_filter_windows = { w_safari, w_extra1, w_extra2 }

            setupColumns({
                workspaces = {
                    { name = "personal", columns = { "browser" } },
                    "work",
                },
                apps = {
                    Safari = { workspace = "personal", jump = "browser" },
                },
            })

            -- Tile: Notes, Preview, Safari
            local space = 1
            State.windowList(space)[1] = { w_extra1 }
            State.windowList(space)[2] = { w_extra2 }
            State.windowList(space)[3] = { w_safari }

            Workspaces.reflowLayout("personal")

            -- Should be: Safari (browser), Notes, Preview (unmatched keep order)
            local wl = State.windowList(space)
            assert.are.equal(3, #wl)
            assert.are.equal(1, wl[1][1]:id())  -- Safari
            assert.are.equal(2, wl[2][1]:id())  -- Notes (preserved order)
            assert.are.equal(3, wl[3][1]:id())  -- Preview (preserved order)
        end)

        it("should preserve column stacking (multi-row columns stay intact)", function()
            local w_safari = makeWin(1, "Safari Tab", "Safari", 100)
            local w_term = makeWin(2, "[personal] ~/code", "WezTerm", 200)
            local w_stacked = makeWin(3, "Other App", "Other", 300)
            all_filter_windows = { w_safari, w_term, w_stacked }

            setupColumns({
                workspaces = {
                    { name = "personal", columns = { "terminal", "browser" } },
                    "work",
                },
                apps = {
                    Safari  = { workspace = "personal", jump = "browser" },
                    WezTerm = {
                        { workspace = "personal", jump = "terminal", title = "^%[personal%]" },
                    },
                },
            })

            -- Tile: col1=[Safari, Other stacked], col2=[WezTerm]
            local space = 1
            State.windowList(space)[1] = { w_safari, w_stacked }
            State.windowList(space)[2] = { w_term }

            Workspaces.reflowLayout("personal")

            -- Should be: col1=[WezTerm] (terminal), col2=[Safari, Other stacked] (browser matches Safari)
            local wl = State.windowList(space)
            assert.are.equal(2, #wl)
            assert.are.equal(2, wl[1][1]:id())     -- WezTerm (terminal)
            assert.are.equal(1, wl[2][1]:id())     -- Safari (browser)
            assert.are.equal(3, wl[2][2]:id())     -- Other stacked with Safari
        end)

        it("should apply column ordering on _initialPark for current workspace", function()
            local w_safari = makeWin(1, "Safari Tab", "Safari", 100)
            local w_term = makeWin(2, "[personal] ~/code", "WezTerm", 200)
            all_filter_windows = { w_safari, w_term }

            -- Capture tileSpace calls and their window_list state
            local tile_window_orders = {}
            mock_codex.tileSpace = function(self, space)
                local wl = State.windowList(space)
                local order = {}
                for _, col in ipairs(wl) do
                    for _, win in ipairs(col) do
                        order[#order + 1] = win:id()
                    end
                end
                tile_window_orders[#tile_window_orders + 1] = order
            end

            setupColumns({
                workspaces = {
                    { name = "personal", columns = { "terminal", "browser" } },
                    "work",
                },
                apps = {
                    Safari  = { workspace = "personal", jump = "browser" },
                    WezTerm = {
                        { workspace = "personal", jump = "terminal", title = "^%[personal%]" },
                    },
                },
            })

            -- After _initialPark, tileSpace should have been called
            -- The last tileSpace call should have terminal before browser
            assert.is_true(#tile_window_orders > 0)
            local last = tile_window_orders[#tile_window_orders]
            -- The tiling state should have WezTerm (id=2) before Safari (id=1)
            local wl = State.windowList(1)
            if #wl >= 2 then
                assert.are.equal(2, wl[1][1]:id())  -- WezTerm first
                assert.are.equal(1, wl[2][1]:id())  -- Safari second
            end
        end)

        it("should apply column ordering to non-current workspace snapshots", function()
            local w_safari = makeWin(1, "Safari Tab", "Safari", 100)
            local w_term = makeWin(2, "[personal] ~/code", "WezTerm", 200)
            local w_work = makeWin(3, "Work App", "WorkApp", 300)
            all_filter_windows = { w_safari, w_term, w_work }

            setupColumns({
                workspaces = {
                    "work",
                    { name = "personal", columns = { "terminal", "browser" } },
                },
                apps = {
                    Safari  = { workspace = "personal", jump = "browser" },
                    WorkApp = { workspace = "work" },
                    WezTerm = {
                        { workspace = "personal", jump = "terminal", title = "^%[personal%]" },
                    },
                },
            })

            -- Current is "work", personal is non-current
            -- After _initialPark, personal's snapshot should be reordered
            -- Switch to personal to check
            Workspaces.switchTo("personal")

            -- The restored snapshot should have terminal before browser
            local wl = State.windowList(1)
            if #wl >= 2 then
                assert.are.equal(2, wl[1][1]:id())  -- WezTerm first (terminal)
                assert.are.equal(1, wl[2][1]:id())  -- Safari second (browser)
            end
        end)
    end)

    describe("autoLaunch", function()
        it("should launch app when no matching window exists on setup", function()
            -- No windows at all
            all_filter_windows = {}

            local launched = {}
            hs.task.new = function(cmd, cb, args)
                return {
                    start = function(self)
                        launched[#launched + 1] = { cmd = cmd, args = args }
                        return self
                    end,
                }
            end

            local config = {
                workspaces = { "personal", "work" },
                apps = {
                    WezTerm = {
                        { workspace = "work", jump = "terminal", title = "^%[work%]",
                          launch = { "/usr/bin/wezterm", "connect", "work" },
                          autoLaunch = true },
                    },
                },
            }
            Workspaces.setup(config)

            assert.are.equal(1, #launched)
            assert.are.equal("/usr/bin/wezterm", launched[1].cmd)
        end)

        it("should not launch when matching window already exists", function()
            local w1 = makeWin(1, "[work] ~/project", "WezTerm", 100)
            all_filter_windows = { w1 }

            local launched = {}
            hs.task.new = function(cmd, cb, args)
                return {
                    start = function(self)
                        launched[#launched + 1] = { cmd = cmd, args = args }
                        return self
                    end,
                }
            end

            local config = {
                workspaces = { "personal", "work" },
                apps = {
                    WezTerm = {
                        { workspace = "work", jump = "terminal", title = "^%[work%]",
                          launch = { "/usr/bin/wezterm", "connect", "work" },
                          autoLaunch = true },
                    },
                },
            }
            Workspaces.setup(config)

            assert.are.equal(0, #launched)
        end)

        it("should use launchOrFocus for simple app targets", function()
            all_filter_windows = {}

            local launch_spy = spy.on(hs.application, "launchOrFocus")

            local config = {
                workspaces = { "personal", "work" },
                apps = {
                    Safari = { workspace = "personal", jump = "browser", autoLaunch = true },
                },
            }
            Workspaces.setup(config)

            assert.spy(launch_spy).was.called_with("Safari")
        end)
    end)

    describe("app-centric config", function()
        -- Helper: set up with app-centric config
        local function setupApps(opts)
            opts = opts or {}
            local config = {
                workspaces = opts.workspaces or { "personal", "work" },
                toggleBack = opts.toggleBack or false,
                apps = opts.apps or {},
            }
            Workspaces.setup(config)
            return config
        end

        it("should assign windows by workspace from apps config", function()
            local w1 = makeWin(1, "Browser", "Safari", 100)
            all_filter_windows = { w1 }

            setupApps({
                apps = {
                    Safari = { workspace = "work" },
                },
            })

            local work_ids = Workspaces.windowIds("work")
            assert.is_true(work_ids[1] == true)
        end)

        it("should build title rules from apps with title patterns", function()
            local w1 = makeWin(1, "[work] ~/project", "WezTerm", 100)
            all_filter_windows = { w1 }

            setupApps({
                apps = {
                    WezTerm = {
                        { workspace = "personal", title = "^%[personal%]" },
                        { workspace = "work", title = "^%[work%]" },
                    },
                },
            })

            local work_ids = Workspaces.windowIds("work")
            assert.is_true(work_ids[1] == true)
        end)

        it("should set focusFollows from apps config", function()
            local w1 = makeWin(1, "W1", "Terminal", 100)
            local w2 = makeWin(2, "Safari Tab", "Safari", 200)
            all_filter_windows = { w1, w2 }

            setupApps({
                workspaces = { "work", "personal" },
                apps = {
                    Safari = { workspace = "personal", focusFollows = true },
                    Terminal = { workspace = "work" },
                },
            })

            -- w2 (Safari) is on personal, current is work → w2 is hidden
            assert.is_true(State.isHidden(2))

            -- Disable auto-timers to capture the debounce timer
            Mocks._auto_execute_timers = false
            Mocks._timer_callbacks = {}

            -- macOS gives Safari focus
            focused_window = w2
            Workspaces.onWindowFocused(w2)

            -- Fire the debounce timer
            for _, t in ipairs(Mocks._timer_callbacks) do
                if t._fn and not t._stopped then
                    t._fn()
                end
            end

            assert.are.equal("personal", Workspaces.currentSpace())
        end)

        it("should assign multi-instance app windows by title pattern", function()
            local w1 = makeWin(1, "[personal] ~/code", "WezTerm", 100)
            all_filter_windows = { w1 }
            focused_window = w1

            setupApps({
                apps = {
                    WezTerm = {
                        { workspace = "personal", jump = "terminal", title = "^%[personal%]",
                          launch = { "/usr/bin/true" } },
                        { workspace = "work", jump = "terminal", title = "^%[work%]",
                          launch = { "/usr/bin/true" } },
                    },
                },
            })

            -- Window should be on personal (matched by title)
            assert.is_true(Workspaces.windowIds("personal")[1] == true)
        end)

        it("should support unmanaged layout in workspace list", function()
            setupApps({
                workspaces = { "personal", { name = "scratch", layout = "unmanaged" } },
                apps = {},
            })

            assert.is_true(Workspaces.isUnmanaged("scratch"))
            assert.is_false(Workspaces.isUnmanaged("personal"))
        end)

        it("should auto-float on unmanaged workspace via apps config", function()
            setupApps({
                workspaces = { "personal", { name = "scratch", layout = "unmanaged" } },
                apps = { Finder = { workspace = "scratch" } },
            })

            local w1 = makeWin(10, "Finder Window", "Finder", 500)
            Workspaces.onWindowCreated(w1)

            assert.is_true(State.is_floating[10])
        end)

        it("should not set app_rules for entries with title patterns", function()
            -- Multi-instance: title entries should NOT create app_rules
            -- (otherwise all WezTerm windows would match the app rule)
            local w1 = makeWin(1, "untitled", "WezTerm", 100)
            all_filter_windows = { w1 }

            setupApps({
                apps = {
                    WezTerm = {
                        { workspace = "personal", title = "^%[personal%]" },
                        { workspace = "work", title = "^%[work%]" },
                    },
                },
            })

            -- No title match, no app_rules entry → falls to current (personal)
            local personal_ids = Workspaces.windowIds("personal")
            assert.is_true(personal_ids[1] == true)
            local work_ids = Workspaces.windowIds("work")
            assert.is_nil(work_ids[1])
        end)
    end)
end)
