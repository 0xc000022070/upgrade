local card = {}

function card.status(state)
    return ui.Panel {key = "status", title = "Hello", children = {
        ui.Text {key = "greeting", text = state.greeting, style = "heading"},
        ui.BracketLabel {key = "refreshes", label = "Refreshes", value = tostring(state.refreshes)},
        ui.StatusTag {key = "mode", label = "Phone only", color = "accent"},
    }}
end

return card
