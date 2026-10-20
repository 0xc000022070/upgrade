local TONE = {blocked = "danger", working = "warning", idle = "muted"}
local US, RS = "\31", "\30"
local COLUMN_LIMIT = 8
local DEFAULT_COLUMNS = {"Inbox", "Doing", "Done"}
local CARD_LIMIT = 120
local HOME_COLUMNS = 3
local HOME_ROWS = 4
local HOME_APPROVALS = 2

-- Read from storage on every frame, so a page and its Home card never hold different boards.
local layout

local function remember(key, value)
    local saved = striked.data.get("preferences", key)
    striked.data.put("preferences", key, value, saved and saved.revision or 0)
end

local function recall(key)
    local saved = striked.data.get("preferences", key)
    return saved and saved.value or ""
end

local function split(text, separator)
    local parts = {}
    if text == "" then return parts end
    local start = 1
    while true do
        local at = string.find(text, separator, start, true)
        if not at then
            table.insert(parts, string.sub(text, start))
            return parts
        end
        table.insert(parts, string.sub(text, start, at - 1))
        start = at + 1
    end
end

local function clean(name)
    local flat = string.gsub(name or "", "%c", " ")
    return string.sub(string.match(flat, "^%s*(.-)%s*$"), 1, 24)
end

local function load()
    local loaded = {next = #DEFAULT_COLUMNS + 1, columns = {}, cards = {}, awake = recall("awake") == "on"}
    local parts = split(recall("columns"), RS)
    for i = 2, #parts do
        local fields = split(parts[i], US)
        local id = tonumber(fields[1])
        if id then table.insert(loaded.columns, {id = id, name = fields[2] or ""}) end
    end
    if #loaded.columns > 0 then
        loaded.next = tonumber(parts[1]) or 1
    else
        for i, name in ipairs(DEFAULT_COLUMNS) do table.insert(loaded.columns, {id = i, name = name}) end
    end
    for _, line in ipairs(split(recall("cards"), RS)) do
        local fields = split(line, US)
        local col = tonumber(fields[2])
        if fields[1] and col then table.insert(loaded.cards, {id = fields[1], col = col, host = fields[3] or ""}) end
    end
    return loaded
end

local function saveColumns()
    local parts = {tostring(layout.next)}
    for _, column in ipairs(layout.columns) do
        table.insert(parts, column.id .. US .. column.name)
    end
    remember("columns", table.concat(parts, RS))
end

local function saveCards()
    local lines = {}
    for _, entry in ipairs(layout.cards) do
        table.insert(lines, table.concat({entry.id, tostring(entry.col), entry.host}, US))
    end
    remember("cards", table.concat(lines, RS))
end

local function holds(columns, id)
    for i, column in ipairs(columns) do
        if column.id == id then return i end
    end
    return nil
end

local function place(state)
    local live, ok = {}, {}
    for _, host in ipairs(state.hosts) do
        if host.ok then ok[host.id] = true end
    end
    for _, item in ipairs(state.items) do live[item.id] = true end
    local kept, seen, changed = {}, {}, false
    for _, entry in ipairs(layout.cards) do
        if seen[entry.id] or not live[entry.id] and state.ready and ok[entry.host] then
            changed = true
        else
            seen[entry.id] = true
            if not holds(layout.columns, entry.col) then
                entry.col = layout.columns[1].id
                changed = true
            end
            table.insert(kept, entry)
        end
    end
    for _, item in ipairs(state.items) do
        if not seen[item.id] then
            table.insert(kept, {id = item.id, col = layout.columns[1].id, host = item.host})
            changed = true
        end
    end
    layout.cards = kept
    if changed then saveCards() end
end

local function move(id, col, before)
    local index
    for i, entry in ipairs(layout.cards) do
        if entry.id == id then index = i end
    end
    if not index then return end
    local entry = table.remove(layout.cards, index)
    entry.col = col
    local at = #layout.cards + 1
    for i, other in ipairs(layout.cards) do
        if other.id == before then at = i break end
    end
    table.insert(layout.cards, at, entry)
    saveCards()
end

local function list(state)
    return state, {ui.effect("agents", "list", {}, "list")}
end

local function project(item)
    if item.workspace ~= "" then return item.workspace end
    return string.match(item.directory, "([^/]+)/*$") or item.directory
end

local function detail(item)
    if item.approval then return item.approval.line end
    if item.question ~= "" then return item.question end
    return item.message
end

local function matches(search, item)
    local hay = string.lower(table.concat({item.title, item.question, item.message, item.directory, item.agent,
        item.approval and item.approval.line or ""}, " "))
    for word in string.gmatch(string.lower(search), "%S+") do
        if not string.find(hay, word, 1, true) then return false end
    end
    return true
end

local function title(item)
    return item.title ~= "" and item.title or "Untitled session"
end

local function lanes(state, search)
    local byId = {}
    for _, item in ipairs(state.items) do byId[item.id] = item end
    local columns = layout.columns
    local result = {}
    for _, column in ipairs(columns) do table.insert(result, {id = column.id, name = column.name, items = {}}) end
    for _, entry in ipairs(layout.cards) do
        local item = byId[entry.id]
        if item and matches(search, item) then
            table.insert(result[holds(columns, entry.col) or 1].items, item)
        end
    end
    return result
end

local function answers(key, item)
    return ui.Row {key = key .. "answer", gap = 8, children = {
        ui.Button {key = key .. "deny", text = "DENY", flex = 1, color = "danger", onPress = "deny", args = {approval = item.approval.id}},
        ui.Button {key = key .. "allow", text = "ALLOW", flex = 1, background = "accent", onPress = "allow", args = {approval = item.approval.id}},
    }}
end

local function card(item)
    local key = "c_" .. item.id
    local tone = TONE[item.state]
    local children = {
        ui.Row {key = key .. "head", gap = 8, children = {
            ui.Text {key = key .. "agent", text = string.upper(item.agent), bold = true, flex = 1, lines = 1, color = "muted"},
            ui.StatusTag {key = key .. "state", label = string.upper(item.state), color = tone},
        }},
        ui.Text {key = key .. "title", text = title(item), bold = true, lines = 2},
    }
    local line = detail(item)
    if line ~= "" then
        table.insert(children, ui.Text {key = key .. "detail", text = line, lines = 3, color = item.approval and "danger" or "muted"})
    end
    local place = project(item)
    table.insert(children, ui.Text {key = key .. "place", text = (place ~= "" and place .. " · " or "") .. item.host_name,
        fontSize = 11, lines = 1, color = "muted"})
    if item.approval then table.insert(children, answers(key, item)) end
    return ui.Box {key = key, padding = 10, border = item.state == "blocked" and "danger" or nil,
        onPress = "open", drag = item.id, onDrop = "drop_card", args = {id = item.id},
        children = {ui.Column {key = key .. "rows", gap = 6, align = "stretch", children = children}}}
end

local function board(state)
    local shown = 0
    local result = {}
    for _, lane in ipairs(lanes(state, state.search)) do
        local key = "l_" .. lane.id
        local cards = {}
        for _, item in ipairs(lane.items) do
            if shown >= CARD_LIMIT then break end
            shown += 1
            table.insert(cards, card(item))
        end
        local hidden = #lane.items - #cards
        if hidden > 0 then
            table.insert(cards, ui.Text {key = key .. "more", text = "+" .. hidden .. " more · search to narrow", color = "muted"})
        end
        table.insert(result, ui.Column {key = key, width = 280, gap = 8, align = "stretch", onDrop = "drop_column", args = {col = lane.id},
            children = {
                ui.Box {key = key .. "head", padding = 8, children = {
                    ui.Row {key = key .. "row", gap = 8, children = {
                        ui.Text {key = key .. "name", text = string.upper(lane.name), bold = true, flex = 1, lines = 1},
                        ui.Text {key = key .. "count", text = tostring(#lane.items), color = "muted"},
                    }},
                }},
                ui.List {key = key .. "cards", flex = 1, gap = 8, children = cards},
            }})
    end
    return result
end

local function editor(state)
    local columns = layout.columns
    local rows = {}
    for i, column in ipairs(columns) do
        local key = "e_" .. column.id
        table.insert(rows, ui.Row {key = key, gap = 6, children = {
            ui.Input {key = key .. "name", label = "Column " .. i, value = column.name, onChange = "rename", args = {col = column.id}, flex = 1},
            ui.Button {key = key .. "left", text = "←", onPress = "left", args = {col = column.id}, enabled = i > 1},
            ui.Button {key = key .. "right", text = "→", onPress = "right", args = {col = column.id}, enabled = i < #columns},
            ui.Button {key = key .. "delete", text = "×", color = "danger", onPress = "delete", args = {col = column.id}, enabled = #columns > 1},
        }})
    end
    if #columns < COLUMN_LIMIT then
        table.insert(rows, ui.Row {key = "add", gap = 6, children = {
            ui.Input {key = "newcol_" .. #columns, label = "New column", onChange = "add", flex = 1},
            ui.Button {key = "addcol", text = "ADD", onPress = "add"},
        }})
    end
    table.insert(rows, ui.Toggle {key = "awake", label = "Keep screen on", value = layout.awake, onChange = "awake"})
    return ui.Disclosure {key = "columns", title = "Columns",
        subtitle = #columns .. " columns" .. (layout.awake and " · screen stays on" or ""), children = rows}
end

local function view(state)
    layout = layout or load()
    local children = {}
    if state.message ~= "" then
        table.insert(children, ui.Text {key = "message", text = state.message, color = state.failed and "danger" or "accent"})
    end
    table.insert(children, ui.Input {key = "search", label = "Search", hint = "Title, prompt, message, directory or agent", value = state.search, onChange = "search", live = true})
    table.insert(children, editor(state))
    for _, host in ipairs(state.hosts) do
        if not host.ok then
            table.insert(children, ui.Text {key = "down_" .. host.id, text = string.upper(host.name) .. " · " .. (host.reason or "did not answer"),
                color = "danger", lines = 2})
        end
    end
    if not state.ready then
        table.insert(children, ui.Text {key = "waiting", text = "Reading hosts…", color = "muted"})
    end
    table.insert(children, ui.List {key = "board", direction = "horizontal", flex = 1, gap = 12, children = board(state)})
    return ui.Page {key = "page", title = "KANBAN", breadcrumb = "/ TOOLS", fill = true, awake = layout.awake,
        children = {ui.Column {key = "body", gap = 8, align = "stretch", children = children}}}
end

local function inbox(state)
    layout = layout or load()
    local children = {}
    if state.message ~= "" then
        table.insert(children, ui.Text {key = "message", text = state.message, color = state.failed and "danger" or "accent"})
    end
    local asking = 0
    for _, item in ipairs(state.items) do
        if item.approval and asking < HOME_APPROVALS then
            asking += 1
            local key = "a_" .. item.id
            table.insert(children, ui.Box {key = key, padding = 8, border = "danger", onPress = "open", args = {id = item.id}, children = {
                ui.Column {key = key .. "rows", gap = 4, align = "stretch", children = {
                    ui.Text {key = key .. "title", text = string.upper(item.agent) .. " · " .. title(item), bold = true, lines = 1},
                    ui.Text {key = key .. "line", text = item.approval.line, lines = 2, color = "danger"},
                    answers(key, item),
                }},
            }})
        end
    end
    local columns = {}
    local all = lanes(state, "")
    for i = 1, math.min(#all, HOME_COLUMNS) do
        local lane = all[i]
        local key = "m_" .. lane.id
        local rows = {
            ui.Text {key = key .. "name", text = string.upper(lane.name) .. " " .. #lane.items, bold = true, lines = 1, fontSize = 12, color = "muted"},
        }
        for j = 1, math.min(#lane.items, HOME_ROWS) do
            local item = lane.items[j]
            table.insert(rows, ui.Box {key = key .. "_" .. item.id, padding = 6, onPress = "open", args = {id = item.id},
                border = item.state == "blocked" and "danger" or nil, children = {
                    ui.Text {key = key .. "_" .. item.id .. "t", text = title(item), lines = 1, fontSize = 12, color = TONE[item.state]},
                }})
        end
        if #lane.items > HOME_ROWS then
            table.insert(rows, ui.Text {key = key .. "more", text = "+" .. (#lane.items - HOME_ROWS), fontSize = 11, color = "muted"})
        end
        table.insert(columns, ui.Column {key = key, flex = 1, gap = 4, align = "stretch", children = rows})
    end
    table.insert(children, ui.Row {key = "mini", gap = 6, align = "start", children = columns})
    if #all > HOME_COLUMNS then
        table.insert(children, ui.Text {key = "hidden", text = "+" .. (#all - HOME_COLUMNS) .. " more columns on the board", fontSize = 11, color = "muted"})
    end
    if not state.ready then
        table.insert(children, ui.Text {key = "waiting", text = "Reading hosts…", fontSize = 11, color = "muted"})
    end
    table.insert(children, ui.Button {key = "open_board", text = "OPEN BOARD", opens = "main"})
    return ui.Panel {key = "inbox", title = "AGENTS",
        children = {ui.Column {key = "inboxrows", gap = 8, align = "stretch", children = children}}}
end

local function columnAction(state, id, col, value)
    local columns = layout.columns
    local index = holds(columns, col)
    if id == "add" then
        local name = clean(value)
        if name == "" then
            state.message = "Name the column first"
            state.failed = true
            return
        end
        if #columns >= COLUMN_LIMIT then return end
        table.insert(columns, {id = layout.next, name = name})
        layout.next += 1
    elseif not index then
        return
    elseif id == "rename" then
        local name = clean(value)
        if name == "" then return end
        columns[index].name = name
    elseif id == "left" or id == "right" then
        local other = index + (id == "left" and -1 or 1)
        if other < 1 or other > #columns then return end
        columns[index], columns[other] = columns[other], columns[index]
    elseif id == "delete" then
        if #columns < 2 then return end
        table.remove(columns, index)
        for _, entry in ipairs(layout.cards) do
            if entry.col == col then entry.col = columns[1].id end
        end
        saveCards()
    end
    saveColumns()
end

local function update(state, event)
    layout = load()
    if event.type == "mount" then return list(state) end
    if event.type == "changed" or event.type == "refresh" then return list(state) end
    if event.type == "result" then
        if not event.ok then
            state.message = event.error
            state.failed = true
            if event.id ~= "list" then return list(state) end
            return state
        end
        if event.id == "list" then
            state.ready = event.value.ready
            state.items = event.value.items
            state.hosts = event.value.hosts
            place(state)
            -- The feed can trail an answer by a read; keep its buttons hidden until it catches up.
            local still = {}
            for _, item in ipairs(state.items) do
                if item.approval and state.answered[item.approval.id] then
                    still[item.approval.id] = true
                    item.approval = nil
                end
            end
            state.answered = still
        elseif event.id == "answer" then
            state.message = string.upper(event.value.answer)
            state.failed = false
            state.answered[state.answering] = true
            return list(state)
        end
        return state
    end
    if event.type ~= "action" then return state end
    local fields = event.fields or {}
    local args = event.args or {}
    if fields.search ~= nil then state.search = fields.search end
    state.message = ""
    if event.id == "search" then
        state.search = event.value
    elseif event.id == "drop_column" then
        move(event.value, args.col, nil)
    elseif event.id == "drop_card" then
        if event.value == args.id then return state end
        for _, entry in ipairs(layout.cards) do
            if entry.id == args.id then
                move(event.value, entry.col, args.id)
                break
            end
        end
    elseif event.id == "add" then
        columnAction(state, "add", nil, fields["newcol_" .. #layout.columns])
    elseif event.id == "rename" or event.id == "left" or event.id == "right" or event.id == "delete" then
        columnAction(state, event.id, args.col, event.value)
    elseif event.id == "awake" then
        layout.awake = event.value == true
        remember("awake", layout.awake and "on" or "off")
    elseif event.id == "allow" or event.id == "deny" then
        state.answering = args.approval
        return state, {ui.effect("agents", "answer", {approval = args.approval, allow = event.id == "allow"}, "answer")}
    elseif event.id == "open" then
        return state, {ui.effect("agents", "open", {id = args.id}, "open")}
    end
    return state
end

return ui.app {
    init = function()
        return {ready = false, items = {}, hosts = {}, message = "", failed = false, search = "",
            answered = {}, answering = ""}
    end,
    update = update,
    view = view,
    cards = {inbox = inbox},
}
