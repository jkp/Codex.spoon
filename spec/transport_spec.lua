---@diagnostic disable

package.preload["mocks"] = function() return dofile("spec/mocks.lua") end
package.preload["transport"] = function() return dofile("transport.lua") end

describe("Codex.transport", function()
    local Mocks = require("mocks")
    Mocks.init_mocks()

    local Transport = require("transport")
    local encoded

    before_each(function()
        Mocks.stub_io()
        encoded = nil
        hs.json.encode = function(t) encoded = t; return "[]" end
        Transport.init(Mocks.get_mock_codex({}))
    end)

    after_each(function()
        Mocks.restore_io()
    end)

    describe("moveWindowsAsync", function()
        it("sends w = 0 and h = 0 for a park op without a size", function()
            -- winmove rejects the whole batch if any op lacks w or h
            Transport.moveWindowsAsync({ { id = 1, pid = 100, x = 5, y = 6 } })

            assert.are.same({ { wid = 1, pid = 100, x = 5, y = 6, w = 0, h = 0 } }, encoded)
        end)

        it("keeps an explicit size", function()
            Transport.moveWindowsAsync({ { id = 1, pid = 100, x = 5, y = 6, w = 300, h = 200 } })

            assert.are.same({ { wid = 1, pid = 100, x = 5, y = 6, w = 300, h = 200 } }, encoded)
        end)
    end)
end)
