--[[
    Unit tests for src/fskv_migrate.lua. Verifies the schema-versioning
    logic that gates legacy-key cleanup on field-unit OTA upgrades, plus
    the one-shot back-compat shim that moves devices from the older
    `_kv_schema` key to `database_version`.
]]

local fskv_migrate = require("fskv_migrate")
local A = require("assertions")

local tests = {}

-- A pre-v2 field device has a 'credentials' blob and no version marker.
-- Migration must drop the legacy key and stamp database_version=2.
function tests.test_migrate_drops_legacy_credentials_blob()
    fskv.preload({
        credentials = {host = "legacy.example", port = 8883, cert = "STALE"},
        config = {read_interval_ms = 1800000},
    })

    fskv_migrate.run()

    local snap = fskv.snapshot()
    A.assert_nil(snap.credentials, "legacy 'credentials' key should be dropped")
    A.assert_eq(snap.database_version, 2, "database_version stamped to 2")
    -- Untargeted keys are left alone.
    A.assert_truthy(snap.config, "non-legacy key preserved")
end

-- A device already on the current schema must be a no-op for migrations,
-- but the run still ensures the marker key exists (idempotent write).
function tests.test_migrate_noop_when_schema_current()
    fskv.preload({
        database_version = 2,
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
    A.assert_eq(snap.database_version, 2, "schema unchanged")
end

-- A brand-new device with no fskv keys must still get database_version
-- stamped so subsequent boots take the up-to-date branch.
function tests.test_migrate_fresh_device_stamps_version()
    -- empty fskv
    fskv_migrate.run()

    local snap = fskv.snapshot()
    A.assert_eq(snap.database_version, 2, "fresh device gets database_version=2")
end

-- Devices we flashed during the short `_kv_schema` window should pick up
-- the legacy key's value (so we don't re-run completed migrations) and
-- get promoted to the new `database_version` name. Legacy key deleted.
function tests.test_migrate_imports_legacy_kv_schema_key()
    fskv.preload({
        _kv_schema = 2,            -- legacy version marker — value is up to date
        credentials = "should-stay",  -- if we re-ran the v2 migration this would be dropped
    })

    fskv_migrate.run()

    local snap = fskv.snapshot()
    A.assert_eq(snap.database_version, 2, "version copied to new key")
    A.assert_nil(snap._kv_schema, "legacy key cleaned up")
    A.assert_eq(snap.credentials, "should-stay", "to-2 migration NOT re-run")
end

return tests
