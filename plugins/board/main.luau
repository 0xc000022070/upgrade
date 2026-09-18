local NOTE_WIDTH = 132
local NOTE_HEIGHT = 64
-- A single drawing surface carries 256 commands: a note spends three of them
-- and a link one, so the board holds what those two together fit inside.
local MAX_NOTES = 70
local MAX_LINKS = 40
local MAX_COMMANDS = 250
local MAX_DELETES = 48
local PAGE = 64
local MIN_HEIGHT = 900
local MAX_HEIGHT = 4096
local UNIT = string.char(31)

local function split(text)
    local parts, start = {}, 1
    while true do
        local at = string.find(text, UNIT, start, true)
        if not at then
            table.insert(parts, string.sub(text, start))
            return parts
        end
        table.insert(parts, string.sub(text, start, at - 1))
        start = at + 1
    end
end

local function clean(text)
    return (string.gsub(text, UNIT, " "))
end

local function encode(object)
    if object.kind == "note" then
        return table.concat({"n", tostring(object.x), tostring(object.y), object.text}, UNIT)
    end
    return table.concat({"e", object.a, object.b}, UNIT)
end

local function decode(record)
    local parts = split(record.value)
    local common = {id = string.match(record.key, "([^:]+)$") or "", key = record.key, revision = record.revision}
    if parts[1] == "n" then
        common.kind = "note"
        common.x = tonumber(parts[2]) or 0
        common.y = tonumber(parts[3]) or 0
        common.text = parts[4] or ""
        return common
    elseif parts[1] == "e" then
        common.kind = "edge"
        common.a = parts[2] or ""
        common.b = parts[3] or ""
        return common
    end
    return nil
end

-- The dataset query is a keyset cursor with no prefix filter, so a page is read
-- until a key leaves the prefix it was seeking.
local function scan(prefix, pages, build)
    local rows, cursor = {}, prefix
    for _ = 1, pages do
        local page = dazzle.data.query("boards", cursor, PAGE)
        for _, record in ipairs(page) do
            if string.sub(record.key, 1, #prefix) ~= prefix then return rows end
            local row = build(record)
            if row then table.insert(rows, row) end
            cursor = record.key
        end
        if #page < PAGE then return rows end
    end
    return rows
end

local function readBoards()
    return scan("b:", 2, function(record)
        return {id = string.sub(record.key, 3), name = record.value, revision = record.revision}
    end)
end

local function readObjects(boardId)
    return scan("o:" .. boardId .. ":", 4, decode)
end

local function find(objects, id)
    if id == "" then return nil end
    for _, object in ipairs(objects) do
        if object.id == id then return object end
    end
    return nil
end

local function count(objects, kind)
    local total = 0
    for _, object in ipairs(objects) do
        if object.kind == kind then total += 1 end
    end
    return total
end

local function hit(objects, x, y)
    local found = ""
    for _, object in ipairs(objects) do
        if object.kind == "note" and x >= object.x and x <= object.x + NOTE_WIDTH
            and y >= object.y and y <= object.y + NOTE_HEIGHT then
            found = object.id
        end
    end
    return found
end

-- A page is never told its viewport width, so a note is centred on the tap and
-- only its left edge is held on the surface; the surface clips its own right.
local function place(x)
    local left = x - NOTE_WIDTH / 2
    if left < 4 then return 4 end
    return left
end

local function store(object)
    object.revision = dazzle.data.put("boards", object.key, encode(object), object.revision or 0)
    return object
end

local function removeNote(state, id)
    local kept, removed = {}, 0
    for _, object in ipairs(state.objects) do
        local touches = object.id == id
            or (object.kind == "edge" and (object.a == id or object.b == id))
        if touches and removed < MAX_DELETES then
            dazzle.data.delete("boards", object.key, object.revision)
            removed += 1
        else
            table.insert(kept, object)
        end
    end
    state.objects = kept
    if state.selected == id then state.selected = "" end
    if state.linkFrom == id then state.linkFrom = "" end
end

local function wrap(text)
    if text == "" then return "" end
    local lines, start = {}, 1
    while start <= #text and #lines < 3 do
        local ending = utf8.offset(text, 19, start) or (#text + 1)
        table.insert(lines, string.sub(text, start, ending - 1))
        start = ending
    end
    return table.concat(lines, "\n")
end

local function surfaceHeight(objects)
    local bottom = MIN_HEIGHT
    for _, object in ipairs(objects) do
        if object.kind == "note" then
            local reach = object.y + NOTE_HEIGHT + 160
            if reach > bottom then bottom = reach end
        end
    end
    if bottom > MAX_HEIGHT then return MAX_HEIGHT end
    return bottom
end

local function drawing(state)
    local commands, notes = {}, {}
    for _, object in ipairs(state.objects) do
        if object.kind == "note" then notes[object.id] = object end
    end
    for _, object in ipairs(state.objects) do
        if object.kind == "edge" and #commands < MAX_COMMANDS then
            local from, to = notes[object.a], notes[object.b]
            if from and to then
                table.insert(commands, {op = "line", color = "border", stroke = 2,
                    x = from.x + NOTE_WIDTH / 2, y = from.y + NOTE_HEIGHT / 2,
                    x2 = to.x + NOTE_WIDTH / 2, y2 = to.y + NOTE_HEIGHT / 2})
            end
        end
    end
    for _, object in ipairs(state.objects) do
        if object.kind == "note" and #commands + 3 <= MAX_COMMANDS then
            local marked = object.id == state.selected or object.id == state.linkFrom
            table.insert(commands, {op = "rect", x = object.x - 1, y = object.y - 1,
                width = NOTE_WIDTH + 2, height = NOTE_HEIGHT + 2,
                color = marked and "accent" or "border"})
            table.insert(commands, {op = "rect", x = object.x, y = object.y,
                width = NOTE_WIDTH, height = NOTE_HEIGHT, color = "surface"})
            table.insert(commands, {op = "text", x = object.x + 8, y = object.y + 8,
                text = object.text == "" and "EMPTY" or wrap(object.text),
                size = 11, color = object.text == "" and "muted" or nil})
        end
    end
    return commands
end

local function label(key, text, color, size)
    return ui.Text {key = key, text = text, color = color or "muted", fontSize = size or 11}
end

local function button(key, text, event, args, accent)
    return ui.Button {key = key, text = text, onPress = event, args = args,
        color = accent and "background" or "muted", background = accent and "accent" or nil}
end

local function tap(state, event)
    local position = event.position or {x = 0, y = 0}
    local x, y = position.x or 0, position.y or 0
    local target = hit(state.objects, x, y)
    local top = math.max(4, y - NOTE_HEIGHT / 2)
    if state.tool == "note" then
        if count(state.objects, "note") >= MAX_NOTES then
            state.message = "This board holds no more notes."
            return state
        end
        local note = {kind = "note", id = event.token, x = place(x), y = top, text = ""}
        note.key = "o:" .. state.boardId .. ":" .. note.id
        table.insert(state.objects, store(note))
        state.selected = note.id
    elseif state.tool == "move" then
        local object = find(state.objects, state.selected)
        if not object then
            state.message = "Select a note before moving it."
            return state
        end
        object.x = place(x)
        object.y = top
        store(object)
    elseif state.tool == "link" then
        if target == "" then
            state.linkFrom = ""
        elseif state.linkFrom == "" then
            state.linkFrom = target
        elseif state.linkFrom ~= target then
            if count(state.objects, "edge") >= MAX_LINKS then
                state.message = "This board holds no more links."
                return state
            end
            local edge = {kind = "edge", id = event.token, a = state.linkFrom, b = target}
            edge.key = "o:" .. state.boardId .. ":" .. edge.id
            table.insert(state.objects, store(edge))
            state.linkFrom = ""
        end
    elseif state.tool == "erase" then
        if target ~= "" then removeNote(state, target) end
    else
        state.selected = target
    end
    return state
end

local function update(state, event)
    if event.type == "mount" then
        state.boards = readBoards()
        return state
    end
    if event.type ~= "action" then return state end
    local values = event.fields or {}
    local args = event.args or {}
    state.message = ""
    if event.id == "new_board" then
        local key = "b:" .. event.token
        dazzle.data.put("boards", key, "BOARD " .. tostring(#state.boards + 1), 0)
        state.boards = readBoards()
        state.boardId = event.token
        state.objects = {}
        state.selected = ""
        state.linkFrom = ""
        state.mode = "board"
    elseif event.id == "open_board" then
        state.boardId = args.id
        state.objects = readObjects(args.id)
        state.selected = ""
        state.linkFrom = ""
        state.mode = "board"
    elseif event.id == "delete_board" then
        local board = find(state.boards, args.id)
        if board then
            local objects = readObjects(args.id)
            for index, object in ipairs(objects) do
                if index > MAX_DELETES then break end
                dazzle.data.delete("boards", object.key, object.revision)
            end
            dazzle.data.delete("boards", "b:" .. args.id, board.revision)
        end
        state.boards = readBoards()
        if state.boardId == args.id then
            state.boardId = ""
            state.objects = {}
        end
    elseif event.id == "boards" then
        state.boards = readBoards()
        state.mode = "boards"
        state.selected = ""
        state.linkFrom = ""
    elseif event.id == "tool" then
        state.tool = args.tool
        state.linkFrom = ""
    elseif event.id == "tap" then
        return tap(state, event)
    elseif event.id == "save_note" then
        local object = find(state.objects, state.selected)
        if object then
            object.text = clean(values.note or "")
            store(object)
        end
    elseif event.id == "erase_note" then
        if state.selected ~= "" then removeNote(state, state.selected) end
    end
    return state
end

local TOOLS = {
    {id = "select", text = "SELECT"},
    {id = "note", text = "NOTE"},
    {id = "move", text = "MOVE"},
    {id = "link", text = "LINK"},
    {id = "erase", text = "ERASE"},
}

local HINTS = {
    select = "Tap a note to select it.",
    note = "Tap the board to place a note.",
    move = "Tap where the selected note should go.",
    link = "Tap two notes to link them.",
    erase = "Tap a note to erase it and its links.",
}

local function boardsView(state)
    local rows = {}
    for _, board in ipairs(state.boards) do
        table.insert(rows, ui.Box {key = "b_" .. board.id, padding = 12, children = {
            label("n_" .. board.id, board.name, "accent", 14),
            ui.Spacer {key = "s_" .. board.id, height = 8},
            ui.Row {key = "a_" .. board.id, gap = 8, children = {
                button("o_" .. board.id, "OPEN", "open_board", {id = board.id}, true),
                button("d_" .. board.id, "DELETE", "delete_board", {id = board.id}),
            }},
        }})
    end
    if #rows == 0 then
        table.insert(rows, label("empty", "No boards yet. Create one to start arranging notes."))
    end
    return {
        button("new_board", "+ NEW BOARD", "new_board", nil, true),
        ui.Spacer {key = "boards_space", height = 12},
        ui.List {key = "boards_list", flex = 1, gap = 10, children = rows},
    }
end

local function boardView(state)
    local tools = {}
    for _, tool in ipairs(TOOLS) do
        table.insert(tools, ui.Button {key = "t_" .. tool.id, text = tool.text, onPress = "tool",
            args = {tool = tool.id},
            color = state.tool == tool.id and "background" or "muted",
            background = state.tool == tool.id and "accent" or nil})
    end
    local children = {
        ui.Row {key = "tools", gap = 6, children = tools},
        ui.Spacer {key = "tools_space", height = 8},
        label("hint", HINTS[state.tool] or "", "muted", 11),
    }
    local selected = find(state.objects, state.selected)
    if selected then
        table.insert(children, ui.Input {key = "note", label = "Note", value = selected.text, lines = 2})
        table.insert(children, ui.Row {key = "note_actions", gap = 8, children = {
            button("save_note", "SAVE NOTE", "save_note", nil, true),
            button("erase_note", "ERASE NOTE", "erase_note"),
        }})
    end
    table.insert(children, ui.Spacer {key = "surface_space", height = 10})
    table.insert(children, ui.List {key = "surface", flex = 1, children = {
        ui.Canvas {key = "board", height = surfaceHeight(state.objects),
            onPress = "tap", commands = drawing(state)},
    }})
    return children
end

local function view(state)
    local children = {
        ui.Row {key = "heading", gap = 12, children = {
            ui.Text {key = "title", text = "BOARD_", style = "heading", fontSize = 27, bold = true, flex = 1},
            state.mode == "board" and button("back_boards", "BOARDS", "boards") or ui.Spacer {key = "no_back", width = 1},
        }},
        label("subtitle", state.mode == "board"
            and tostring(count(state.objects, "note")) .. " NOTES / " .. tostring(count(state.objects, "edge")) .. " LINKS"
            or "NOTES AND LINKS / TAP TO ARRANGE"),
        ui.Spacer {key = "head_space", height = 14},
    }
    if state.message ~= "" then
        table.insert(children, label("message", state.message, "danger", 12))
    end
    local body = state.mode == "board" and boardView(state) or boardsView(state)
    for _, node in ipairs(body) do table.insert(children, node) end
    return ui.Screen {key = "screen", padding = 16, children = children}
end

return ui.app {
    init = function()
        return {mode = "boards", boards = {}, boardId = "", objects = {},
            selected = "", linkFrom = "", tool = "select", message = ""}
    end,
    update = update,
    view = view,
    back = function(state) if state.mode == "board" then return "boards" end end,
}
