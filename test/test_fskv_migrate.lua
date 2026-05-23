--[[
    Unit tests for src/fskv_migrate.lua. Verifies the schema-versioning
    logic that gates legacy-key cleanup on field-unit OTA upgrades.
]]

local fskv_migrate = require("fskv_migrate")
local A = require("assertions")

local tests = {}

-- A pre-v2 field device has a 'credentials' blob and no _kv_schema marker.
-- Migration must drop the legacy key and stamp _kv_schema=2.
function tests.test_migrate_drops_legacy_credentials_blob()
    fskv.preload({
        credentials = {host = "legacy.example", port = 8883, cert = "STALE"},
        config = {read_interval_ms = 1800000},
    })

    fskv_migrate.run()

    local snap = fskv.snapshot()
    A.assert_nil(snap.credentials, "legacy 'credentials' key should be dropped")
    A.assert_eq(snap._kv_schema, 2, "schema bumped to 2")
    -- Untargeted keys are left alone.
    A.assert_truthy(snap.config, "non-legacy key preserved")
end

-- A device already on the current schema must be a complete no-op —
-- never re-run migrations or trample existing data.
function tests.test_migrate_noop_when_schema_current()
    fskv.preload({
        _kv_schema = 2,
        -- A 'credentials' key here would be unexpected on a v2 device but
        -- the migration must not touch it again — the to-2 step has
        -- already been recorded as run.
        credentials = "should-stay",
        cert_b64 = "ACTIVE",
    })

    fskv_migrate.run()

    local snap = fskv.snapshot()
    A.assert_eq(snap.credentials, "should-stay", "must not re-run completed migration")
    A.assert_eq(snap.cert_b64, "ACTIVE", "active keys preserved")
    A.assert_eq(snap._kv_schema, 2, "schema unchanged")
end

-- A brand-new device with no fskv keys must still get _kv_schema stamped
-- so subsequent boots take the up-to-date branch.
function tests.test_migrate_fresh_device_stamps_version()
    -- empty fskv
    fskv_migrate.run()

    local snap = fskv.snapshot()
    A.assert_eq(snap._kv_schema, 2, "fresh device gets schema=2")
end

return tests
