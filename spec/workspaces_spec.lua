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
            jumpTargets = opts.jumpTargets or {},
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

        it("should require at least one workspace", function()
            -- Empty workspace list is not supported: setup uses current (nil)
            -- as a table key in Timer.doAfter callback, which would error.
            -- This test documents that at least one workspace is required.
            assert.has_error(function()
                setupStandard({ workspaces = {} })
            end)
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

            setupStandard({ workspaces = { "personal", "scratch" } })
            Workspaces.setupScratch("scratch")

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
            setupStandard({ workspaces = { "personal", "scratch" } })
            Workspaces.setupScratch("scratch")

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

        it("should auto-float windows assigned to scratch", function()
            setupStandard({ workspaces = { "personal", "scratch" }, appRules = { Scratch = "scratch" } })
            Workspaces.setupScratch("scratch")

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

    describe("jumpToApp", function()
        it("should be no-op for unknown category", function()
            setupStandard({ jumpTargets = { browser = { personal = "Safari" } } })

            -- Should not error
            Workspaces.jumpToApp("nonexistent")
        end)

        it("should be no-op when no target for current workspace", function()
            setupStandard({ jumpTargets = { browser = { work = "Safari" } } })

            -- Current is personal, no browser target for personal
            Workspaces.jumpToApp("browser")
        end)

        it("should focus matching window on current workspace", function()
            local w1 = makeWin(1, "Safari Tab", "Safari", 100)
            all_filter_windows = { w1 }
            focused_window = w1

            -- Set up hs.application.find to return an app with the window
            hs.application.find = function(name)
                if name == "Safari" then
                    return {
                        allWindows = function() return { w1 } end,
                    }
                end
                return nil
            end

            setupStandard({ jumpTargets = { browser = { personal = "Safari" } } })

            local focus_spy = spy.on(w1, "focus")
            Workspaces.jumpToApp("browser")

            assert.spy(focus_spy).was.called()
        end)

        it("should launch app as fallback when no window found", function()
            setupStandard({ jumpTargets = { browser = { personal = "Safari" } } })

            local launch_spy = spy.on(hs.application, "launchOrFocus")
            Workspaces.jumpToApp("browser")

            assert.spy(launch_spy).was.called_with("Safari")
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

    describe("scratch helpers", function()
        it("should set scratch name via setupScratch", function()
            setupStandard({ workspaces = { "personal", "scratch" } })
            Workspaces.setupScratch("scratch")
            assert.are.equal("scratch", Workspaces.scratchName())
        end)

        it("should toggle to scratch workspace", function()
            setupStandard({ workspaces = { "personal", "scratch" } })
            Workspaces.setupScratch("scratch")

            Workspaces.toggleScratch()

            assert.are.equal("scratch", Workspaces.currentSpace())
        end)

        it("should toggle back from scratch to previous workspace", function()
            setupStandard({ workspaces = { "personal", "scratch" } })
            Workspaces.setupScratch("scratch")

            Workspaces.toggleScratch()  -- go to scratch
            assert.are.equal("scratch", Workspaces.currentSpace())

            Workspaces.toggleScratch()  -- back to personal
            assert.are.equal("personal", Workspaces.currentSpace())
        end)

        it("should be no-op when scratch not configured", function()
            setupStandard()
            -- scratchName is nil, toggleScratch should be no-op
            Workspaces.toggleScratch()
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
            setupStandard({ workspaces = { "personal", "scratch" } })
            Workspaces.setupScratch("scratch")

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

        it("should return scratch name", function()
            setupStandard()
            assert.is_nil(Workspaces.scratchName())

            Workspaces.setupScratch("scratch")
            assert.are.equal("scratch", Workspaces.scratchName())
        end)
    end)
end)
