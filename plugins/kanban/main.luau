local STATES = {"blocked", "working", "done", "idle"}
local RANK = {blocked = 1, working = 2, done = 3, idle = 4}
local TONE = {blocked = "danger", working = "warning", idle = "muted"}
local CARD_LIMIT = 120
local HOME_BLOCKED = 3

local function remember(key, value)
    local saved = striked.data.get("preferences", key)
    striked.data.put("preferences", key, value, saved and saved.revision or 0)
end

local function recall(key)
    local saved = striked.data.get("preferences", key)
    return saved and saved.value or ""
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

local function age(seconds)
    if seconds < 60 then return tostring(seconds) .. "s" end
    if seconds < 3600 then return tostring(seconds // 60) .. "m" end
    return tostring(seconds // 3600) .. "h"
end

local function matches(state, item)
    if state.agent ~= "" and item.agent ~= state.agent then return false end
    if state.host ~= "" and item.host ~= state.host then return false end
    if state.project ~= "" and project(item) ~= state.project then return false end
    local hay = string.lower(table.concat({item.title, item.question, item.message, item.directory, item.agent,
        item.approval and item.approval.line or ""}, " "))
    for word in string.gmatch(string.lower(state.search), "%S+") do
        if not string.find(hay, word, 1, true) then return false end
    end
    return true
end

local function ordered(a, b)
    local ra, rb = RANK[a.state] or 5, RANK[b.state] or 5
    if ra ~= rb then return ra < rb end
    if a.title ~= b.title then return a.title < b.title end
    return a.id < b.id
end

local function columns(state)
    local result = {}
    local index = {}
    local function column(id, name, tone)
        if not index[id] then
            index[id] = {id = id, name = name, tone = tone, items = {}}
            table.insert(result, index[id])
        end
        return index[id]
    end
    if state.group == "status" then
        for _, word in ipairs(STATES) do column(word, string.upper(word), TONE[word]) end
    elseif state.group == "machine" then
        for _, host in ipairs(state.hosts) do column(host.id, string.upper(host.name), not host.ok and "danger" or nil) end
    end
    local items = {}
    for _, item in ipairs(state.items) do
        if matches(state, item) then table.insert(items, item) end
    end
    table.sort(items, ordered)
    for _, item in ipairs(items) do
        local target
        if state.group == "machine" then
            target = column(item.host, string.upper(item.host_name))
        elseif state.group == "workspace" then
            local name = project(item)
            target = column(name, name == "" and "NO WORKSPACE" or name)
        else
            target = column(item.state, string.upper(item.state), TONE[item.state])
        end
        table.insert(target.items, item)
    end
    if state.group == "workspace" then
        table.sort(result, function(a, b) return a.name < b.name end)
    end
    return result
end

local function options(state, read, labelOf)
    local seen = {}
    local result = {{value = "", label = "All"}}
    for _, item in ipairs(state.items) do
        local value = read(item)
        if value ~= "" and not seen[value] then
            seen[value] = true
            table.insert(result, {value = value, label = labelOf and labelOf(item) or value})
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
            ui.Text {key = key .. "agent", text = string.upper(item.agent), bold = true, flex = 1, lines = 1, color = tone},
            ui.Text {key = key .. "state", text = string.upper(item.state), fontSize = 11, color = tone},
        }},
        ui.Text {key = key .. "title", text = item.title ~= "" and item.title or "Untitled session", bold = true, lines = 2},
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
        onPress = "open", args = {id = item.id},
        children = {ui.Column {key = key .. "rows", gap = 6, align = "stretch", children = children}}}
end

local function board(state)
    local shown = 0
    local lanes = {}
    for _, lane in ipairs(columns(state)) do
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
        table.insert(lanes, ui.Column {key = key, width = 280, gap = 8, align = "stretch", children = {
            ui.Box {key = key .. "head", padding = 8, border = lane.tone, children = {
                ui.Row {key = key .. "row", gap = 8, children = {
                    ui.Text {key = key .. "name", text = lane.name, bold = true, flex = 1, lines = 1, color = lane.tone},
                    ui.Text {key = key .. "count", text = tostring(#lane.items), color = "muted"},
                }},
            }},
            ui.List {key = key .. "cards", flex = 1, gap = 8, children = cards},
        }})
    end
    return lanes
end

local function groupButton(state, id, label)
    return ui.Button {key = "group_" .. id, text = label, flex = 1, onPress = "group", args = {group = id},
        background = state.group == id and "accent" or nil}
end

local function view(state)
    local filters = {}
    if state.agent ~= "" then table.insert(filters, string.upper(state.agent)) end
    if state.host ~= "" then
        local name = state.host
        for _, host in ipairs(state.hosts) do if host.id == state.host then name = host.name end end
        table.insert(filters, name)
    end
    if state.project ~= "" then table.insert(filters, state.project) end
    local children = {}
    if state.message ~= "" then
        table.insert(children, ui.Text {key = "message", text = state.message, color = state.failed and "danger" or "accent"})
    end
    table.insert(children, ui.Input {key = "search", label = "Search", hint = "Title, prompt, message, directory or agent", value = state.search, onChange = "search", live = true})
    table.insert(children, ui.Row {key = "group", gap = 8, children = {
        groupButton(state, "status", "STATUS"), groupButton(state, "machine", "MACHINE"), groupButton(state, "workspace", "WORKSPACE"),
    }})
    table.insert(children, ui.Disclosure {key = "filters", title = "Filters",
        subtitle = #filters > 0 and table.concat(filters, " · ") or (state.awake and "All sessions · screen stays on" or "All sessions"),
        children = {
            ui.Select {key = "agent", label = "Agent", value = state.agent, onChange = "filter_agent",
                options = options(state, function(item) return item.agent end, function(item) return string.upper(item.agent) end)},
            ui.Select {key = "host", label = "Host", value = state.host, onChange = "filter_host",
                options = options(state, function(item) return item.host end, function(item) return item.host_name end)},
            ui.Select {key = "project", label = "Project", value = state.project, onChange = "filter_project", options = options(state, project)},
            ui.Toggle {key = "awake", label = "Keep screen on", value = state.awake, onChange = "awake"},
            ui.Button {key = "clear", text = "Clear filters", onPress = "clear"},
        }})
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
    return ui.Page {key = "page", title = "KANBAN", breadcrumb = "/ TOOLS", fill = true, awake = state.awake,
        children = {ui.Column {key = "body", gap = 8, align = "stretch", children = children}}}
end

local function inbox(state)
    local counts = {blocked = 0, working = 0, done = 0}
    local blocked = {}
    for _, item in ipairs(state.items) do
        if counts[item.state] then counts[item.state] += 1 end
        if item.state == "blocked" then table.insert(blocked, item) end
    end
    table.sort(blocked, ordered)
    local children = {}
    if state.message ~= "" then
        table.insert(children, ui.Text {key = "message", text = state.message, color = state.failed and "danger" or "accent"})
    end
    table.insert(children, ui.Row {key = "counts", gap = 8, children = {
        ui.BracketLabel {key = "blocked", label = "BLOCKED", value = tostring(counts.blocked), color = counts.blocked > 0 and "danger" or nil, flex = 1},
        ui.BracketLabel {key = "working", label = "WORKING", value = tostring(counts.working), flex = 1},
        ui.BracketLabel {key = "done", label = "DONE", value = tostring(counts.done), flex = 1},
    }})
    for i = 1, math.min(#blocked, HOME_BLOCKED) do
        local item = blocked[i]
        local key = "b_" .. item.id
        local rows = {
            ui.Text {key = key .. "title", text = item.title ~= "" and item.title or string.upper(item.agent), bold = true, lines = 1},
            ui.Text {key = key .. "detail", text = detail(item), lines = 2, color = "muted"},
            ui.Text {key = key .. "who", text = string.upper(item.agent) .. " · " .. item.host_name, fontSize = 11, lines = 1, color = "muted"},
        }
        if item.approval then table.insert(rows, answers(key, item)) end
        table.insert(children, ui.Box {key = key, padding = 8, border = "danger", onPress = "open", args = {id = item.id},
            children = {ui.Column {key = key .. "rows", gap = 4, align = "stretch", children = rows}}})
    end
    if #blocked > HOME_BLOCKED then
        table.insert(children, ui.Text {key = "more", text = "+" .. (#blocked - HOME_BLOCKED) .. " more blocked", color = "muted"})
    end
    local newest
    for _, host in ipairs(state.hosts) do
        if host.read_ago and (newest == nil or host.read_ago < newest) then newest = host.read_ago end
    end
    table.insert(children, ui.Text {key = "read", color = "muted", fontSize = 11,
        text = newest and "READ " .. age(newest) .. " AGO" or (state.ready and "NO HOST ANSWERED YET" or "READING HOSTS")})
    table.insert(children, ui.Button {key = "open_board", text = "OPEN BOARD", opens = "main"})
    return ui.Panel {key = "inbox", title = "AGENT BOARD",
        children = {ui.Column {key = "inboxrows", gap = 8, align = "stretch", children = children}}}
end

local function update(state, event)
    if event.type == "mount" then
        if event.widget == nil then
            state.group = recall("group")
            if state.group == "" then state.group = "status" end
            state.agent = recall("agent")
            state.host = recall("host")
            state.project = recall("project")
            state.awake = recall("awake") == "on"
        end
        return list(state)
    end
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
    elseif event.id == "group" then
        state.group = args.group
        remember("group", state.group)
    elseif event.id == "filter_agent" or event.id == "filter_host" or event.id == "filter_project" then
        local name = string.sub(event.id, 8)
        state[name] = event.value
        remember(name, event.value)
    elseif event.id == "awake" then
        state.awake = event.value == true
        remember("awake", state.awake and "on" or "off")
    elseif event.id == "clear" then
        for _, name in ipairs({"agent", "host", "project"}) do
            state[name] = ""
            remember(name, "")
        end
        state.search = ""
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
        return {ready = false, items = {}, hosts = {}, message = "", failed = false,
            group = "status", agent = "", host = "", project = "", awake = false, search = "",
            answered = {}, answering = ""}
    end,
    update = update,
    view = view,
    cards = {inbox = inbox},
}
