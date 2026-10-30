local shout = require("lib/shout")

return {
    shout = function()
        local record = upgrade.data.get("selected")
        upgrade.data.propose("selected", record.key, shout.shout(record.value), record.revision)
    end,
}
