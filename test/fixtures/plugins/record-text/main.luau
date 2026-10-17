return {
    trim = function()
        local record = striked.data.get("selected")
        local value = string.gsub(record.value, "^%s*(.-)%s*$", "%1")
        value = string.gsub(value, "[ \t]+", " ")
        striked.data.propose("selected", record.key, value, record.revision)
    end,
    remember = function()
        local record = striked.data.get("selected")
        local saved = striked.data.get("saved", record.key)
        striked.data.put("saved", record.key, record.value, saved and saved.revision or 0)
    end,
}
