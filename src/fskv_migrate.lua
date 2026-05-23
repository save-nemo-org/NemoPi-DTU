local fskv_migrate = {}

--[[
    fskv schema versioning.

    A device that's been in the field for a while may have fskv keys our
    current code doesn't recognise — most commonly the pre-v2 "credentials"
    blob from before we split cert/key/broker hostname into separate keys.
    Leaving stale keys around is mostly harmless (new code just ignores
    them) but it wastes space and risks confusion if a future migration
    needs the slot for something else.

    This module keeps a `database_version` key in fskv and runs ordered
    migrations on every boot. Each migration runs at most once per device
    (gated by the stored version). The migration list is append-only.

    Add a new entry to `migrations` (with `to` = the next integer) when
    keys are renamed or removed; never edit a previously-shipped one.

    Back-compat: this module previously stored the version under the key
    `_kv_schema`. Devices flashed during that window are read with the
    old name on first boot of the new code, then promoted to the new key
    (and the legacy `_kv_schema` is deleted) so we end up with a single
    source of truth.
]]

local DB_VERSION_KEY = "database_version"
local LEGACY_VERSION_KEY = "_kv_schema"
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

local function read_current_version()
    local v = fskv.get(DB_VERSION_KEY)
    if type(v) == "number" then return v end
    -- One-shot back-compat: if the prior name carries a valid version,
    -- treat it as authoritative. We'll write it under the new name (and
    -- drop the legacy key) below so this branch is never taken twice.
    local legacy = fskv.get(LEGACY_VERSION_KEY)
    if type(legacy) == "number" then return legacy end
    return 1
end

function fskv_migrate.run()
    local version = read_current_version()

    if version >= CURRENT_VERSION then
        log.info("fskv_migrate", "schema up to date", DB_VERSION_KEY, version)
    else
        log.info("fskv_migrate", "upgrading schema", "from", version, "to", CURRENT_VERSION)
        for _, m in ipairs(migrations) do
            if m.to > version then
                log.info("fskv_migrate", "running migration", "to_version", m.to, "description", m.description)
                m.run()
                version = m.to
            end
        end
    end

    -- Always (re)write the new key so subsequent boots short-circuit, and
    -- drop the legacy key if it's still there. Idempotent.
    fskv.set(DB_VERSION_KEY, version)
    if fskv.get(LEGACY_VERSION_KEY) ~= nil then
        fskv.del(LEGACY_VERSION_KEY)
        log.info("fskv_migrate", "removed legacy", LEGACY_VERSION_KEY, "key (migrated to", DB_VERSION_KEY, ")")
    end
end

-- Exposed for tests + introspection.
function fskv_migrate.current_version() return CURRENT_VERSION end

return fskv_migrate
