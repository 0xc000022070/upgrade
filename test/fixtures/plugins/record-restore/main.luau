return {
    restore = function()
        local record = striked.data.get("selected")
        local saved = striked.data.get("saved", record.key)
        assert(saved, "No snapshot saved for this record")
        striked.data.propose("selected", record.key, saved.value, record.revision)
    end,
}
