local function text(key, value, color)
    return ui.Text {key = key, text = value, color = color or "muted"}
end

local function dateLabel(value)
    if #value < 16 then return value end
    return string.sub(value, 1, 10) .. " · " .. string.sub(value, 12, 16)
end

local function button(key, title, event, args, primary)
    return ui.Button {key = key, text = title, onPress = event, args = args, background = primary and "accent" or nil}
end

local function remember(key, value)
    local saved = striked.data.get("preferences", key)
    striked.data.put("preferences", key, value, saved and saved.revision or 0)
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

local function feature(state, name)
    for _, item in ipairs(state.hostInfo.features or {}) do
        if item == name then return true end
    end
    return false
end

local function update(state, event)
    if event.type == "mount" then
        local saved = striked.data.get("preferences", "host")
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
            state.more = event.value.more or false
            state.offset = event.value.offset or 0
            if event.value.paused ~= nil then state.paused = event.value.paused end
            state.message = event.value.error or ""
        elseif event.id == "edit" then
            state.edit = event.value
            state.mode = "edit"
            local edit = state.edit
            edit.when = edit["repeat"] == "once" and edit.date .. "T" .. edit.time or edit.time
            edit.timeout = tostring(edit.timeout)
        elseif event.id == "workspaces" then
            state.workspaces = event.value.items
            if state.edit.directory == "" and #state.workspaces == 1 then state.edit.directory = state.workspaces[1] end
        elseif event.id == "output" then
            state.output = event.value
            state.mode = "output"
        elseif event.id == "saved" then
            remember("workspace_" .. state.host, state.edit.directory)
            state.mode = state.edit["repeat"] == "now" and "history" or "list"
            state.edit = nil
            state.rows = {}
            return refresh(state)
        elseif event.id == "ran" then
            state.mode = "history"
            return refresh(state)
        elseif event.id == "canceled" then
            return request(state, "output", {id = state.runId}, "output")
        else
            return refresh(state)
        end
        return state
    end
    if event.type ~= "action" then return state end
    local values = event.fields or {}
    local args = event.args or {}
    if state.mode == "edit" then
        for key, value in pairs(values) do state.edit[key] = value end
    end
    if event.id == "choose_host" then
        state.host = event.value
        state.hostInfo = nil
        state.edit = nil
        state.workspaces = {}
        state.rows = {}
        state.mode = "history"
        remember("host", state.host)
        return request(state, "inspect", {}, "inspect")
    elseif event.id == "reload_hosts" then
        return state, {ui.effect("hosts", "list", {}, "hosts")}
    elseif event.id == "setup" or event.id == "inspect" then
        return request(state, event.id, {}, event.id)
    elseif event.id == "new" then
        state.mode = "edit"
        state.message = ""
        if not state.edit then
            local saved = striked.data.get("preferences", "workspace_" .. state.host)
            state.edit = {id = event.token, revision = 0, title = "", directory = saved and saved.value or "", prompt = "",
                agent = state.hostInfo.agents[1] or "codex", model = "", ["repeat"] = feature(state, "queue") and "now" or "once",
                when = "", timezone = state.hostInfo.timezone or "UTC", timeout = "14400"}
        end
    elseif event.id == "edit" then
        return request(state, "get", {id = args.id}, "edit")
    elseif event.id == "workspaces" then
        return state, {ui.effect("hosts", "workspaces", {host = state.host}, "workspaces")}
    elseif event.id == "workspace" then
        state.edit.directory = event.value
    elseif event.id == "frequency" then
        state.edit["repeat"] = event.value
        state.edit.when = event.value == "daily" and "09:00" or ""
    elseif event.id == "save" then
        local edit = state.edit
        if string.match(edit.prompt, "^%s*$") then state.message = "Describe what the agent should do."; return state end
        if string.match(edit.directory, "^%s*$") then state.message = "Choose a workspace on this host."; return state end
        if edit["repeat"] == "once" and edit.when == "" then state.message = "Choose a start date and time."; return state end
        local title = edit.title
        if string.match(title, "^%s*$") then
            local ending = utf8.offset(edit.prompt, 81) or (#edit.prompt + 1)
            while ending > 121 do ending = utf8.offset(edit.prompt, -1, ending) end
            title = string.gsub(string.sub(edit.prompt, 1, ending - 1), "\n", " ")
        end
        local repeating = edit["repeat"]
        local job = {id = edit.id, revision = edit.revision, title = title, directory = edit.directory,
            agent = edit.agent, model = edit.model, prompt = edit.prompt, ["repeat"] = repeating,
            date = repeating == "once" and string.sub(edit.when, 1, 10) or "",
            time = repeating == "now" and "00:00" or (repeating == "once" and string.sub(edit.when, 12, 16) or edit.when),
            timezone = edit.timezone, timeout = tonumber(edit.timeout) or 0}
        return request(state, "save", {schedule = job}, "saved")
    elseif event.id == "tab" or event.id == "history" then
        state.mode = event.value or "history"
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
    elseif event.id == "stop" then
        return request(state, "cancel", {id = state.runId}, "canceled")
    elseif event.id == "pause_scope" or event.id == "resume_scope" then
        return request(state, event.id, {}, "changed")
    elseif event.id == "back" or event.id == "discard" then
        if event.id == "discard" then state.edit = nil end
        state.mode = "history"
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
    local workspaceOptions = {}
    local included = false
    for _, directory in ipairs(state.workspaces) do
        table.insert(workspaceOptions, {value = directory, label = directory})
        if directory == edit.directory then included = true end
    end
    if edit.directory ~= "" and not included then table.insert(workspaceOptions, {value = edit.directory, label = edit.directory}) end
    local timing = {{value = "once", label = "Later"}, {value = "daily", label = "Daily"}}
    if feature(state, "queue") then table.insert(timing, 1, {value = "now", label = "Now"}) end
    local children = {
        ui.Input {key = "prompt", label = "What should the agent do?", hint = "Describe the outcome and how to verify it", value = edit.prompt, lines = 4},
        #workspaceOptions > 0 and ui.Select {key = "workspace", label = "Workspace", value = edit.directory, options = workspaceOptions, onChange = "workspace"}
            or ui.Panel {key = "workspace_empty", children = {
                ui.ListRow {key = "find_workspaces", title = "Choose workspace", subtitle = "Find a project on this host", node = true, onPress = "workspaces"},
            }},
        ui.Choice {key = "repeat", label = "Start", value = edit["repeat"], options = timing, onChange = "frequency"},
    }
    if edit["repeat"] ~= "now" then
        table.insert(children, ui.DateTime {key = "when", label = edit["repeat"] == "daily" and "Every day at" or "Start date and time",
            value = edit.when, mode = edit["repeat"] == "daily" and "time" or "datetime"})
        table.insert(children, text("zone_note", "Time on host · " .. edit.timezone))
    else
        table.insert(children, text("queue_note", "Your host keeps working when you close Striked."))
    end
    table.insert(children, ui.Disclosure {key = "options", title = "Agent and options", subtitle = string.upper(edit.agent) .. " · up to " .. tostring((tonumber(edit.timeout) or 0) / 3600) .. "h", gap = 12, children = {
        ui.Select {key = "agent", label = "Agent", value = edit.agent, options = agents},
        ui.Input {key = "model", label = "Model", hint = "Host default", value = edit.model},
        ui.Select {key = "timeout", label = "Time limit", value = edit.timeout, options = {
            {value = "900", label = "15 minutes"}, {value = "3600", label = "1 hour"},
            {value = "7200", label = "2 hours"}, {value = "14400", label = "4 hours"},
        }},
        ui.Input {key = "title", label = "Task name", hint = "Uses your instruction if empty", value = edit.title},
        ui.Input {key = "directory", label = "Custom workspace path", hint = "/home/user/project", value = edit.directory},
        button("refresh_workspaces", "Find other workspaces", "workspaces"),
        ui.Input {key = "timezone", label = "Timezone", value = edit.timezone},
        text("permission_note", "Uses the agent's existing host authentication and permissions."),
        text("capacity_note", "Two execution slots for this plugin. Tasks wait for a slot and run one at a time per workspace."),
        button("discard", "Discard draft", "discard"),
    }})
    table.insert(children, ui.Footer {key = "submit", children = {
        button("save", edit.revision > 0 and "Save changes" or (edit["repeat"] == "now" and "Start task" or "Schedule task"), "save", nil, true),
    }})
    return children
end

local function chunks(key, value)
    local result = {}
    local start = 1
    while start <= #value do
        local ending = utf8.offset(value, 2049, start) or (#value + 1)
        table.insert(result, text(key .. tostring(#result + 1), string.sub(value, start, ending - 1), "text"))
        start = ending
    end
    return result
end

local function view(state)
    local children = {}
    local title = "Agent tasks"
    local ready = state.hostInfo and state.hostInfo.installed and state.hostInfo.timer_active ~= false and state.hostInfo.runner_current ~= false
    if ready and state.mode == "edit" then
        title = state.edit.revision > 0 and "Edit task" or "New task"
        children = editor(state)
    elseif ready and state.mode == "output" then
        title = "Task result"
        local output = state.output
        local warnings = output.warnings or {}
        table.insert(children, ui.StatusTag {key = "status", label = #warnings > 0 and output.status .. " · warnings" or output.status,
            color = (#warnings > 0 or output.status == "failed") and "danger" or "accent"})
        table.insert(children, text("task_name", output.title or "Agent run", "text"))
        table.insert(children, text("task_workspace", output.directory or ""))
        for i, warning in ipairs(warnings) do table.insert(children, text("warning_" .. i, warning, "danger")) end
        local summary = output.summary or ""
        if summary == "" then summary = output.status == "queued" and "Waiting for a free slot or for this workspace's current task to finish." or "No final response yet. Refresh to check progress; diagnostics contain the raw output." end
        for _, node in ipairs(chunks("answer_", summary)) do table.insert(children, node) end
        table.insert(children, ui.Disclosure {key = "diagnostics", title = "Diagnostics", subtitle = "Raw agent output", children = chunks("raw_", output.text)})
        if output.status == "running" or output.status == "queued" then
            if feature(state, "cancel") then table.insert(children, button("stop", output.status == "queued" and "Cancel queued task" or "Stop task", "stop")) end
        elseif output.schedule then
            table.insert(children, button("retry", "Run again", "run", {id = output.schedule}))
        end
        table.insert(children, ui.Footer {key = "output_actions", children = {button("refresh", "Refresh result", "refresh", nil, true)}})
    else
        local hosts = {}
        for _, host in ipairs(state.hosts) do table.insert(hosts, {value = host.id, label = host.name}) end
        if #hosts == 0 then
            table.insert(children, text("no_hosts", "Add and verify a machine in Hosts. Tasks run there while your phone is offline."))
            table.insert(children, button("reload_hosts", "Refresh hosts", "reload_hosts"))
        else
            table.insert(children, ui.Select {key = "host", label = "Run on", value = state.host, options = hosts, onChange = "choose_host"})
            if state.host ~= "" and not state.hostInfo then table.insert(children, button("reconnect", "Reconnect", "inspect", nil, true)) end
        end
        if state.hostInfo and not ready then
            local info = state.hostInfo
            table.insert(children, text("setup_reason", info.supported and (info.installed and "Update the background runner to use this host's current engine. Tasks and history stay intact." or "Enable background tasks once. The host keeps working when you close Striked.") or info.reason))
            table.insert(children, button("setup", info.supported and (info.installed and "Update background runner" or "Enable background tasks") or "Check host again", info.supported and "setup" or "inspect", nil, true))
        elseif ready then
            table.insert(children, ui.Choice {key = "tab", label = "Tasks", value = state.mode, onChange = "tab", options = {
                {value = "history", label = "Activity"}, {value = "list", label = "Schedules"},
            }})
            if state.paused then table.insert(children, button("resume_all", "Queue paused · resume", "resume_scope", nil, true)) end
            local visible = 0
            for _, row in ipairs(state.rows) do
                local key = "r_" .. row.id
                if state.mode == "history" then
                    visible += 1
                    table.insert(children, ui.Panel {key = key, children = {
                        ui.StatusTag {key = key .. "status", label = row.status, color = row.status == "failed" and "danger" or "accent"},
                        ui.ListRow {key = key .. "open", title = row.title, subtitle = row.directory, caption = dateLabel(row.started_label or "") .. " UTC",
                            node = true, onPress = "output", args = {id = row.id}},
                    }})
                elseif row["repeat"] ~= "now" and row.next_label ~= "Finished" then
                    visible += 1
                    table.insert(children, ui.Panel {key = key, title = row.title, children = {
                        text(key .. "time", (row.enabled and "Next · " or "Paused · ") .. dateLabel(row.next_label)),
                        text(key .. "zone", row.timezone or state.hostInfo.timezone or "UTC"),
                        text(key .. "agent", string.upper(row.agent) .. " · " .. row["repeat"]),
                        ui.Disclosure {key = key .. "actions", title = "Manage schedule", gap = 8, children = {
                            button(key .. "edit", "Edit", "edit", {id = row.id}),
                            button(key .. "pause", row.enabled and "Pause" or "Resume", row.enabled and "pause" or "resume", {id = row.id}),
                            button(key .. "run", "Run now", "run", {id = row.id}),
                        }},
                    }})
                end
            end
            if visible == 0 then table.insert(children, ui.Panel {key = "empty", title = state.mode == "history" and "Leave the work running" or "Nothing scheduled", children = {
                text("empty_body", state.mode == "history" and "Give an agent a task and choose its workspace. You can close the app after the host accepts it." or "Choose Later or Daily when creating a task."),
            }}) end
            if state.offset > 0 then table.insert(children, button("previous_page", "Previous", "previous_page")) end
            if state.more then table.insert(children, button("next_page", "Next", "next_page")) end
            table.insert(children, button("refresh", "Refresh", "refresh"))
            table.insert(children, ui.Disclosure {key = "host_controls", title = "Host controls", children = {
                text("pause_note", "Pause prevents queued and future tasks from starting. Running tasks continue."),
                button("pause_all", state.paused and "Resume queue" or "Pause queue", state.paused and "resume_scope" or "pause_scope"),
                button("repair_runner", "Update host runner", "setup"),
            }})
            table.insert(children, ui.Footer {key = "create", children = {
                ui.Button {key = "new", text = state.edit and "Continue draft" or "New task", onPress = "new",
                    enabled = #state.hostInfo.agents > 0, background = "accent"},
            }})
            if #state.hostInfo.agents == 0 then table.insert(children, text("no_agents", "Install and authenticate Codex or Claude on this host.")) end
        end
    end
    if state.message ~= "" then table.insert(children, 1, text("error", state.message, "danger")) end
    return ui.Page {key = "page_" .. state.mode, title = string.upper(title), breadcrumb = ready and (state.mode == "edit" or state.mode == "output") and "/ BACK TO TASKS" or "/ TOOLS", children = children}
end

return ui.app {
    init = function() return {mode = "history", hosts = {}, host = "", rows = {}, workspaces = {}, message = "", offset = 0} end,
    update = update,
    view = view,
    back = function(state) if state.mode == "edit" or state.mode == "output" then return "back" end end,
}
