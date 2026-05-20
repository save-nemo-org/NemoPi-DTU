# Device Provisioning

Client implementation of the Nemo Pi Zero-Touch Provisioning (ZTP) API. Lives in
`src/provisioning.lua`; called from `src/communication.lua` during boot.

Server side: <https://github.com/save-nemo-org/device-provisioning>
Endpoint:    `https://provisioning.nemopi.com/api/`

## Why this module exists

The previous credential service (`https://issuer.nemopi.com/api/certificate`) returned a
cert + key, and the client connected to a **hardcoded** MQTT broker. The new ZTP service
splits cert issuance from broker assignment, lets the back-end change the assigned
broker per device, and lays groundwork for non-MQTT endpoints. The client must now run
a small three-step protocol per boot.

## Boot-time flow

```
                                                                                            cached?
src/communication.lua: communication.init(imei, sub_topics)
  └─ network_setup()
  └─ provisioning.get_credentials(imei, metadata)
       ├─ get_or_issue_certificate(imei) ─────────────────────────────────────── fskv hit?
       │   └─ POST /certificate           {imei}                                 200 → store
       │      response: {certificate, privateKey, thumbprint, expiry}
       │
       ├─ resolve_mqtt_endpoint(imei, cert_b64, metadata) ─────────────────────  always called
       │   ├─ POST /onboard               {deviceId, metadata}, X-Client-Cert
       │   │   response: {id, status, result, error}
       │   │     · status="succeeded" → result.endpoints[0].hostname  ← short-circuit
       │   │     · status="pending"   → poll
       │   │     · status="failed"    → abort
       │   │
       │   └─ poll: GET /onboard/{id}, X-Client-Cert, every 5s × max 12
       │       until status != "pending"
       │
       └─ returns {host, port, client_id, username, password, cert, key}
            (cert/key are PEM-wrapped from the base64 the server returned)

  └─ mqtt.create(...) + connect + sys.waitUntil("MQTT_CONNECTED", 60s)
```

## fskv keys this module owns

| Key | Type | Lifetime | Notes |
|---|---|---|---|
| `cert_b64`        | string | permanent | Device certificate, base64 (PEM headers stripped). Wrapped with `provisioning.cert_pem()` before passing to mqtt. |
| `key_b64`         | string | permanent | Device private key, base64. Wrapped with `provisioning.key_pem()`. |
| `cert_expiry`     | string | permanent | ISO-8601 expiry from `/certificate`. Informational; no auto-renewal. |
| `cert_thumbprint` | string | permanent | SHA-1 thumbprint returned by `/certificate`. Informational. |
| `mqtt_host`       | string | per-boot  | Hostname from latest succeeded `/onboard`. Re-resolved each boot. |

`cert_b64` and `key_b64` are **one-shot per IMEI**: the server flips
`allowCertificateIssuance` to `false` after the first 200 response (see
`request-certificate.ts:104` upstream). The client must therefore persist the cert
before the next boot — `get_or_issue_certificate` writes both keys to fskv as soon as
the response is parsed.

## Encoding contract

The server returns the cert and key as **base64 with PEM headers stripped** (per
`pemToBase64` / `pemToBase64PrivateKey` in the server's `helpers.ts`). The
`X-Client-Cert` header must be the same shape — the server runs `toPem(header)` to
re-wrap it.

LuatOS `mqtt.create` expects **PEM-formatted** cert and key (with `-----BEGIN
CERTIFICATE-----` headers and 64-char line wrapping). So:

- Outbound (header on `/onboard`, `/onboard/{id}`): pass the base64 as-is.
- Inbound (to `mqtt.create`): wrap with `provisioning.cert_pem(b64)` /
  `provisioning.key_pem(b64)`.

## Failure modes and what the log will show

| Source response | Log line | Cause |
|---|---|---|
| `400 {"error":"Device not found."}` | `E/user.provisioning request_certificate rejected (400) Device not found.` | IMEI not in devices table. Add it (`tools/provisioning_admin/add_device.py`). |
| `400 {"error":"Device already provisioned and not expired."}` | same shape | Cert was already issued for this IMEI; `allowCertificateIssuance` is now `false`. Either reuse the cached fskv cert or reset the row server-side (see "Reset" below). |
| `429` | `E/user.provisioning request_certificate rate limited (429); 1 req/min/IP` | The `/certificate` endpoint throttles to 1 req/min per source IP. Wait. |
| `/onboard` returns `status=failed` | `E/user.provisioning resolve_mqtt_endpoint terminal status failed error <…>` | Common causes: cert thumbprint doesn't match the row (cached cert from a previous IMEI?), `allowProvisioning=false`, no matching provisioning policy. |
| `/onboard/{id}` returns `status=pending` for 12 polls (60s) | `E/user.provisioning poll_onboarding timed out after 12 attempts` | The `create-client` queue worker hasn't completed. Check the function app's invocation logs. |

The whole credential acquisition is wrapped by `communication.init`, which logs
`E/user.communication provisioning.get_credentials failed` and returns `false` on any
of the above. The caller (`src/nemopi.lua`) then sleeps 30 min and reboots.

## Resetting a device for repeat testing

After a successful `/certificate` + `/onboard`, the IMEI is "burned" in two places:

1. **Server-side** — `allowCertificateIssuance=false`, `certificateIssuedAt/Expiry/Thumbprint`
   populated, `assignedEndpoints` populated, plus an MQTT client created at the EventGrid
   namespace.
2. **Client-side** — `cert_b64`, `key_b64`, etc. in `fskv.bin`.

For **iterative testing of the client only**, do nothing — re-running the simulator
skips `/certificate` (cached) and `/onboard` short-circuits server-side. This is the
intended steady state.

For a **clean-slate retest** (e.g. to verify the cert-issuance branch end-to-end):

1. Delete the local cache:  `rm fskv.bin`
2. Reset the row in the devices table (set `allowCertificateIssuance=true`, clear cert
   metadata, clear `assignedEndpoints`). The server README marks those fields "do not
   modify"; that guidance is for production. For dev/test it's fine.
3. Delete the MQTT client at the EventGrid namespace (`nemopi-mqtt-sandbox` for dev
   devices). If you skip this, the device will fail-back into the cached-endpoints
   branch (`onboard.ts:418`) instead of exercising the queue path.

## Operational helpers

- `tools/provisioning_admin/add_device.py` — upsert a row in the devices table with
  `allowCertificateIssuance=true allowProvisioning=true`. Idempotent. See `--help`.

## Tested against

- Simulator (V2031) → `provisioning.nemopi.com` production, IMEI `hantest1`,
  successfully onboarded to `nemopi-mqtt-sandbox.southeastasia-1.ts.eventgrid.azure.net`
  on 2026-05-20. Full flow took ~33 s (cert issuance ~2.8 s, onboard polling 5 × 5 s
  intervals, MQTT TLS handshake ~1 s).
- Hardware: not yet tested. Same `src/` runs on EC618; only difference is `mobile.imei()`
  returns the real modem IMEI instead of the simulator's `NEMOPI_TEST_IMEI` value.
