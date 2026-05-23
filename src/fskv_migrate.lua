local fskv_migrate = {}

--[[
    fskv schema versioning.

    A device that's been in the field for a while may have fskv keys our
    current code doesn't recognise — most commonly the pre-v2 "credentials"
    blob from before we split cert/key/broker hostname into separate keys.
    Leaving stale keys around is mostly harmless (new code just ignores
    them) but it wastes space and risks confusion if a future migration
    needs the slot for something else.

    This module keeps a `_kv_schema` key in fskv and runs ordered
    migrations on every boot. Each migration runs at most once per device
    (gated by the stored version). The migration list is append-only.

    Add a new entry to `migrations` (with `to` = the next integer) when
    keys are renamed or removed; never edit a previously-shipped one.
]]

local CURRENT_VERSION = 2

local migrations = {
    {
        to = 2,
        description = "drop pre-v2 'credentials' blob (superseded by cert_b64/key_b64/mqtt_host)",
        run = function()
            if fskv.get("credentials") ~= nil then
                fskv.del("credentials")
                log.warn("fskv_migrate", "dropped legacy 'credentials' key")
            end
        end,
    },
}

function fskv_migrate.run()
    local stored = fskv.get("_kv_schema")
    local version = (type(stored) == "number") and stored or 1

    if version >= CURRENT_VERSION then
        log.info("fskv_migrate", "schema up to date", "version", version)
        return
    end

    log.info("fskv_migrate", "upgrading schema", "from", version, "to", CURRENT_VERSION)
    for _, m in ipairs(migrations) do
        if m.to > version then
            log.info("fskv_migrate", "running migration", "to_version", m.to, "description", m.description)
            m.run()
            fskv.set("_kv_schema", m.to)
            version = m.to
        end
    end
end

-- Exposed for tests + introspection.
function fskv_migrate.current_version() return CURRENT_VERSION end

return fskv_migrate
