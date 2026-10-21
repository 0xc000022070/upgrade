local card = require("lib/card")

return ui.app {
    init = function()
        return {greeting = "Hello from Luau", refreshes = 0}
    end,
    update = function(state, event)
        if event.type == "refresh" then
            state.refreshes = state.refreshes + 1
        end
        return state
    end,
    cards = {
        status = card.status,
    },
}
