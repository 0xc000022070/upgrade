return {
    restore = function()
        local record = dazzle.data.get("selected")
        local saved = dazzle.data.get("saved", record.key)
        assert(saved, "No snapshot saved for this record")
        dazzle.data.propose("selected", record.key, saved.value, record.revision)
    end,
}
