local shout = require("lib/shout")

return {
    shout = function()
        local record = striked.data.get("selected")
        striked.data.propose("selected", record.key, shout.shout(record.value), record.revision)
    end,
}
