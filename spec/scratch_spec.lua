---@diagnostic disable

package.preload["mocks"] = function() return dofile("spec/mocks.lua") end
package.preload["scratch"] = function() return dofile("scratch.lua") end

describe("Codex.scratch", function()
    local Mocks = require("mocks")
    Mocks.init_mocks()

    local spy = require("luassert.spy")
    local Scratch = require("scratch")

    local focused_window

    -- Screen frame: x=0, y=32, w=1000, h=668
    local sf = Mocks.mock_screen():frame()

    local mock_codex

    before_each(function()
        focused_window = nil
        hs.window.focusedWindow = function() return focused_window end

        mock_codex = {
            workspaces = {
                windowIds = function(name) return {} end,
                currentSpace = function() return "scratch" end,
            },
        }
        Scratch.init(mock_codex)
    end)

    describe("snap", function()
        it("should snap left half on first press", function()
            local win = Mocks.mock_window(1, "W1", { x = 100, y = 100, w = 200, h = 200 })
            focused_window = win

            Scratch.snap("left")

            local f = win:frame()
            assert.are.equal(sf.x, f.x)
            assert.are.equal(sf.y, f.y)
            assert.are.equal(sf.w * 0.5, f.w)
            assert.are.equal(sf.h, f.h)
        end)

        it("should cycle left: half -> top-left quarter", function()
            local win = Mocks.mock_window(1, "W1")
            focused_window = win

            Scratch.snap("left")  -- half
            Scratch.snap("left")  -- top-left quarter

            local f = win:frame()
            assert.are.equal(sf.x, f.x)
            assert.are.equal(sf.y, f.y)
            assert.are.equal(sf.w * 0.5, f.w)
            assert.are.equal(sf.h * 0.5, f.h)
        end)

        it("should cycle left: half -> quarter A -> quarter B", function()
            local win = Mocks.mock_window(1, "W1")
            focused_window = win

            Scratch.snap("left")
            Scratch.snap("left")
            Scratch.snap("left")  -- bottom-left quarter

            local f = win:frame()
            assert.are.equal(sf.x, f.x)
            assert.are.equal(sf.y + sf.h * 0.5, f.y)
            assert.are.equal(sf.w * 0.5, f.w)
            assert.are.equal(sf.h * 0.5, f.h)
        end)

        it("should cycle left: wraps back to half after quarter B", function()
            local win = Mocks.mock_window(1, "W1")
            focused_window = win

            Scratch.snap("left")
            Scratch.snap("left")
            Scratch.snap("left")
            Scratch.snap("left")  -- wrap to half

            local f = win:frame()
            assert.are.equal(sf.x, f.x)
            assert.are.equal(sf.y, f.y)
            assert.are.equal(sf.w * 0.5, f.w)
            assert.are.equal(sf.h, f.h)
        end)

        it("should snap right half on first press", function()
            local win = Mocks.mock_window(1, "W1", { x = 100, y = 100, w = 200, h = 200 })
            focused_window = win

            Scratch.snap("right")

            local f = win:frame()
            assert.are.equal(sf.x + sf.w * 0.5, f.x)
            assert.are.equal(sf.y, f.y)
            assert.are.equal(sf.w * 0.5, f.w)
            assert.are.equal(sf.h, f.h)
        end)

        it("should cycle right: half -> top-right quarter -> bottom-right quarter", function()
            local win = Mocks.mock_window(1, "W1")
            focused_window = win

            Scratch.snap("right")
            Scratch.snap("right")

            local f = win:frame()
            assert.are.equal(sf.x + sf.w * 0.5, f.x)
            assert.are.equal(sf.y, f.y)
            assert.are.equal(sf.w * 0.5, f.w)
            assert.are.equal(sf.h * 0.5, f.h)
        end)

        it("should snap top half on first press", function()
            local win = Mocks.mock_window(1, "W1", { x = 100, y = 100, w = 200, h = 200 })
            focused_window = win

            Scratch.snap("top")

            local f = win:frame()
            assert.are.equal(sf.x, f.x)
            assert.are.equal(sf.y, f.y)
            assert.are.equal(sf.w, f.w)
            assert.are.equal(sf.h * 0.5, f.h)
        end)

        it("should cycle top: half -> top-left quarter -> top-right quarter", function()
            local win = Mocks.mock_window(1, "W1")
            focused_window = win

            Scratch.snap("top")
            Scratch.snap("top")

            local f = win:frame()
            assert.are.equal(sf.x, f.x)
            assert.are.equal(sf.y, f.y)
            assert.are.equal(sf.w * 0.5, f.w)
            assert.are.equal(sf.h * 0.5, f.h)
        end)

        it("should snap bottom half on first press", function()
            local win = Mocks.mock_window(1, "W1", { x = 100, y = 100, w = 200, h = 200 })
            focused_window = win

            Scratch.snap("bottom")

            local f = win:frame()
            assert.are.equal(sf.x, f.x)
            assert.are.equal(sf.y + sf.h * 0.5, f.y)
            assert.are.equal(sf.w, f.w)
            assert.are.equal(sf.h * 0.5, f.h)
        end)

        it("should cycle bottom: half -> bottom-left quarter -> bottom-right quarter", function()
            local win = Mocks.mock_window(1, "W1")
            focused_window = win

            Scratch.snap("bottom")
            Scratch.snap("bottom")

            local f = win:frame()
            assert.are.equal(sf.x, f.x)
            assert.are.equal(sf.y + sf.h * 0.5, f.y)
            assert.are.equal(sf.w * 0.5, f.w)
            assert.are.equal(sf.h * 0.5, f.h)
        end)

        it("should be no-op for nil focused window", function()
            focused_window = nil
            -- Should not error
            Scratch.snap("left")
        end)

        it("should be no-op for unknown direction", function()
            local win = Mocks.mock_window(1, "W1", { x = 100, y = 100, w = 200, h = 200 })
            focused_window = win
            local before = win:frame()

            Scratch.snap("diagonal")

            local after = win:frame()
            assert.are.equal(before.x, after.x)
            assert.are.equal(before.y, after.y)
            assert.are.equal(before.w, after.w)
            assert.are.equal(before.h, after.h)
        end)
    end)

    describe("maximize", function()
        it("should set frame to fill screen", function()
            local win = Mocks.mock_window(1, "W1", { x = 100, y = 100, w = 200, h = 200 })
            focused_window = win

            Scratch.maximize()

            local f = win:frame()
            assert.are.equal(sf.x, f.x)
            assert.are.equal(sf.y, f.y)
            assert.are.equal(sf.w, f.w)
            assert.are.equal(sf.h, f.h)
        end)

        it("should be no-op for nil focused window", function()
            focused_window = nil
            Scratch.maximize()
        end)
    end)

    describe("center", function()
        it("should set frame at 1/6 margins with 2/3 size", function()
            local win = Mocks.mock_window(1, "W1", { x = 100, y = 100, w = 200, h = 200 })
            focused_window = win

            Scratch.center()

            local f = win:frame()
            local eps = 1
            assert.is_true(math.abs(f.x - (sf.x + sf.w / 6)) < eps)
            assert.is_true(math.abs(f.y - (sf.y + sf.h / 6)) < eps)
            assert.is_true(math.abs(f.w - (sf.w * 2 / 3)) < eps)
            assert.is_true(math.abs(f.h - (sf.h * 2 / 3)) < eps)
        end)

        it("should be no-op for nil focused window", function()
            focused_window = nil
            Scratch.center()
        end)
    end)

    describe("cycle_width", function()
        it("should cycle from 1/3 to 1/2", function()
            local win = Mocks.mock_window(1, "W1")
            focused_window = win

            -- Set window to 1/3 width
            win:moveToUnit({ 0, 0, 1/3, 1 })
            Scratch.cycle_width()

            local f = win:frame()
            local expected_w = sf.w * 0.5
            assert.is_true(math.abs(f.w - expected_w) < 1)
        end)

        it("should cycle from 1/2 to 2/3", function()
            local win = Mocks.mock_window(1, "W1")
            focused_window = win

            win:moveToUnit({ 0, 0, 1/2, 1 })
            Scratch.cycle_width()

            local f = win:frame()
            local expected_w = sf.w * 2/3
            assert.is_true(math.abs(f.w - expected_w) < 1)
        end)

        it("should cycle from 2/3 back to 1/3", function()
            local win = Mocks.mock_window(1, "W1")
            focused_window = win

            win:moveToUnit({ 0, 0, 2/3, 1 })
            Scratch.cycle_width()

            local f = win:frame()
            local expected_w = sf.w * 1/3
            assert.is_true(math.abs(f.w - expected_w) < 1)
        end)

        it("should clamp position when window would exceed screen edge", function()
            local win = Mocks.mock_window(1, "W1")
            focused_window = win

            -- Place window at right edge with 1/3 width -> cycling to 1/2 should clamp
            win:moveToUnit({ 0.7, 0, 1/3, 1 })
            Scratch.cycle_width()

            local f = win:frame()
            -- x + w should not exceed screen right edge
            assert.is_true(f.x + f.w <= sf.x + sf.w + 1)
        end)
    end)

    describe("cycle_height", function()
        it("should cycle from 1/3 to 1/2", function()
            local win = Mocks.mock_window(1, "W1")
            focused_window = win

            win:moveToUnit({ 0, 0, 1, 1/3 })
            Scratch.cycle_height()

            local f = win:frame()
            local expected_h = sf.h * 0.5
            assert.is_true(math.abs(f.h - expected_h) < 1)
        end)

        it("should cycle from 1/2 to 2/3", function()
            local win = Mocks.mock_window(1, "W1")
            focused_window = win

            win:moveToUnit({ 0, 0, 1, 1/2 })
            Scratch.cycle_height()

            local f = win:frame()
            local expected_h = sf.h * 2/3
            assert.is_true(math.abs(f.h - expected_h) < 1)
        end)

        it("should cycle from 2/3 back to 1/3", function()
            local win = Mocks.mock_window(1, "W1")
            focused_window = win

            win:moveToUnit({ 0, 0, 1, 2/3 })
            Scratch.cycle_height()

            local f = win:frame()
            local expected_h = sf.h * 1/3
            assert.is_true(math.abs(f.h - expected_h) < 1)
        end)

        it("should clamp position when window would exceed screen bottom", function()
            local win = Mocks.mock_window(1, "W1")
            focused_window = win

            win:moveToUnit({ 0, 0.7, 1, 1/3 })
            Scratch.cycle_height()

            local f = win:frame()
            assert.is_true(f.y + f.h <= sf.y + sf.h + 1)
        end)
    end)

    describe("cycle_center", function()
        it("should cycle from 1/3 to 1/2 centered", function()
            local win = Mocks.mock_window(1, "W1")
            focused_window = win

            -- Set to 1/3 centered
            local margin = (1 - 1/3) / 2
            win:moveToUnit({ margin, margin, 1/3, 1/3 })
            Scratch.cycle_center()

            local f = win:frame()
            local expected_size = sf.w * 0.5
            assert.is_true(math.abs(f.w - expected_size) < 1)
        end)

        it("should cycle from 1/2 to 2/3 centered", function()
            local win = Mocks.mock_window(1, "W1")
            focused_window = win

            local margin = (1 - 1/2) / 2
            win:moveToUnit({ margin, margin, 1/2, 1/2 })
            Scratch.cycle_center()

            local f = win:frame()
            local expected_size = sf.w * 2/3
            assert.is_true(math.abs(f.w - expected_size) < 1)
        end)

        it("should cycle from 2/3 to 5/6 centered", function()
            local win = Mocks.mock_window(1, "W1")
            focused_window = win

            local margin = (1 - 2/3) / 2
            win:moveToUnit({ margin, margin, 2/3, 2/3 })
            Scratch.cycle_center()

            local f = win:frame()
            local expected_size = sf.w * 5/6
            assert.is_true(math.abs(f.w - expected_size) < 1)
        end)

        it("should wrap from 5/6 back to 1/3 centered", function()
            local win = Mocks.mock_window(1, "W1")
            focused_window = win

            local margin = (1 - 5/6) / 2
            win:moveToUnit({ margin, margin, 5/6, 5/6 })
            Scratch.cycle_center()

            local f = win:frame()
            local expected_size = sf.w * 1/3
            assert.is_true(math.abs(f.w - expected_size) < 1)
        end)

        it("should fall back to 1/3 for arbitrary size", function()
            local win = Mocks.mock_window(1, "W1")
            focused_window = win

            win:moveToUnit({ 0.1, 0.1, 0.4, 0.4 })  -- arbitrary, matches no step
            Scratch.cycle_center()

            local f = win:frame()
            local expected_size = sf.w * 1/3
            assert.is_true(math.abs(f.w - expected_size) < 1)
        end)
    end)

    describe("focus", function()
        it("should call focusWindowWest for left", function()
            local win = Mocks.mock_window(1, "W1")
            focused_window = win
            local s = spy.on(win, "focusWindowWest")

            Scratch.init(mock_codex)
            Scratch.focus("left")

            assert.spy(s).was.called()
        end)

        it("should call focusWindowEast for right", function()
            local win = Mocks.mock_window(1, "W1")
            focused_window = win
            local s = spy.on(win, "focusWindowEast")

            Scratch.init(mock_codex)
            Scratch.focus("right")

            assert.spy(s).was.called()
        end)

        it("should call focusWindowNorth for up", function()
            local win = Mocks.mock_window(1, "W1")
            focused_window = win
            local s = spy.on(win, "focusWindowNorth")

            Scratch.init(mock_codex)
            Scratch.focus("up")

            assert.spy(s).was.called()
        end)

        it("should call focusWindowSouth for down", function()
            local win = Mocks.mock_window(1, "W1")
            focused_window = win
            local s = spy.on(win, "focusWindowSouth")

            Scratch.init(mock_codex)
            Scratch.focus("down")

            assert.spy(s).was.called()
        end)

        it("should be no-op for nil focused window", function()
            focused_window = nil
            Scratch.init(mock_codex)
            Scratch.focus("left")
        end)
    end)
end)
