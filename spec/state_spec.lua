---@diagnostic disable

package.preload["mocks"] = function() return dofile("spec/mocks.lua") end
package.preload["state"] = function() return dofile("state.lua") end

describe("Codex.state", function()
    local Mocks = require("mocks")
    Mocks.init_mocks()

    local State = require("state")

    local mock_codex = Mocks.get_mock_codex({ State = State })

    before_each(function()
        -- Reset state before each test
        State.init(mock_codex)
    end)

    describe("isTiled", function()
        it("should return true for a tiled window and false for a floating window", function()
            -- To add a window to index_table, we need to add it to window_list
            local space = 1
            local win = Mocks.mock_window(123, "Tiled Window")
            local window_list = State.windowList(space)
            window_list[1] = { win }

            assert.is_true(State.isTiled(123))
            assert.is_false(State.isTiled(456))
        end)
    end)

    describe("windowList proxy", function()
        it("should insert a column into a new space via proxy __newindex", function()
            local space = 1
            local win = Mocks.mock_window(1, "W1")
            local columns = State.windowList(space)
            columns[1] = { win }

            assert.are.equal(win, State.windowList(space, 1, 1))
        end)

        it("should insert multiple columns into a space", function()
            local space = 1
            local w1 = Mocks.mock_window(1, "W1")
            local w2 = Mocks.mock_window(2, "W2")
            local columns = State.windowList(space)
            columns[1] = { w1 }
            columns[2] = { w2 }

            assert.are.equal(2, #State.windowList(space))
            assert.are.equal(w1, State.windowList(space, 1, 1))
            assert.are.equal(w2, State.windowList(space, 2, 1))
        end)

        it("should auto-clean empty spaces when last column is removed", function()
            local space = 1
            local win = Mocks.mock_window(1, "W1")
            local columns = State.windowList(space)
            columns[1] = { win }

            -- Remove the column by setting it to nil
            local rows = State.windowList(space, 1)
            rows[1] = nil  -- remove the window from the row

            local state = State.get()
            assert.is_nil(state.window_list[space])
        end)

        it("should support __len on columns proxy", function()
            local space = 1
            local w1 = Mocks.mock_window(1, "W1")
            local w2 = Mocks.mock_window(2, "W2")
            local columns = State.windowList(space)
            columns[1] = { w1 }
            columns[2] = { w2 }

            assert.are.equal(2, #State.windowList(space))
        end)

        it("should support __len on rows proxy", function()
            local space = 1
            local w1 = Mocks.mock_window(1, "W1")
            local w2 = Mocks.mock_window(2, "W2")
            local columns = State.windowList(space)
            columns[1] = { w1, w2 }

            assert.are.equal(2, #State.windowList(space, 1))
        end)

        it("should support __ipairs on columns proxy", function()
            local space = 1
            local w1 = Mocks.mock_window(1, "W1")
            local w2 = Mocks.mock_window(2, "W2")
            local columns = State.windowList(space)
            columns[1] = { w1 }
            columns[2] = { w2 }

            local count = 0
            for _, col in ipairs(State.windowList(space)) do
                count = count + 1
            end
            assert.are.equal(2, count)
        end)

        it("should support __ipairs on rows proxy", function()
            local space = 1
            local w1 = Mocks.mock_window(1, "W1")
            local w2 = Mocks.mock_window(2, "W2")
            local columns = State.windowList(space)
            columns[1] = { w1, w2 }

            local count = 0
            for _, win in ipairs(State.windowList(space, 1)) do
                count = count + 1
            end
            assert.are.equal(2, count)
        end)

        it("should keep index table consistent after column insert", function()
            local space = 1
            local w1 = Mocks.mock_window(10, "W1")
            local w2 = Mocks.mock_window(20, "W2")
            local columns = State.windowList(space)
            columns[1] = { w1 }
            columns[2] = { w2 }

            local idx1 = State.windowIndex(w1)
            local idx2 = State.windowIndex(w2)
            assert.are.same({ space = 1, col = 1, row = 1 }, idx1)
            assert.are.same({ space = 1, col = 2, row = 1 }, idx2)
        end)

        it("should keep index table consistent with multiple rows", function()
            local space = 1
            local w1 = Mocks.mock_window(10, "W1")
            local w2 = Mocks.mock_window(20, "W2")
            local columns = State.windowList(space)
            columns[1] = { w1, w2 }

            local idx1 = State.windowIndex(w1)
            local idx2 = State.windowIndex(w2)
            assert.are.same({ space = 1, col = 1, row = 1 }, idx1)
            assert.are.same({ space = 1, col = 1, row = 2 }, idx2)
        end)

        it("should return nil for windowList of empty space", function()
            -- A fresh proxy for an empty space should still allow __newindex
            local columns = State.windowList(99)
            -- Reading from it should return nil
            assert.is_nil(columns[1])
        end)

        it("should handle table.insert on columns proxy for existing spaces", function()
            local space = 1
            local w1 = Mocks.mock_window(1, "W1")
            local w2 = Mocks.mock_window(2, "W2")
            local w3 = Mocks.mock_window(3, "W3")

            local columns = State.windowList(space)
            columns[1] = { w1 }
            columns[2] = { w2 }

            -- Use table.insert on the internal state (as Windows.addWindow does)
            table.insert(State.windowList(space), 2, { w3 })

            assert.are.equal(w3, State.windowList(space, 2, 1))
        end)

        it("should return nil for non-existent column or row", function()
            local space = 1
            local w1 = Mocks.mock_window(1, "W1")
            local columns = State.windowList(space)
            columns[1] = { w1 }

            assert.is_nil(State.windowList(space, 2, 1))
            assert.is_nil(State.windowList(space, 1, 5))
        end)
    end)

    describe("windowIndex", function()
        it("should return index for a tiled window", function()
            local space = 1
            local win = Mocks.mock_window(42, "W42")
            State.windowList(space)[1] = { win }

            local idx = State.windowIndex(win)
            assert.are.same({ space = 1, col = 1, row = 1 }, idx)
        end)

        it("should return nil for an unknown window", function()
            local win = Mocks.mock_window(999, "Unknown")
            assert.is_nil(State.windowIndex(win))
        end)

        it("should remove entry when remove=true", function()
            local space = 1
            local win = Mocks.mock_window(42, "W42")
            State.windowList(space)[1] = { win }

            local idx = State.windowIndex(win, true)
            assert.are.same({ space = 1, col = 1, row = 1 }, idx)
            assert.is_nil(State.windowIndex(win))
        end)

        it("should preserve entry when remove=false", function()
            local space = 1
            local win = Mocks.mock_window(42, "W42")
            State.windowList(space)[1] = { win }

            State.windowIndex(win, false)
            assert.is_not_nil(State.windowIndex(win))
        end)
    end)

    describe("xPositions proxy", function()
        it("should store and retrieve x position", function()
            local space = 1
            local xp = State.xPositions(space)
            xp[100] = 250

            assert.are.equal(250, State.xPositions(space)[100])
        end)

        it("should auto-create space table on first write", function()
            local xp = State.xPositions(42)
            xp[1] = 100

            assert.are.equal(100, State.xPositions(42)[1])
        end)

        it("should auto-clean space table when last position is removed", function()
            local xp = State.xPositions(1)
            xp[100] = 250
            xp[100] = nil

            local state = State.get()
            assert.is_nil(state.x_positions[1])
        end)

        it("should iterate stored positions with pairs", function()
            local xp = State.xPositions(1)
            xp[10] = 100
            xp[20] = 200

            local found = {}
            for id, x in pairs(State.xPositions(1)) do
                found[id] = x
            end
            assert.are.same({ [10] = 100, [20] = 200 }, found)
        end)

        it("should return nil for unknown space/id", function()
            assert.is_nil(State.xPositions(99)[123])
        end)
    end)

    describe("setHidden / isHidden", function()
        it("should return false for unknown window ID", function()
            assert.is_false(State.isHidden(999))
        end)

        it("should mark a window as hidden", function()
            State.setHidden(42, true)
            assert.is_true(State.isHidden(42))
        end)

        it("should unhide with nil", function()
            State.setHidden(42, true)
            State.setHidden(42, nil)
            assert.is_false(State.isHidden(42))
        end)

        it("should unhide with false", function()
            State.setHidden(42, true)
            State.setHidden(42, false)
            assert.is_false(State.isHidden(42))
        end)
    end)

    describe("snapshotSpace", function()
        it("should return deep copy of window_list and x_positions", function()
            local space = 1
            local w1 = Mocks.mock_window(10, "W1")
            local w2 = Mocks.mock_window(20, "W2")
            State.windowList(space)[1] = { w1 }
            State.windowList(space)[2] = { w2 }
            State.xPositions(space)[10] = 100
            State.xPositions(space)[20] = 200

            local snap = State.snapshotSpace(space)
            assert.is_not_nil(snap.window_list)
            assert.is_not_nil(snap.x_positions)
            assert.are.equal(2, #snap.window_list)
            assert.are.equal(w1, snap.window_list[1][1])
            assert.are.equal(100, snap.x_positions[10])
        end)

        it("should be independent of live state after mutation", function()
            local space = 1
            local w1 = Mocks.mock_window(10, "W1")
            State.windowList(space)[1] = { w1 }
            State.xPositions(space)[10] = 100

            local snap = State.snapshotSpace(space)

            -- Mutate the snapshot
            snap.x_positions[10] = 999

            -- Live state should be unaffected
            assert.are.equal(100, State.xPositions(space)[10])
        end)

        it("should return nil fields for empty space", function()
            local snap = State.snapshotSpace(99)
            assert.is_nil(snap.window_list)
            assert.is_nil(snap.x_positions)
        end)

        it("should copy window references not deep-clone window objects", function()
            local space = 1
            local w1 = Mocks.mock_window(10, "W1")
            State.windowList(space)[1] = { w1 }

            local snap = State.snapshotSpace(space)
            -- Same window object reference
            assert.are.equal(w1, snap.window_list[1][1])
        end)
    end)

    describe("restoreSpace", function()
        it("should replace state from snapshot", function()
            local space = 1
            local w1 = Mocks.mock_window(10, "W1")
            local w2 = Mocks.mock_window(20, "W2")

            -- Set up initial state
            State.windowList(space)[1] = { w1 }

            -- Create snapshot with different state
            local snap = {
                window_list = { { w2 } },
                x_positions = { [20] = 300 },
            }

            State.restoreSpace(space, snap)

            -- Should have w2, not w1
            assert.are.equal(w2, State.windowList(space, 1, 1))
            assert.are.equal(300, State.xPositions(space)[20])
            assert.is_false(State.isTiled(10))
            assert.is_true(State.isTiled(20))
        end)

        it("should update index table after restore", function()
            local space = 1
            local w1 = Mocks.mock_window(10, "W1")
            local w2 = Mocks.mock_window(20, "W2")
            State.windowList(space)[1] = { w1 }

            local snap = { window_list = { { w2 } }, x_positions = nil }
            State.restoreSpace(space, snap)

            local idx = State.windowIndex(w2)
            assert.are.same({ space = 1, col = 1, row = 1 }, idx)
            assert.is_nil(State.windowIndex(w1))
        end)

        it("should clear space when restoring nil", function()
            local space = 1
            local w1 = Mocks.mock_window(10, "W1")
            State.windowList(space)[1] = { w1 }
            State.xPositions(space)[10] = 100

            State.restoreSpace(space, nil)

            local state = State.get()
            assert.is_nil(state.window_list[space])
            assert.is_nil(state.x_positions[space])
            assert.is_false(State.isTiled(10))
        end)

        it("should clear space when snapshot has nil window_list", function()
            local space = 1
            local w1 = Mocks.mock_window(10, "W1")
            State.windowList(space)[1] = { w1 }

            State.restoreSpace(space, { window_list = nil, x_positions = nil })

            assert.is_false(State.isTiled(10))
        end)
    end)

    describe("windowIdsInSpace", function()
        it("should return set of IDs for populated space", function()
            local space = 1
            local w1 = Mocks.mock_window(10, "W1")
            local w2 = Mocks.mock_window(20, "W2")
            State.windowList(space)[1] = { w1 }
            State.windowList(space)[2] = { w2 }

            local ids = State.windowIdsInSpace(space)
            assert.is_true(ids[10])
            assert.is_true(ids[20])
            assert.is_nil(ids[99])
        end)

        it("should return empty table for empty space", function()
            local ids = State.windowIdsInSpace(99)
            assert.are.same({}, ids)
        end)

        it("should include windows from multiple rows in same column", function()
            local space = 1
            local w1 = Mocks.mock_window(10, "W1")
            local w2 = Mocks.mock_window(20, "W2")
            State.windowList(space)[1] = { w1, w2 }

            local ids = State.windowIdsInSpace(space)
            assert.is_true(ids[10])
            assert.is_true(ids[20])
        end)
    end)

    describe("ensureWatchers", function()
        it("should create watchers for windows without them", function()
            local space = 1
            local win = Mocks.mock_window(10, "W1")
            -- Add directly to get() state without going through uiWatcherCreate
            local state = State.get()
            state.window_list[space] = { { win } }

            -- No watcher exists yet
            assert.is_nil(state.ui_watchers[10])

            State.ensureWatchers(space)

            -- Now a watcher should exist
            assert.is_not_nil(state.ui_watchers[10])
        end)

        it("should not crash for empty space", function()
            -- Should be a no-op
            State.ensureWatchers(99)
        end)

        it("should not crash for nil space", function()
            State.ensureWatchers(nil)
        end)
    end)

    describe("clear", function()
        it("should reset all internal state tables", function()
            local space = 1
            local win = Mocks.mock_window(10, "W1")
            State.windowList(space)[1] = { win }
            State.xPositions(space)[10] = 100
            State.setHidden(10, true)
            State.is_floating[10] = true
            State.prev_focused_window = win
            State.pending_window = win

            State.clear()

            local state = State.get()
            assert.are.same({}, state.window_list)
            assert.are.same({}, state.index_table)
            assert.are.same({}, state.ui_watchers)
            assert.are.same({}, state.x_positions)
            assert.are.same({}, state.is_floating)
            assert.is_nil(state.prev_focused_window)
            assert.is_nil(state.pending_window)
        end)

        it("should clear hidden state", function()
            State.setHidden(42, true)
            State.clear()
            assert.is_false(State.isHidden(42))
        end)
    end)

    describe("uiWatchers", function()
        it("should create and track a watcher for a window", function()
            local win = Mocks.mock_window(10, "W1")
            State.uiWatcherCreate(win)

            local state = State.get()
            assert.is_not_nil(state.ui_watchers[10])
        end)

        it("should delete a watcher", function()
            local win = Mocks.mock_window(10, "W1")
            State.uiWatcherCreate(win)
            State.uiWatcherDelete(10)

            local state = State.get()
            assert.is_nil(state.ui_watchers[10])
        end)

        it("should stop all watchers", function()
            local w1 = Mocks.mock_window(10, "W1")
            local w2 = Mocks.mock_window(20, "W2")
            State.uiWatcherCreate(w1)
            State.uiWatcherCreate(w2)

            -- Should not error
            State.uiWatcherStopAll()
        end)
    end)
end)
