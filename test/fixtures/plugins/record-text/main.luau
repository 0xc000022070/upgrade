return {
    trim = function()
        local record = upgrade.data.get("selected")
        local value = string.gsub(record.value, "^%s*(.-)%s*$", "%1")
        value = string.gsub(value, "[ \t]+", " ")
        upgrade.data.propose("selected", record.key, value, record.revision)
    end,
    remember = function()
        local record = upgrade.data.get("selected")
        local saved = upgrade.data.get("saved", record.key)
        upgrade.data.put("saved", record.key, record.value, saved and saved.revision or 0)
    end,
}
