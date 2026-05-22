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

-- #4: invalidate() drops the cached credentials, so the next get_credentials
-- re-runs the full /certificate + /onboard flow. communication.lua calls
-- invalidate() on MQTT connect timeout (broker rejected the cert), which is
-- how the system recovers from credential-related failure without the
-- network being at fault.
function tests.test_invalidate_clears_cache_and_next_call_reprovisions()
    fskv.preload({
        cert_b64 = "OLD_CERT",
        key_b64 = "OLD_KEY",
        cert_expiry = "2030-01-01T00:00:00Z",
        cert_thumbprint = "OLDFP",
        mqtt_host = "old.broker.example.net",
    })

    provisioning.invalidate()

    local snap = fskv.snapshot()
    A.assert_nil(snap.cert_b64, "cert_b64 should be cleared")
    A.assert_nil(snap.key_b64, "key_b64 should be cleared")
    A.assert_nil(snap.cert_expiry, "cert_expiry should be cleared")
    A.assert_nil(snap.cert_thumbprint, "cert_thumbprint should be cleared")
    A.assert_nil(snap.mqtt_host, "mqtt_host should be cleared")

    -- After invalidation, get_credentials must hit /certificate again.
    http.queue({code = 200, body = json.encode({
        certificate = "FRESH_CERT",
        privateKey = "FRESH_KEY",
        thumbprint = "NEWFP",
        expiry = "2031-01-01T00:00:00Z",
    })})
    http.queue({code = 200, body = json.encode({
        id = "op-3",
        status = "succeeded",
        result = {endpoints = {{kind = "mqtt", hostname = "new.broker.example.net"}}},
    })})

    local creds = provisioning.get_credentials("test-imei", {})
    A.assert_truthy(creds, "expected fresh credentials after invalidate")
    A.assert_contains(creds.cert, "FRESH_CERT", "fresh cert used, not old one")
    A.assert_eq(creds.host, "new.broker.example.net", "fresh broker hostname")

    local calls = http.calls()
    A.assert_eq(#calls, 2, "expected 2 calls after invalidate (cert + onboard)")
    A.assert_contains(calls[1].url, "/certificate", "first call /certificate")
    A.assert_contains(calls[2].url, "/onboard", "second call /onboard")
end

return tests
