return {
    restore = function()
        local record = upgrade.data.get("selected")
        local saved = upgrade.data.get("saved", record.key)
        assert(saved, "No snapshot saved for this record")
        upgrade.data.propose("selected", record.key, saved.value, record.revision)
    end,
}
