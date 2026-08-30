---@diagnostic disable

package.preload["mocks"] = function() return dofile("spec/mocks.lua") end

describe("Codex.windows", function()
    local Mocks = require("mocks")
    Mocks.init_mocks()

    local Windows = require("windows")
    local State = require("state")
    local Tiling = require("tiling")
    local Floating = require("floating")

    local mock_codex = Mocks.get_mock_codex({ Windows = Windows, State = State, Tiling = Tiling, Floating = Floating })
    local mock_window = Mocks.mock_window

    local focused_window

    before_each(function()
        -- Reset state before each test
        State.init(mock_codex)
        Windows.init(mock_codex)
        Floating.init(mock_codex)
        Tiling.init(mock_codex)
        hs.window.focusedWindow = function() return focused_window end
    end)

    describe("addWindow", function()
        it("should add a window to the state", function()
            local win = mock_window(101, "Test Window")
            local space = Windows.addWindow(win)

            local state = State.get()
            assert.are.equal(1, space)
            assert.are.equal(1, #state.window_list[space])
            assert.are.equal(1, #state.window_list[space][1])
            assert.are.equal(win, state.window_list[space][1][1])
            assert.is_not_nil(state.index_table[101])
            assert.are.equal(1, state.index_table[101].col)
            assert.are.equal(1, state.index_table[101].row)
            assert.is_not_nil(state.ui_watchers[101])
        end)

        it("should add first tab window when no duplicate tracked", function()
            local win = mock_window(101, "Test Window", nil)
            win.tabCount = function() return 2 end

            local space = Windows.addWindow(win)

            local state = State.get()
            assert.are.equal(1, space)
            assert.is_not_nil(state.index_table[101])
        end)

        it("should skip duplicate tab window from same app at same frame", function()
            local frame = { x = 0, y = 0, w = 100, h = 100 }
            local win1 = mock_window(101, "Tab 1", frame, "Ghostty", 5000)
            win1.tabCount = function() return 2 end
            Windows.addWindow(win1)

            local win2 = mock_window(102, "Tab 2", frame, "Ghostty", 5000)
            win2.tabCount = function() return 2 end
            local space = Windows.addWindow(win2)

            local state = State.get()
            assert.is_nil(space)
            assert.is_nil(state.index_table[102])
            -- Original still tracked
            assert.is_not_nil(state.index_table[101])
        end)

        it("should add tab window from different app at same frame", function()
            local frame = { x = 0, y = 0, w = 100, h = 100 }
            local win1 = mock_window(101, "Tab 1", frame, "Ghostty", 5000)
            win1.tabCount = function() return 2 end
            Windows.addWindow(win1)

            local win2 = mock_window(102, "Tab 1", frame, "Safari", 6000)
            win2.tabCount = function() return 3 end
            local space = Windows.addWindow(win2)

            local state = State.get()
            assert.are.equal(1, space)
            assert.is_not_nil(state.index_table[102])
        end)

        it("should add window with tabCount of 1", function()
            local win = mock_window(101, "Test Window", nil)
            win.tabCount = function() return 1 end

            local space = Windows.addWindow(win)

            local state = State.get()
            assert.are.equal(1, space)
            assert.is_not_nil(state.index_table[101])
        end)

        it("should add window with tabCount of 0", function()
            local win = mock_window(101, "Test Window", nil)
            win.tabCount = function() return 0 end

            local space = Windows.addWindow(win)

            local state = State.get()
            assert.are.equal(1, space)
            assert.is_not_nil(state.index_table[101])
        end)
    end)


    describe("addWindowsInOrder", function()
        it("should add windows from left to right", function()
            local win1 = mock_window(101, "Window 1", { x = 0, y = 0, w = 100, h = 100 })
            local win2 = mock_window(102, "Window 2", { x = 200, y = 0, w = 100, h = 100 })
            Windows.addWindow(win1)
            Windows.addWindow(win2)

            local state = State.get()
            assert.are.equal(win1, state.window_list[1][1][1])
            assert.are.equal(win2, state.window_list[1][2][1])
        end)
    end)

    describe("removeWindow", function()
        it("should remove a window from the state", function()
            local win = mock_window(101, "Test Window")
            Windows.addWindow(win)

            local space = Windows.removeWindow(win, true)

            local state = State.get()
            assert.are.equal(1, space)
            assert.is_nil(state.window_list[space])
            assert.is_nil(state.index_table[101])
            assert.is_nil(state.ui_watchers[101])
        end)
    end)

    describe("tab switch", function()
        it("should replace window in-place when tab switches in same app", function()
            -- Set up: three windows tiled left to right
            local frame = { x = 200, y = 0, w = 100, h = 100 }
            local win1 = mock_window(101, "Window 1", { x = 0, y = 0, w = 100, h = 100 })
            local win2 = mock_window(102, "Tab 1", frame, "Ghostty", 5000)
            local win3 = mock_window(103, "Window 3", { x = 400, y = 0, w = 100, h = 100 })
            Windows.addWindow(win1)
            Windows.addWindow(win2)
            Windows.addWindow(win3)

            local state = State.get()
            assert.are.equal(win2, state.window_list[1][2][1]) -- win2 is in col 2

            -- Simulate tab switch: old tab removed, new tab from same app at same frame
            Windows.removeWindow(win2, true)
            local win2b = mock_window(104, "Tab 2", frame, "Ghostty", 5000)
            local space = Windows.addWindow(win2b)

            state = State.get()
            assert.are.equal(1, space)
            assert.are.equal(3, #state.window_list[1])      -- still 3 columns
            assert.are.equal(win1, state.window_list[1][1][1])  -- col 1 unchanged
            assert.are.equal(win2b, state.window_list[1][2][1]) -- col 2 is new tab
            assert.are.equal(win3, state.window_list[1][3][1])  -- col 3 unchanged
        end)

        it("should not replace when app differs", function()
            local frame = { x = 200, y = 0, w = 100, h = 100 }
            local win1 = mock_window(101, "Tab 1", frame, "Ghostty", 5000)
            Windows.addWindow(win1)

            Windows.removeWindow(win1, true)
            -- Different app (different pid)
            local win2 = mock_window(102, "Other App", frame, "Safari", 6000)
            Windows.addWindow(win2)

            local state = State.get()
            -- Should still be added (just at normal position), not rejected
            assert.is_not_nil(state.index_table[102])
        end)

        it("should not replace when frame differs", function()
            local win1 = mock_window(101, "Tab 1", { x = 200, y = 0, w = 100, h = 100 }, "Ghostty", 5000)
            Windows.addWindow(win1)

            Windows.removeWindow(win1, true)
            -- Same app but different frame
            local win2 = mock_window(102, "Tab 2", { x = 300, y = 0, w = 100, h = 100 }, "Ghostty", 5000)
            Windows.addWindow(win2)

            local state = State.get()
            assert.is_not_nil(state.index_table[102])
        end)
    end)

    describe("swapWindows", function()
        it("should swap two windows horizontally", function()
            local win1 = mock_window(101, "Window 1", { x = 0, y = 0, w = 100, h = 100 })
            local win2 = mock_window(102, "Window 2", { x = 200, y = 0, w = 100, h = 100 })
            Windows.addWindow(win1)
            Windows.addWindow(win2)
            focused_window = win1

            Windows.swapWindows(Windows.Direction.RIGHT)

            local state = State.get()
            assert.are.equal(win2, state.window_list[1][1][1])
            assert.are.equal(win1, state.window_list[1][2][1])
        end)

        it("should swap two windows vertically", function()
            local win1 = mock_window(101, "Window 1", { x = 0, y = 0, w = 100, h = 100, y2 = 100 })
            local win2 = mock_window(102, "Window 2", { x = 0, y = 108, w = 100, h = 100, y2 = 208 })
            Windows.addWindow(win1)
            -- manually add win2 to the same column
            table.insert(State.windowList(1, 1), win2)
            focused_window = win1

            Windows.swapWindows(Windows.Direction.DOWN)

            local state = State.get()
            assert.are.equal(win2, state.window_list[1][1][1])
            assert.are.equal(win1, state.window_list[1][1][2])
        end)
    end)

    describe("slurpWindow", function()
        it("should move the focused window into the column on the left", function()
            local win1 = mock_window(101, "Window 1", { x = 0, y = 0, w = 100, h = 100 })
            local win2 = mock_window(102, "Window 2", { x = 200, y = 0, w = 100, h = 100 })
            Windows.addWindow(win1)
            Windows.addWindow(win2)
            focused_window = win2

            Windows.slurpWindow()

            local state = State.get()
            assert.are.equal(1, #state.window_list[1])    -- only one column left
            assert.are.equal(2, #state.window_list[1][1]) -- with two windows
            assert.are.equal(win1, state.window_list[1][1][1])
            assert.are.equal(win2, state.window_list[1][1][2])
        end)
    end)

    describe("barfWindow", function()
        it("should move the focused window to a new column on the right", function()
            local win1 = mock_window(101, "Window 1", { x = 0, y = 0, w = 100, h = 100 })
            local win2 = mock_window(102, "Window 2")
            Windows.addWindow(win1)
            table.insert(State.windowList(1, 1), win2)
            focused_window = win1

            Windows.barfWindow()

            local state = State.get()
            assert.are.equal(2, #state.window_list[1])    -- two columns
            assert.are.equal(1, #state.window_list[1][1]) -- one window in first column
            assert.are.equal(1, #state.window_list[1][2]) -- one window in second column
            assert.are.equal(win2, state.window_list[1][1][1])
            assert.are.equal(win1, state.window_list[1][2][1])
        end)
    end)

    describe("focusWindowAt", function()
        it("should focus the window at the specified index", function()
            local win1 = mock_window(101, "Window 1")
            local win2 = mock_window(102, "Window 2")
            local win3 = mock_window(103, "Window 3")

            -- Setup state: 2 columns. Col 1 has win1, win2. Col 2 has win3.
            Windows.addWindow(win1)
            table.insert(State.windowList(1, 1), win2)
            table.insert(State.windowList(1), { win3 })

            -- spy on focus
            local s = spy.on(win3, "focus")

            -- win1 is index 1, win2 is index 2, win3 is index 3
            Windows.focusWindowAt(3)

            assert.spy(s).was.called()
        end)

        it("should focus the first window", function()
            local win1 = mock_window(101, "Window 1")
            local win2 = mock_window(102, "Window 2")

            Windows.addWindow(win1)
            Windows.addWindow(win2)

            local s = spy.on(win1, "focus")

            Windows.focusWindowAt(1)

            assert.spy(s).was.called()
        end)
    end)
end)
