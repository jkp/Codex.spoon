---@diagnostic disable

package.preload["mocks"] = function() return dofile("spec/mocks.lua") end
package.preload["tiling"] = function() return dofile("tiling.lua") end
package.preload["windows"] = function() return dofile("windows.lua") end
package.preload["state"] = function() return dofile("state.lua") end
package.preload["floating"] = function() return dofile("floating.lua") end

describe("Codex.tiling", function()
    local Mocks = require("mocks")
    Mocks.init_mocks()

    local Tiling = require("tiling")
    local Windows = require("windows")
    local State = require("state")
    local Floating = require("floating")

    local mock_codex = Mocks.get_mock_codex({ Tiling = Tiling, Windows = Windows, State = State, Floating = Floating })
    local mock_window = Mocks.mock_window

    local focused_window

    before_each(function()
        -- Reset state before each test
        State.init(mock_codex)
        Windows.init(mock_codex)
        Floating.init(mock_codex)
        Tiling.init(mock_codex)
        mock_codex.sticky_pairs = true
        mock_codex.right_anchor_last = true
        hs.window.focusedWindow = function() return focused_window end
    end)

    describe("tileSpace", function()
        it("should tile a single window to fit in the screen with external_bar", function()
            mock_codex.external_bar = { top = 40 }
            local win = mock_window(101, "Test Window", { x = 0, y = 0, w = 100, h = 100 })
            Windows.addWindow(win)
            focused_window = win

            Tiling.tileSpace(1)

            local frame = win:frame()
            assert.are.equal(8, frame.x)
            assert.are.equal(48, frame.y)
            assert.are.equal(100, frame.w)
            assert.are.equal(644, frame.h)
        end)
        it("should tile two windows side-by-side with external_bar", function()
            mock_codex.external_bar = { top = 40 }
            local win1 = mock_window(101, "Window 1", { x = 0, y = 0, w = 100, h = 100 })
            local win2 = mock_window(102, "Window 2", { x = 200, y = 0, w = 100, h = 100 })
            Windows.addWindow(win1)
            Windows.addWindow(win2)
            focused_window = win1

            Tiling.tileSpace(1)

            local frame1 = win1:frame()
            assert.are.equal(8, frame1.x)
            assert.are.equal(48, frame1.y)
            assert.are.equal(100, frame1.w)
            assert.are.equal(644, frame1.h)

            local frame2 = win2:frame()
            assert.are.equal(116, frame2.x) -- 8 + 100 + 8 (right gap)
            assert.are.equal(48, frame2.y)
            assert.are.equal(100, frame2.w)
            assert.are.equal(692, frame2.y2) -- tileColumn sets y2
        end)
        it("should tile a single window to fit in the screen", function()
            mock_codex.external_bar = nil
            local win = mock_window(101, "Test Window", { x = 0, y = 0, w = 100, h = 100 })
            Windows.addWindow(win)
            focused_window = win

            Tiling.tileSpace(1)

            local frame = win:frame()
            assert.are.equal(8, frame.x)
            assert.are.equal(40, frame.y)
            assert.are.equal(100, frame.w)
            assert.are.equal(652, frame.h)
        end)

        it("should tile two windows side-by-side", function()
            mock_codex.external_bar = nil
            local win1 = mock_window(101, "Window 1", { x = 0, y = 0, w = 100, h = 100 })
            local win2 = mock_window(102, "Window 2", { x = 200, y = 0, w = 100, h = 100 })
            Windows.addWindow(win1)
            Windows.addWindow(win2)
            focused_window = win1

            Tiling.tileSpace(1)

            local frame1 = win1:frame()
            assert.are.equal(8, frame1.x)
            assert.are.equal(40, frame1.y)
            assert.are.equal(100, frame1.w)
            assert.are.equal(652, frame1.h)

            local frame2 = win2:frame()
            assert.are.equal(116, frame2.x) -- 8 + 100 + 8 (right gap)
            assert.are.equal(40, frame2.y)
            assert.are.equal(100, frame2.w)
            assert.are.equal(692, frame2.y2) -- tileColumn sets y2
        end)

        -- canvas: x=8, y=40, w=984, h=652, x2=992, y2=692

        it("should left-anchor the first of three columns", function()
            mock_codex.external_bar = nil

            local win1 = mock_window(101, "W1", { x = 0, y = 0, w = 300, h = 100 })
            local win2 = mock_window(102, "W2", { x = 300, y = 0, w = 300, h = 100 })
            local win3 = mock_window(103, "W3", { x = 600, y = 0, w = 300, h = 100 })
            Windows.addWindow(win1)
            Windows.addWindow(win2)
            Windows.addWindow(win3)
            focused_window = win1

            Tiling.tileSpace(1)

            local f1 = win1:frame()
            assert.are.equal(8, f1.x) -- left-anchored at canvas.x
            assert.are.equal(300, f1.w)
        end)

        it("should right-anchor the last of three columns", function()
            mock_codex.external_bar = nil
            local win1 = mock_window(101, "W1", { x = 0, y = 0, w = 300, h = 100 })
            local win2 = mock_window(102, "W2", { x = 300, y = 0, w = 300, h = 100 })
            local win3 = mock_window(103, "W3", { x = 600, y = 0, w = 300, h = 100 })
            Windows.addWindow(win1)
            Windows.addWindow(win2)
            Windows.addWindow(win3)
            focused_window = win3

            Tiling.tileSpace(1)

            local f3 = win3:frame()
            -- right-anchored: canvas.x2 - width = 992 - 300 = 692
            assert.are.equal(692, f3.x)
            assert.are.equal(300, f3.w)
        end)

        it("should left-anchor last column when right_anchor_last is false", function()
            mock_codex.external_bar = nil
            mock_codex.right_anchor_last = false
            local win1 = mock_window(101, "W1", { x = 0, y = 0, w = 300, h = 100 })
            local win2 = mock_window(102, "W2", { x = 300, y = 0, w = 300, h = 100 })
            local win3 = mock_window(103, "W3", { x = 600, y = 0, w = 300, h = 100 })
            Windows.addWindow(win1)
            Windows.addWindow(win2)
            Windows.addWindow(win3)
            focused_window = win3

            Tiling.tileSpace(1)

            local f3 = win3:frame()
            -- sticky pair with left neighbor: 8 + 300 + 8 = 316
            assert.are.equal(316, f3.x)
            assert.are.equal(300, f3.w)
        end)

        it("should sticky-pair middle column with left neighbor when both fit", function()
            mock_codex.external_bar = nil
            -- left=300, middle=300, right=300: left+gap+middle = 300+8+300 = 608 <= 984
            local win1 = mock_window(101, "W1", { x = 0, y = 0, w = 300, h = 100 })
            local win2 = mock_window(102, "W2", { x = 300, y = 0, w = 300, h = 100 })
            local win3 = mock_window(103, "W3", { x = 600, y = 0, w = 300, h = 100 })
            Windows.addWindow(win1)
            Windows.addWindow(win2)
            Windows.addWindow(win3)
            focused_window = win2

            Tiling.tileSpace(1)

            local f2 = win2:frame()
            -- sticky pair: anchor_x = canvas.x + left_w + left_gap = 8 + 300 + 8 = 316
            assert.are.equal(316, f2.x)
            assert.are.equal(300, f2.w)

            -- left neighbor should be visible at canvas.x
            local f1 = win1:frame()
            assert.are.equal(8, f1.x)
        end)

        it("should maintain visual continuity when scrolling left with sticky pairs", function()
            mock_codex.external_bar = nil
            mock_codex.right_anchor_last = false
            -- three half-width windows: 480+8+480 = 968 <= 984 (pairs fit)
            local win1 = mock_window(101, "W1", { x = 0, y = 0, w = 480, h = 100 })
            local win2 = mock_window(102, "W2", { x = 480, y = 0, w = 480, h = 100 })
            local win3 = mock_window(103, "W3", { x = 960, y = 0, w = 480, h = 100 })
            Windows.addWindow(win1)
            Windows.addWindow(win2)
            Windows.addWindow(win3)

            -- Scroll right: focus 1 → 2 → 3
            focused_window = win1
            Tiling.tileSpace(1)
            assert.are.equal(8, win1:frame().x) -- col 1 left-anchored

            State.prev_prev_focused_window = win1
            focused_window = win2
            Tiling.tileSpace(1)
            -- scrolled right: pair left, win1+win2 visible
            assert.are.equal(496, win2:frame().x) -- 8 + 480 + 8
            assert.are.equal(8, win1:frame().x)

            State.prev_prev_focused_window = win2
            focused_window = win3
            Tiling.tileSpace(1)
            -- scrolled right: pair left, win2+win3 visible
            assert.are.equal(496, win3:frame().x)
            assert.are.equal(8, win2:frame().x)

            -- Now scroll left: focus 3 → 2 → 1
            State.prev_prev_focused_window = win3
            focused_window = win2
            Tiling.tileSpace(1)
            -- scrolled left: left-anchor to keep win2+win3 visible
            assert.are.equal(8, win2:frame().x)
            assert.are.equal(480, win2:frame().w)
            assert.are.equal(496, win3:frame().x) -- right neighbor stays visible

            State.prev_prev_focused_window = win2
            focused_window = win1
            Tiling.tileSpace(1)
            -- col 1 always left-anchors
            assert.are.equal(8, win1:frame().x)
            assert.are.equal(496, win2:frame().x)
        end)

        it("should preserve anchor position across workspace round-trips", function()
            mock_codex.external_bar = nil
            mock_codex.right_anchor_last = false
            local win1 = mock_window(101, "W1", { x = 0, y = 0, w = 480, h = 100 })
            local win2 = mock_window(102, "W2", { x = 480, y = 0, w = 480, h = 100 })
            local win3 = mock_window(103, "W3", { x = 960, y = 0, w = 480, h = 100 })
            Windows.addWindow(win1)
            Windows.addWindow(win2)
            Windows.addWindow(win3)

            -- Scroll left to col 2: left-anchored
            State.prev_prev_focused_window = win3
            focused_window = win2
            Tiling.tileSpace(1)
            assert.are.equal(8, win2:frame().x)

            -- Simulate workspace switch: clear direction context
            State.prev_prev_focused_window = nil

            -- Retile (as workspace restore would)
            Tiling.tileSpace(1)
            -- Should restore to same position via saved x_positions
            assert.are.equal(8, win2:frame().x)
        end)

        it("should left-anchor middle column when sticky_pairs is false", function()
            mock_codex.external_bar = nil
            mock_codex.sticky_pairs = false
            local win1 = mock_window(101, "W1", { x = 0, y = 0, w = 300, h = 100 })
            local win2 = mock_window(102, "W2", { x = 300, y = 0, w = 300, h = 100 })
            local win3 = mock_window(103, "W3", { x = 600, y = 0, w = 300, h = 100 })
            Windows.addWindow(win1)
            Windows.addWindow(win2)
            Windows.addWindow(win3)
            focused_window = win2

            Tiling.tileSpace(1)

            local f2 = win2:frame()
            assert.are.equal(8, f2.x) -- left-anchored, no sticky pair
            assert.are.equal(300, f2.w)
        end)

        it("should left-anchor middle column when left neighbor is too wide", function()
            mock_codex.external_bar = nil
            -- left=700, middle=300: left+gap+middle = 700+8+300 = 1008 > 984
            local win1 = mock_window(101, "W1", { x = 0, y = 0, w = 700, h = 100 })
            local win2 = mock_window(102, "W2", { x = 700, y = 0, w = 300, h = 100 })
            local win3 = mock_window(103, "W3", { x = 1000, y = 0, w = 300, h = 100 })
            Windows.addWindow(win1)
            Windows.addWindow(win2)
            Windows.addWindow(win3)
            focused_window = win2

            Tiling.tileSpace(1)

            local f2 = win2:frame()
            -- too wide: left-anchor at canvas.x
            assert.are.equal(8, f2.x)
            assert.are.equal(300, f2.w)
        end)

        it("should keep two half-width windows both visible regardless of focus", function()
            mock_codex.external_bar = nil

            -- two windows that together fit: 480+8+480 = 968 <= 984
            local win1 = mock_window(101, "W1", { x = 0, y = 0, w = 480, h = 100 })
            local win2 = mock_window(102, "W2", { x = 480, y = 0, w = 480, h = 100 })
            Windows.addWindow(win1)
            Windows.addWindow(win2)

            -- focus left window: left-anchored at canvas.x
            focused_window = win1
            Tiling.tileSpace(1)
            local f1a = win1:frame()
            local f2a = win2:frame()
            assert.are.equal(8, f1a.x)
            assert.are.equal(496, f2a.x) -- 8 + 480 + 8

            -- focus right window: right-anchored at canvas.x2 - width
            focused_window = win2
            Tiling.tileSpace(1)
            local f2b = win2:frame()
            local f1b = win1:frame()
            -- right-anchored: 992 - 480 = 512
            assert.are.equal(512, f2b.x)
            -- left neighbor tiled from anchor left: x2 = 512 - 8 = 504, x = 504 - 480 = 24
            assert.are.equal(24, f1b.x)
            -- both visible: f1b.x >= canvas.x (8) and f2b.x2 <= canvas.x2 (992)
            assert.is_true(f1b.x >= 8)
            assert.is_true(f2b.x + f2b.w <= 992)
        end)
    end)

    describe("tileColumn", function()
        it("should tile a single window to fit in the bounds", function()
            local win = mock_window(101, "Test Window", { x = 0, y = 0, w = 100, h = 100 })
            local bounds = { x = 10, y = 20, w = 100, h = 760, x2 = 110, y2 = 780 }

            Tiling.tileColumn({ win }, bounds)

            local frame = win:frame()
            assert.are.equal(10, frame.x)
            assert.are.equal(20, frame.y)
            assert.are.equal(100, frame.w)
            assert.are.equal(780, frame.y2)
        end)

        it("should tile two windows top to bottom in bounds", function()
            local win1 = mock_window(101, "Test Window", { x = 0, y = 0, w = 100, h = 100 })
            local win2 = mock_window(102, "Test Window", { x = 200, y = 0, w = 100, h = 100 })
            local bounds = { x = 10, y = 20, w = 100, h = 760, x2 = 110, y2 = 780 }

            Tiling.tileColumn({ win1, win2 }, bounds)

            local frame1 = win1:frame()
            assert.are.equal(10, frame1.x)
            assert.are.equal(20, frame1.y)
            assert.are.equal(100, frame1.w)
            assert.are.equal(100, frame1.y2)

            local frame2 = win2:frame()
            assert.are.equal(10, frame2.x)
            assert.are.equal(108, frame2.y)
            assert.are.equal(100, frame2.w)
            assert.are.equal(780, frame2.y2)
        end)
    end)
end)
