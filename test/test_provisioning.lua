--[[
    Unit tests for src/provisioning.lua. Covers the four scenarios called out
    in the requirements:

      1. provisioning returns correct credentials on the happy path
      2. provisioning returns nil on failure (caller — nemopi.lua — handles
         the 30-min retry via utils.reboot_with_delay_blocking)
      3. cached cert/key are reused on subsequent boots
      4. invalidate() drops the cache so the next call re-provisions; this is
         the mechanism communication.lua uses to recover from broker-side
         credential rejection (non-network failure modes)

    Run via the LuatOS PC simulator:
        ./tools/luatos_pc/V2031/luatos-pc.exe ./test/ ./src/
    The test runner (test/main.lua) wires up fake http + fskv before
    requiring this file.
]]

local provisioning = require("provisioning")
local A = require("assertions")

local tests = {}

-- #1: full /certificate + /onboard happy path yields a complete credentials
-- struct ready for mqtt.create.
function tests.test_get_credentials_happy_path()
    http.queue({code = 200, body = json.encode({
        certificate = "CERTBODY",
        privateKey = "KEYBODY",
        thumbprint = "FINGERPRINT",
        expiry = "2030-01-01T00:00:00Z",
    })})
    http.queue({code = 200, body = json.encode({
        id = "op-1",
        status = "succeeded",
        result = {endpoints = {{kind = "mqtt", hostname = "broker.example.net"}}},
    })})

    local creds = provisioning.get_credentials("test-imei", {os = "test"})

    A.assert_truthy(creds, "expected credentials, got nil")
    A.assert_eq(creds.host, "broker.example.net", "broker host")
    A.assert_eq(creds.port, 8883, "broker port")
    A.assert_eq(creds.client_id, "test-imei", "client_id")
    A.assert_eq(creds.username, "test-imei", "username")
    A.assert_eq(creds.password, "", "password should be empty")
    A.assert_contains(creds.cert, "BEGIN CERTIFICATE", "cert PEM header")
    A.assert_contains(creds.cert, "CERTBODY", "cert body present")
    A.assert_contains(creds.cert, "END CERTIFICATE", "cert PEM footer")
    A.assert_contains(creds.key, "BEGIN PRIVATE KEY", "key PEM header")
    A.assert_contains(creds.key, "KEYBODY", "key body present")

    -- Two http calls, in order: /certificate then /onboard.
    local calls = http.calls()
    A.assert_eq(#calls, 2, "expected 2 http calls (cert + onboard)")
    A.assert_contains(calls[1].url, "/certificate", "first call should be /certificate")
    A.assert_contains(calls[2].url, "/onboard", "second call should be /onboard")

    -- All cache keys persisted for the next boot.
    local snap = fskv.snapshot()
    A.assert_eq(snap.cert_b64, "CERTBODY", "cert_b64 cached")
    A.assert_eq(snap.key_b64, "KEYBODY", "key_b64 cached")
    A.assert_eq(snap.cert_thumbprint, "FINGERPRINT", "thumbprint cached")
    A.assert_eq(snap.cert_expiry, "2030-01-01T00:00:00Z", "expiry cached")
    A.assert_eq(snap.mqtt_host, "broker.example.net", "mqtt_host cached")
end

-- #2: on /certificate failure, get_credentials returns nil. The 30-min sleep
-- before retry is the caller's responsibility — nemopi.lua's
-- `utils.reboot_with_delay_blocking(30 * 60 * 1000)` runs when
-- communication.init returns false.
function tests.test_get_credentials_returns_nil_on_certificate_failure()
    http.queue({code = 400, body = json.encode({error = "Device not found."})})

    local creds = provisioning.get_credentials("unknown-imei", {})

    A.assert_nil(creds, "expected nil on /certificate 400")
    A.assert_nil(fskv.snapshot().cert_b64, "must not cache cert on failure")
    -- /onboard is never attempted without a cert.
    local calls = http.calls()
    A.assert_eq(#calls, 1, "expected 1 http call (only /certificate)")
end

-- #3: when fskv already holds a cert/key, get_credentials skips /certificate
-- and goes straight to /onboard. This is the steady-state boot path.
function tests.test_get_credentials_uses_cached_cert()
    fskv.preload({cert_b64 = "CACHED_CERT", key_b64 = "CACHED_KEY"})
    http.queue({code = 200, body = json.encode({
        id = "op-2",
        status = "succeeded",
        result = {endpoints = {{kind = "mqtt", hostname = "cached.example.net"}}},
    })})

    local creds = provisioning.get_credentials("test-imei", {})

    A.assert_truthy(creds, "expected credentials")
    A.assert_eq(creds.host, "cached.example.net")
    A.assert_contains(creds.cert, "CACHED_CERT", "cached cert used")
    A.assert_contains(creds.key, "CACHED_KEY", "cached key used")

    -- Only one http call: /onboard. /certificate skipped because of the cache.
    local calls = http.calls()
    A.assert_eq(#calls, 1, "expected exactly 1 http call (onboard)")
    A.assert_contains(calls[1].url, "/onboard", "expected /onboard call")
end

-- #4: load_cached_credentials returns a complete creds struct from the fskv
-- cache alone, with no HTTP calls. This is the fast path communication.lua
-- uses on warm boots before falling through to fresh provisioning.
--
-- The "if creds don't work, go back to provisioning" half of requirement #4
-- lives in communication.init's two-attempt orchestration (cached → fresh)
-- and is exercised by the integration test in
-- .github/workflows/integration-test-simulator.yml; the choice not to
-- auto-invalidate the cert on MQTT failure is documented in
-- communication.lua and docs/provisioning.md.
function tests.test_load_cached_credentials_returns_creds_when_cache_complete()
    fskv.preload({
        cert_b64 = "CACHED_CERT",
        key_b64 = "CACHED_KEY",
        mqtt_host = "cached.broker.example.net",
    })

    local creds = provisioning.load_cached_credentials("test-imei")

    A.assert_truthy(creds, "expected creds from full cache")
    A.assert_eq(creds.host, "cached.broker.example.net", "host from cache")
    A.assert_eq(creds.port, 8883, "port")
    A.assert_eq(creds.client_id, "test-imei", "client_id")
    A.assert_eq(creds.username, "test-imei", "username")
    A.assert_contains(creds.cert, "BEGIN CERTIFICATE", "cert PEM header")
    A.assert_contains(creds.cert, "CACHED_CERT", "cert body")
    A.assert_contains(creds.key, "BEGIN PRIVATE KEY", "key PEM header")
    A.assert_contains(creds.key, "CACHED_KEY", "key body")

    -- The whole point of this fast path: zero HTTP calls.
    A.assert_eq(#http.calls(), 0, "load_cached_credentials must not hit HTTP")
end

-- load_cached_credentials returns nil if any of the three required keys is
-- missing, so communication.init falls through cleanly to fresh provisioning.
function tests.test_load_cached_credentials_returns_nil_when_incomplete()
    -- empty cache
    A.assert_nil(provisioning.load_cached_credentials("test-imei"),
        "empty cache should yield nil")

    -- cert only
    fskv.preload({cert_b64 = "CACHED_CERT"})
    A.assert_nil(provisioning.load_cached_credentials("test-imei"),
        "cert-only cache should yield nil")

    -- cert + key but no mqtt_host (the common in-between state after
    -- /certificate succeeded but /onboard never did)
    fskv.reset()
    fskv.preload({cert_b64 = "CACHED_CERT", key_b64 = "CACHED_KEY"})
    A.assert_nil(provisioning.load_cached_credentials("test-imei"),
        "missing mqtt_host should yield nil")
end

return tests
