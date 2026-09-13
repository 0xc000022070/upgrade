const luauUiSdk = r'''
local ui = {}
function ui.node(kind, props, children)
    return {kind = kind, props = props or {}, children = children or {}}
end
for name, kind in pairs({
    Screen = "screen", Column = "column", Row = "row", Stack = "stack",
    Box = "box", Text = "text", Button = "button", Input = "input",
    Select = "select", Toggle = "toggle", List = "list", Canvas = "canvas",
    Spacer = "spacer", Divider = "divider", DateTime = "datetime",
}) do
    ui[name] = function(props)
        props = props or {}
        local children = props.children or {}
        local fields = {}
        for key, value in pairs(props) do
            if key ~= "children" then fields[key] = value end
        end
        return ui.node(kind, fields, children)
    end
end
function ui.effect(capability, operation, args, id)
    return {capability = capability, operation = operation, args = args or {}, id = id or operation}
end
function ui.app(app)
    return {
        frame = function(input)
            local state = input.state
            if state == nil then state = app.init and app.init() or {} end
            local effects = {}
            if app.update and input.event then
                local updated, pending = app.update(state, input.event)
                state = updated or state
                effects = pending or {}
            end
            return {state = state, view = app.view(state), effects = effects, back = app.back and app.back(state) or nil}
        end,
    }
end
ui = table.freeze(ui)
''';
