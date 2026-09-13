local function label(key, text, color, size)
    return ui.Text {key = key, text = text, color = color or "muted", fontSize = size or 11}
end

local function button(key, text, event, args, accent)
    return ui.Button {key = key, text = text, onPress = event, args = args,
        color = accent and "background" or "muted", background = accent and "accent" or nil}
end

local function request(state, operation, args, id)
    args = args or {}
    args.host = state.host
    state.message = ""
    return state, {ui.effect("scheduler", operation, args, id)}
end

local function refresh(state)
    return request(state, state.mode == "history" and "history" or "list", {}, "rows")
end

local function field(state, values, key)
    if values[key] ~= nil then return values[key] end
    return state.edit[key] or ""
end

local function update(state, event)
    if event.type == "mount" then
        local saved = dazzle.data.get("preferences", "host")
        state.host = saved and saved.value or ""
        return state, {ui.effect("hosts", "list", {}, "hosts")}
    end
    if event.type == "result" then
        if not event.ok then state.message = event.error; return state end
        if event.id == "hosts" then
            state.hosts = event.value.items
            for _, host in ipairs(state.hosts) do
                if host.id == state.host then return request(state, "inspect", {}, "inspect") end
            end
            state.host = ""
        elseif event.id == "inspect" or event.id == "setup" then
            state.hostInfo = event.value
            if event.value.installed then return refresh(state) end
        elseif event.id == "rows" then
            state.rows = event.value.items
            state.more = event.value.more
            state.offset = event.value.offset or 0
            state.paused = event.value.paused or false
            state.message = event.value.error or ""
        elseif event.id == "edit" then
            state.edit = event.value
            state.mode = "edit"
            state.edit.when = state.edit["repeat"] == "daily" and state.edit.time or state.edit.date .. "T" .. state.edit.time
            state.edit.timeout = tostring(state.edit.timeout)
        elseif event.id == "output" then
            state.output = event.value
            state.mode = "output"
        elseif event.id == "usage" then
            state.usage = event.value
        elseif event.id == "saved" then
            state.mode = "list"
            state.rows = {}
            return refresh(state)
        elseif event.id == "ran" then
            state.mode = "history"
            state.rows = {}
            return refresh(state)
        else
            return refresh(state)
        end
        return state
    end
    if event.type ~= "action" then return state end
    local values = event.fields or {}
    local args = event.args or {}
    if event.id == "choose_host" then
        state.host = event.value
        state.hostInfo = nil
        state.rows = {}
        state.mode = "list"
        local saved = dazzle.data.get("preferences", "host")
        dazzle.data.put("preferences", "host", state.host, saved and saved.revision or 0)
        return request(state, "inspect", {}, "inspect")
    elseif event.id == "reload_hosts" then
        return state, {ui.effect("hosts", "list", {}, "hosts")}
    elseif event.id == "setup" then
        return request(state, "setup", {}, "setup")
    elseif event.id == "inspect" then
        return request(state, "inspect", {}, "inspect")
    elseif event.id == "new" then
        state.mode = "edit"
        state.edit = {id = event.token, revision = 0, title = "", directory = "", prompt = "",
            agent = state.hostInfo.agents[1] or "codex", model = "", ["repeat"] = "daily", when = "09:00",
            timezone = state.hostInfo.timezone or "UTC", timeout = "900"}
    elseif event.id == "edit" then
        return request(state, "get", {id = args.id}, "edit")
    elseif event.id == "frequency" then
        for key, value in pairs(values) do state.edit[key] = value end
        state.edit["repeat"] = event.value
        state.edit.when = event.value == "daily" and "09:00" or string.sub(event.now, 1, 10) .. "T09:00"
    elseif event.id == "save" then
        local when = field(state, values, "when")
        local repeating = field(state, values, "repeat")
        local job = {id = state.edit.id, revision = state.edit.revision,
            title = field(state, values, "title"), directory = field(state, values, "directory"),
            agent = field(state, values, "agent"), model = field(state, values, "model"),
            prompt = field(state, values, "prompt"), ["repeat"] = repeating,
            date = repeating == "once" and string.sub(when, 1, 10) or "",
            time = repeating == "once" and string.sub(when, 12, 16) or when,
            timezone = field(state, values, "timezone"), timeout = tonumber(field(state, values, "timeout")) or 0}
        for key, value in pairs(values) do state.edit[key] = value end
        return request(state, "save", {schedule = job}, "saved")
    elseif event.id == "history" then
        state.mode = "history"
        state.rows = {}
        return refresh(state)
    elseif event.id == "refresh" then
        if state.mode == "output" then return request(state, "output", {id = state.runId}, "output") end
        return refresh(state)
    elseif event.id == "next_page" or event.id == "previous_page" then
        local offset = math.max(0, state.offset + (event.id == "next_page" and 32 or -32))
        return request(state, state.mode == "history" and "history" or "list", {offset = offset}, "rows")
    elseif event.id == "pause" or event.id == "resume" then
        return request(state, event.id, {id = args.id}, "changed")
    elseif event.id == "run" then
        return request(state, "run", {id = args.id}, "ran")
    elseif event.id == "output" then
        state.runId = args.id
        return request(state, "output", {id = args.id}, "output")
    elseif event.id == "pause_scope" or event.id == "resume_scope" then
        return request(state, event.id, {}, "changed")
    elseif event.id == "usage" then
        return request(state, "usage", {}, "usage")
    elseif event.id == "back" then
        state.mode = state.mode == "output" and "history" or "list"
        state.rows = {}
        state.message = ""
        return refresh(state)
    end
    return state
end

local function editor(state)
    local edit = state.edit
    local agents = {}
    for _, agent in ipairs(state.hostInfo.agents) do table.insert(agents, {value = agent, label = string.upper(agent)}) end
    return ui.List {key = "editor", flex = 1, gap = 14, children = {
        label("edit_title", edit.revision == 0 and "NEW SCHEDULE" or "EDIT SCHEDULE", "accent", 16),
        ui.Input {key = "title", label = "Name", value = edit.title},
        ui.Input {key = "directory", label = "Repository directory on host", value = edit.directory},
        ui.Select {key = "agent", label = "Agent", value = edit.agent, options = agents},
        ui.Input {key = "model", label = "Model (empty uses host default)", value = edit.model},
        ui.Input {key = "prompt", label = "Prompt", value = edit.prompt, lines = 5},
        ui.Select {key = "repeat", label = "Repeat", value = edit["repeat"], onChange = "frequency",
            options = {{value = "daily", label = "Daily"}, {value = "once", label = "Once"}}},
        ui.DateTime {key = "when", label = "Run at", value = edit.when, mode = edit["repeat"] == "daily" and "time" or "datetime"},
        ui.Input {key = "timezone", label = "Timezone (IANA)", value = edit.timezone},
        ui.Input {key = "timeout", label = "Timeout in seconds (60–14400)", value = edit.timeout},
        label("permission_note", "Runs use the host agent's existing authentication and permissions."),
        button("save", "SAVE SCHEDULE", "save", nil, true),
        button("cancel", "CANCEL", "back"),
    }}
end

local function view(state)
    local hosts = {}
    for _, host in ipairs(state.hosts) do table.insert(hosts, {value = host.id, label = host.name}) end
    local children = {
        ui.Row {key = "heading", gap = 12, children = {
            ui.Text {key = "title_text", text = "AGENT SCHEDULES_", style = "heading", fontSize = 27, bold = true, flex = 1},
            ui.Canvas {key = "clock_mark", width = 36, height = 36, commands = {
                {op = "circle", x = 18, y = 18, radius = 16, color = "surface"},
                {op = "line", x = 18, y = 7, x2 = 18, y2 = 18, color = "accent", stroke = 2},
                {op = "line", x = 18, y = 18, x2 = 27, y2 = 22, color = "accent", stroke = 2},
            }},
        }},
        label("subtitle", "HOST EXECUTION / PHONE CONTROL"),
        ui.Spacer {key = "space_top", height = 14},
    }
    if #hosts == 0 then
        table.insert(children, ui.Box {key = "no_hosts", children = {
            label("no_hosts_title", "NO HOSTS REGISTERED", "accent", 14),
            ui.Spacer {key = "no_hosts_space", height = 12},
            label("no_hosts_body", "Add and verify a machine in HOSTS. Schedules run there, even while this phone is offline."),
            button("reload_hosts", "REFRESH HOSTS", "reload_hosts"),
        }})
    else
        table.insert(children, ui.Select {key = "host", label = "Host", value = state.host, options = hosts, onChange = "choose_host"})
    end
    if state.message ~= "" then table.insert(children, label("error", state.message, "danger", 12)) end
    if state.hostInfo then
        local info = state.hostInfo
        if not info.installed or info.timer_active == false then
            table.insert(children, ui.Box {key = "setup", children = {
                label("setup_title", info.supported and "HOST READY" or "HOST SUPPORT REQUIRED", "accent", 14),
                ui.Spacer {key = "setup_space", height = 12},
                label("setup_reason", info.supported and "Install the private runner and systemd user timer on this host. No other jobs are changed." or info.reason),
                info.supported and button("setup_button", "ENABLE HOST SCHEDULING", "setup", nil, true) or button("probe_again", "CHECK HOST AGAIN", "inspect", nil),
            }})
        elseif state.mode == "edit" then
            table.insert(children, editor(state))
        elseif state.mode == "output" then
            table.insert(children, label("run_status", string.upper(state.output.status), "accent"))
            table.insert(children, button("output_refresh", "REFRESH OUTPUT", "refresh"))
            local chunks = {}
            local output = state.output.text
            local start = 1
            while start <= #output do
                local ending = utf8.offset(output, 2049, start) or (#output + 1)
                table.insert(chunks, label("output_" .. tostring(#chunks + 1), string.sub(output, start, ending - 1), nil, 11))
                start = ending
            end
            if #chunks == 0 then table.insert(chunks, label("output_empty", "No output yet.")) end
            table.insert(children, ui.List {key = "output_list", flex = 1, children = chunks})
        else
            table.insert(children, ui.Row {key = "actions", gap = 8, children = {
                ui.Button {key = "new", text = "+ NEW", onPress = "new", enabled = #info.agents > 0, background = "accent", color = "background"},
                button("history", "HISTORY", "history"),
                button("refresh", "REFRESH", "refresh"),
            }})
            if #info.agents == 0 then table.insert(children, label("no_agents", "Install and authenticate Codex or Claude on this host before creating schedules.")) end
            if state.paused then
                table.insert(children, button("resume_all", "HOST PAUSED · RESUME", "resume_scope", nil, true))
            elseif state.mode == "list" then
                table.insert(children, button("pause_all", "PAUSE FUTURE RUNS", "pause_scope"))
            end
            local rows = {}
            for _, row in ipairs(state.rows) do
                local key = "r_" .. row.id
                local contents = {label(key .. "title", row.title, "text", 14), ui.Spacer {key = key .. "space", height = 8}}
                if state.mode == "history" then
                    table.insert(contents, label(key .. "status", string.upper(row.status) .. " / " .. row.started_label, row.status == "failed" and "danger" or "muted"))
                    table.insert(contents, button(key .. "output", "OUTPUT", "output", {id = row.id}))
                else
                    table.insert(contents, label(key .. "time", (row.enabled and "NEXT " or "PAUSED ") .. row.next_label))
                    table.insert(contents, label(key .. "agent", string.upper(row.agent) .. " / " .. string.upper(row["repeat"])))
                    table.insert(contents, ui.Row {key = key .. "buttons", gap = 8, children = {
                        button(key .. "edit", "EDIT", "edit", {id = row.id}),
                        button(key .. "pause", row.enabled and "PAUSE" or "RESUME", row.enabled and "pause" or "resume", {id = row.id}),
                        button(key .. "run", "RUN NOW", "run", {id = row.id}),
                    }})
                end
                table.insert(rows, ui.Box {key = key, padding = 12, children = contents})
            end
            if #rows == 0 then table.insert(rows, label("empty", state.mode == "history" and "No runs yet." or "No schedules yet. Create a run to get started.")) end
            table.insert(children, ui.List {key = "rows", flex = 1, gap = 10, children = rows})
            if state.more or state.offset > 0 then
                table.insert(children, ui.Row {key = "pagination", gap = 12, children = {
                    button("previous_page", "PREVIOUS", "previous_page"), button("next_page", "NEXT", "next_page"),
                }})
            end
            table.insert(children, button("usage", "DATA USAGE", "usage"))
            if state.usage then table.insert(children, label("usage_text", tostring(state.usage.schedules) .. " schedules / " .. tostring(state.usage.runs) .. " runs / " .. tostring(state.usage.bytes) .. " bytes")) end
        end
    end
    return ui.Screen {key = "screen", padding = 16, children = children}
end

return ui.app {
    init = function() return {mode = "list", hosts = {}, host = "", rows = {}, message = "", offset = 0} end,
    update = update,
    view = view,
    back = function(state) if state.mode ~= "list" then return "back" end end,
}
