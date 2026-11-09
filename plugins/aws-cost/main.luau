-- The answer is cached as lines of typed key/value fields: "=" holds the top level,
-- ".name" a nested record, "[name" one item of a list.
local US, RS, GS = "\31", "\30", "\29"
local SERVICES_ON_CARD = 3
local CHART_WIDTH, CHART_HEIGHT = 300, 72

local function fields(tag, record)
    local parts = {tag}
    for k, v in pairs(record) do
        local kind = type(v)
        if kind == "number" then
            table.insert(parts, k .. GS .. "n" .. tostring(v))
        elseif kind == "boolean" then
            table.insert(parts, k .. GS .. "b" .. (v and "1" or "0"))
        elseif kind == "string" then
            table.insert(parts, k .. GS .. "s" .. v)
        end
    end
    return table.concat(parts, US)
end

local function encode(result)
    local lines = {fields("=", result)}
    for k, v in pairs(result) do
        if type(v) == "table" then
            if #v > 0 then
                for _, item in ipairs(v) do table.insert(lines, fields("[" .. k, item)) end
            elseif next(v) ~= nil then
                table.insert(lines, fields("." .. k, v))
            end
        end
    end
    return table.concat(lines, RS)
end

local function decode(value)
    local result = nil
    local nested = {}
    for _, line in ipairs(string.split(value, RS)) do
        local parts = string.split(line, US)
        local record = {}
        for i = 2, #parts do
            local k, kind, raw = string.match(parts[i], "^([^\29]*)\29(.)(.*)$")
            if kind == "n" then
                record[k] = tonumber(raw)
            elseif kind == "b" then
                record[k] = raw == "1"
            elseif kind == "s" then
                record[k] = raw
            end
        end
        local tag = parts[1]
        if tag == "=" then
            result = record
        elseif string.sub(tag, 1, 1) == "." then
            nested[string.sub(tag, 2)] = record
        elseif string.sub(tag, 1, 1) == "[" then
            local name = string.sub(tag, 2)
            nested[name] = nested[name] or {}
            table.insert(nested[name], record)
        end
    end
    if not result or not result.fetched then return nil end
    for k, v in pairs(nested) do result[k] = v end
    for _, list in ipairs({"days", "services", "freeTier", "budgets", "notes"}) do
        result[list] = result[list] or {}
    end
    result.last = result.last or {}
    return result
end

local function load(state, again)
    if state.loaded and not again then return end
    state.loaded = true
    local saved = upgrade.data.get("costs", "month")
    state.result = saved and decode(saved.value) or nil
end

local function money(result, amount, currency)
    if amount == 0 then amount = 0 end
    return (currency or result.currency) .. " " .. string.format("%.2f", amount or 0)
end

local function quantity(n)
    if n == math.floor(n) and math.abs(n) < 1e15 then return string.format("%d", n) end
    return string.format("%.2f", n)
end

local function change(now, before)
    if not before or before == 0 then return "" end
    local percent = (now - before) / before * 100
    return string.format(" (%s%.0f%%)", percent >= 0 and "+" or "", percent)
end

local function update(state, event)
    load(state, event.type == "mount" or event.type == "refresh")
    if event.type == "result" and event.id == "billing" then
        state.busy = false
        if not event.ok then
            state.message = event.error
            return state
        end
        local encoded = encode(event.value)
        local saved = upgrade.data.get("costs", "month")
        local stored, problem = pcall(upgrade.data.put, "costs", "month", encoded, saved and saved.revision or 0)
        state.result = decode(encoded)
        state.message = stored and "" or ("Shown but not kept: " .. tostring(problem))
        return state
    end
    if event.type == "action" and event.id == "fetch" then
        state.busy = true
        state.message = ""
        return state, {ui.effect("aws", "billing", {}, "billing")}
    end
    return state
end

local function fetchButton(state)
    return ui.Button {key = "fetch", text = state.busy and "FETCHING" or "FETCH", onPress = "fetch",
        disabled = state.busy, background = "accent"}
end

local function line(key, text, color)
    return ui.Text {key = key, text = text, fontSize = 11, color = color or "muted"}
end

-- Month to date as the console home leads with it: what is owed, what made it up,
-- and how it compares with the same days of last month.
local function heading(state, key)
    local children = {}
    if state.message ~= "" then
        table.insert(children, ui.Text {key = key .. "_message", text = state.message, color = "danger"})
    end
    local r = state.result
    if not r then
        table.insert(children, line(key .. "_empty",
            "Nothing fetched yet. Choose keys or a host for this plugin in SYS · PLUGINS, then fetch."))
        return children
    end
    table.insert(children, ui.Text {key = key .. "_net", text = money(r, r.net), style = "heading"})
    local split = "CHARGES " .. money(r, r.charges) .. " · CREDITS " .. money(r, r.credits)
    if r.refunds ~= 0 then split = split .. " · REFUNDS " .. money(r, r.refunds) end
    table.insert(children, line(key .. "_split", split .. " · TAX " .. money(r, r.tax)))
    table.insert(children, line(key .. "_same", "SAME DAYS OF " .. (r.last.month or "LAST MONTH") .. " · "
        .. money(r, r.last.sameDays) .. " CHARGED" .. change(r.charges, r.last.sameDays)))
    return children
end

local function chart(r)
    local commands = {{op = "rect", x = 0, y = 0, width = CHART_WIDTH, height = CHART_HEIGHT, color = "surface"}}
    local top = 0
    for _, day in ipairs(r.days) do
        if day.amount > top then top = day.amount end
    end
    local slot = math.floor(CHART_WIDTH / math.max(#r.days, 1))
    for i, day in ipairs(r.days) do
        local height = top > 0 and math.max(day.amount / top * (CHART_HEIGHT - 4), day.amount > 0 and 1 or 0) or 0
        table.insert(commands, {op = "rect", x = (i - 1) * slot, y = CHART_HEIGHT - height,
            width = math.max(slot - 2, 1), height = height, color = "accent"})
    end
    return ui.Canvas {key = "chart", width = CHART_WIDTH, height = CHART_HEIGHT, commands = commands}
end

local function view(state)
    load(state)
    local children = {ui.Section {key = "month", title = "MONTH TO DATE", children = heading(state, "month")}}
    local r = state.result
    if r then
        local outlook = {
            ui.ListRow {key = "last", title = "LAST MONTH · " .. (r.last.month or ""), value = money(r, r.last.net),
                subtitle = "CHARGED " .. money(r, r.last.charges)},
        }
        if r.forecast then
            table.insert(outlook, ui.ListRow {key = "forecast", title = "FORECAST TO " .. r.forecastEnd,
                value = money(r, r.forecast), subtitle = "AWS's forecast from today through month end"})
        end
        table.insert(children, ui.Section {key = "outlook", title = "OUTLOOK", children = outlook})

        local credits = {}
        if r.plan then
            table.insert(credits, ui.ListRow {key = "plan", title = "FREE PLAN CREDITS LEFT",
                value = money(r, r.plan.remaining, r.plan.currency),
                subtitle = r.plan.type .. " · " .. r.plan.status .. (r.plan.expires and (" · ENDS " .. r.plan.expires) or "")})
        end
        table.insert(credits, ui.ListRow {key = "applied", title = "APPLIED THIS MONTH", value = money(r, -r.credits)})
        table.insert(credits, line("credit_note",
            "Promotional credit balances (Activate and the like) are in no AWS API; Billing, Credits in the console has them."))
        table.insert(children, ui.Section {key = "credits", title = "CREDITS", children = credits})

        local services = {}
        for i, service in ipairs(r.services) do
            table.insert(services, ui.ListRow {key = "s" .. i, title = service.name, value = money(r, service.charges),
                subtitle = service.net ~= service.charges and ("NET " .. money(r, service.net)) or nil})
        end
        if #services > 0 then
            table.insert(children, ui.Section {key = "services", title = "BY SERVICE", children = services})
        end

        if #r.days > 0 then
            local days = {}
            for i = #r.days, 1, -1 do
                local day = r.days[i]
                table.insert(days, ui.ListRow {key = "d" .. day.date, title = day.date, value = money(r, day.amount)})
            end
            table.insert(children, ui.Section {key = "daily", title = "CHARGED PER DAY", children = {
                chart(r),
                ui.Disclosure {key = "days", title = "EVERY DAY", children = days},
            }})
        end

        if #r.freeTier > 0 then
            local tier = {}
            for i, usage in ipairs(r.freeTier) do
                local share = usage.limit > 0 and string.format(" · %.0f%%", usage.used / usage.limit * 100) or ""
                table.insert(tier, ui.ListRow {key = "f" .. i, title = usage.service,
                    value = quantity(usage.used) .. " / " .. quantity(usage.limit) .. " " .. usage.unit .. share,
                    subtitle = usage.type .. " · " .. usage.description})
            end
            table.insert(children, ui.Section {key = "free_tier", title = "FREE TIER", children = tier})
        end

        if #r.budgets > 0 then
            local budgets = {}
            for i, budget in ipairs(r.budgets) do
                table.insert(budgets, ui.ListRow {key = "b" .. i, title = budget.name,
                    value = money(r, budget.actual, budget.unit) .. " / " .. string.format("%.2f", budget.limit)
                        .. change(budget.actual, budget.limit),
                    subtitle = budget.period .. " · FORECAST " .. money(r, budget.forecast, budget.unit)})
            end
            table.insert(children, ui.Section {key = "budgets", title = "BUDGETS", children = budgets})
        end

        if #r.notes > 0 then
            local notes = {}
            for i, note in ipairs(r.notes) do
                table.insert(notes, ui.ListRow {key = "n" .. i, title = note.block, subtitle = note.error})
            end
            table.insert(children, ui.Section {key = "notes", title = "NOT SHOWN", children = notes})
        end
    end
    local footer = {
        line("billed", "Each fetch makes two or more Cost Explorer requests, which AWS bills at USD 0.01 each."),
        fetchButton(state),
    }
    if r then
        table.insert(footer, 1, line("span", r.start .. " TO " .. r["end"] .. " UTC" ..
            (r.estimated and " · ESTIMATED" or "") .. " · FETCHED " .. r.fetched))
    end
    table.insert(children, ui.Footer {key = "footer", children = footer})
    return ui.Page {key = "page", title = "AWS COST", breadcrumb = "/ TOOLS", children = children}
end

local function month(state)
    load(state)
    local children = heading(state, "card")
    local r = state.result
    if r then
        if r.plan then
            table.insert(children, line("card_plan", "FREE PLAN CREDITS LEFT " .. money(r, r.plan.remaining, r.plan.currency)))
        end
        for i = 1, math.min(#r.services, SERVICES_ON_CARD) do
            local service = r.services[i]
            table.insert(children, ui.ListRow {key = "cs" .. i, title = service.name, value = money(r, service.charges)})
        end
    end
    table.insert(children, ui.Row {key = "actions", gap = 8, children = {
        ui.Column {key = "fetch_slot", flex = 1, align = "stretch", children = {fetchButton(state)}},
        ui.Column {key = "open_slot", flex = 1, align = "stretch", children = {ui.Button {key = "open", text = "OPEN", opens = "main"}}},
    }})
    return ui.Panel {key = "month", title = "AWS COST",
        children = {ui.Column {key = "card", gap = 8, align = "stretch", children = children}}}
end

return ui.app {
    init = function()
        return {loaded = false, busy = false, message = ""}
    end,
    update = update,
    view = view,
    cards = {month = month},
}
