"""
Upsert a device row in the Nemo Pi provisioning service's Azure Table Storage,
flipping it to a state where the device is allowed to call /certificate and /onboard.

This is the operational counterpart to `src/provisioning.lua` — what the client expects
the server-side row to look like before it can complete onboarding.

## Setup (once per shell session)

Populate the connection-string env var via `az` (PowerShell):

    $env:AZURE_STORAGE_CONNECTION_STRING = az storage account show-connection-string `
        --name nemopideviceonboarding --query connectionString -o tsv

Bash equivalent:

    export AZURE_STORAGE_CONNECTION_STRING="$(az storage account show-connection-string \
        --name nemopideviceonboarding --query connectionString -o tsv)"

You need `az login` first; signed-in user needs `Microsoft.Storage/storageAccounts/`
`listKeys/action` to read the connection string (included in Contributor on the
storage account / RG / subscription).

## Usage

    .venv\\Scripts\\python.exe tools\\provisioning_admin\\add_device.py --imei <imei>
    .venv\\Scripts\\python.exe tools\\provisioning_admin\\add_device.py --imei hantest1 --developer
    .venv\\Scripts\\python.exe tools\\provisioning_admin\\add_device.py --imei <imei> --reset

## What "creating" the device means

    PartitionKey               = "nemopi"
    RowKey                     = <imei>
    allowCertificateIssuance   = true
    allowProvisioning          = true
    isDeveloperDevice          = <--developer flag, default false>
    manufacturer, model        = <--manufacturer, --model; default values below>
    provisioningMetadata       = "{}"

The script is an upsert (merge): if the row already exists, only the listed fields are
overwritten — other fields the server may have set (certificateIssuedAt, etc.) are
preserved unless --reset is passed.

With --reset, the script additionally clears server-set fields so the IMEI can run
the full /certificate flow again. The server README marks those fields "do not modify"
in production; --reset is intended for dev/test cycles only.
"""

from __future__ import annotations

import argparse
import os
import sys
from typing import Any

# Windows default console encoding (cp1252) can't render the em-dashes / quotes used
# in this module's docs and output. Force UTF-8 on the streams we own.
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")

from azure.core.exceptions import HttpResponseError
from azure.data.tables import TableClient, UpdateMode

ENV_VAR = "AZURE_STORAGE_CONNECTION_STRING"
DEFAULT_TABLE = "devices"
DEFAULT_PARTITION = "nemopi"
DEFAULT_MANUFACTURER = "Save Nemo e.V."
DEFAULT_MODEL = "nemopi-002"

SETUP_HINT = f"""\
Set {ENV_VAR} first. PowerShell:
  $env:{ENV_VAR} = az storage account show-connection-string `
      --name nemopideviceonboarding --query connectionString -o tsv
Bash:
  export {ENV_VAR}="$(az storage account show-connection-string \\
      --name nemopideviceonboarding --query connectionString -o tsv)"\
"""


def build_entity(args: argparse.Namespace) -> dict[str, Any]:
    entity: dict[str, Any] = {
        "PartitionKey": args.partition_key,
        "RowKey": args.imei,
        "allowCertificateIssuance": True,
        "allowProvisioning": True,
        "isDeveloperDevice": bool(args.developer),
        "manufacturer": args.manufacturer,
        "model": args.model,
        "provisioningMetadata": args.provisioning_metadata,
    }
    if args.reset:
        # Server-managed fields cleared on the client side so the IMEI can re-issue
        # certs from scratch. Production: don't use this. Dev/test: it's the point.
        entity.update({
            "certificateIssuedAt": None,
            "certificateExpiry": None,
            "certificateThumbprint": None,
            "assignedEndpoints": None,
            "provisionedAt": None,
        })
    return entity


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--imei", required=True, help="Device IMEI / RowKey")
    parser.add_argument("--table-name", default=DEFAULT_TABLE, help=f"Table name (default: {DEFAULT_TABLE})")
    parser.add_argument("--partition-key", default=DEFAULT_PARTITION, help=f"Partition key (default: {DEFAULT_PARTITION})")
    parser.add_argument("--manufacturer", default=DEFAULT_MANUFACTURER, help=f"manufacturer field (default: {DEFAULT_MANUFACTURER!r})")
    parser.add_argument("--model", default=DEFAULT_MODEL, help=f"model field (default: {DEFAULT_MODEL!r})")
    parser.add_argument(
        "--developer",
        action="store_true",
        help="Set isDeveloperDevice=true (certs signed by Dev CA, onboarded to sandbox broker)",
    )
    parser.add_argument(
        "--provisioning-metadata",
        default="{}",
        help='provisioningMetadata field (JSON string, default: "{}")',
    )
    parser.add_argument(
        "--reset",
        action="store_true",
        help="Also clear server-set cert/onboarding fields so the IMEI can run the full flow again (dev/test only)",
    )
    args = parser.parse_args()

    conn = os.environ.get(ENV_VAR)
    if not conn:
        print(f"ERROR: {ENV_VAR} is not set.\n\n{SETUP_HINT}", file=sys.stderr)
        return 1

    client = TableClient.from_connection_string(conn, table_name=args.table_name)

    entity = build_entity(args)
    action = "RESET + UPSERT" if args.reset else "UPSERT"
    print(f"{action} table={args.table_name} :: {entity['PartitionKey']}/{entity['RowKey']}")
    for k, v in entity.items():
        if k in ("PartitionKey", "RowKey"):
            continue
        print(f"  {k} = {v!r}")

    try:
        client.upsert_entity(entity=entity, mode=UpdateMode.MERGE)
    except HttpResponseError as exc:
        print(f"\nERROR: {exc.status_code} {exc.reason}\n  {exc.message}", file=sys.stderr)
        return 1

    print("\nOK. Device is now eligible for /certificate and /onboard.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
