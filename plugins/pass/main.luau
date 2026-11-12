local SHOWN = 200

local function load(state)
    if state.loaded then return end
    state.loaded = true
    local saved = upgrade.data.get("entries", "list")
    state.entries = (saved and saved.value ~= "") and string.split(saved.value, "\n") or {}
end

local function matches(search, entry)
    local hay = string.lower(entry)
    for word in string.gmatch(string.lower(search), "%S+") do
        if not string.find(hay, word, 1, true) then return false end
    end
    return true
end

local function list(state)
    state.busy = true
    return state, {ui.effect("pass", "list", {}, "list")}
end

local function update(state, event)
    load(state)
    if event.type == "mount" then return list(state) end
    if event.type == "result" and event.id == "list" then
        state.busy = false
        state.failed = not event.ok
        if not event.ok then
            state.message = event.error
            return state
        end
        state.entries = event.value.entries
        state.message = ""
        local encoded = table.concat(state.entries, "\n")
        local saved = upgrade.data.get("entries", "list")
        local stored, problem = pcall(upgrade.data.put, "entries", "list", encoded, saved and saved.revision or 0)
        if not stored then
            state.failed = true
            state.message = "Shown but not kept: " .. tostring(problem)
        end
        return state
    end
    if event.type == "result" and event.id == "copy" then
        state.failed = not event.ok
        state.message = event.ok and ("COPIED " .. state.copying .. event.value.entry .. " · CLEARS IN " .. event.value.clears .. "S")
            or event.error
        return state
    end
    if event.type == "action" and event.id == "search" then
        state.search = event.value or ""
        return state
    end
    if event.type == "action" and event.id == "otp" then
        state.otp = event.value == true
        return state
    end
    if event.type == "action" and event.id == "refresh" then
        state.message = ""
        return list(state)
    end
    if event.type == "action" and event.id == "copy" then
        state.failed = false
        state.copying = state.otp and "THE CODE FOR " or ""
        state.message = "COPYING " .. state.copying .. event.args.entry
        return state, {ui.effect("pass", state.otp and "otp" or "copy", {entry = event.args.entry}, "copy")}
    end
    return state
end

local function view(state)
    load(state)
    local children = {}
    if state.message ~= "" then
        table.insert(children, ui.Text {key = "message", text = state.message,
            color = state.failed and "danger" or "accent"})
    end
    table.insert(children, ui.Input {key = "search", label = "Search", hint = "Words in the entry's path",
        value = state.search, onChange = "search", live = true})
    table.insert(children, ui.Toggle {key = "otp", label = "Copy the one-time code (needs pass-otp on the host)",
        value = state.otp, onChange = "otp"})
    local rows, hidden = {}, 0
    for _, entry in ipairs(state.entries) do
        if matches(state.search, entry) then
            if #rows < SHOWN then
                table.insert(rows, ui.ListRow {key = "e" .. #rows, title = entry, onPress = "copy", args = {entry = entry}})
            else
                hidden += 1
            end
        end
    end
    if #state.entries == 0 then
        table.insert(rows, ui.Text {key = "empty", color = "muted", text = state.busy and "Listing the store…"
            or "No entries. Choose the host for this plugin in SYS · PLUGINS, then refresh."})
    elseif hidden > 0 then
        table.insert(rows, ui.Text {key = "more", color = "muted", text = "+" .. hidden .. " more · search to narrow"})
    end
    table.insert(children, ui.Section {key = "entries", title = "ENTRIES · " .. #state.entries, children = rows})
    table.insert(children, ui.Footer {key = "footer", children = {
        ui.Text {key = "note", fontSize = 11, color = "muted",
            text = "A tap copies the entry's first line, or its pass-otp code, and clears the clipboard after 45 seconds."},
        ui.Button {key = "refresh", text = state.busy and "LISTING" or "REFRESH", onPress = "refresh",
            disabled = state.busy, background = "accent"},
    }})
    return ui.Page {key = "page", title = "PASS", breadcrumb = "/ TOOLS", children = children}
end

return ui.app {
    init = function()
        return {loaded = false, busy = false, message = "", failed = false, search = "", entries = {}, otp = false, copying = ""}
    end,
    update = update,
    view = view,
}
