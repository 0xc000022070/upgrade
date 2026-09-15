local shout = require("lib/shout")

return {
    shout = function()
        local record = dazzle.data.get("selected")
        dazzle.data.propose("selected", record.key, shout.shout(record.value), record.revision)
    end,
}
