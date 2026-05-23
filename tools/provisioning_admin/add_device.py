"""
Upsert a device row in the Nemo Pi provisioning service's Azure Table Storage,
flipping it to a state where the device is allowed to call /certificate and /onboard.

This is the operational counterpart to `src/provisioning.lua` — what the client expects
the server-side row to look like before it can complete onboarding.

## Auth

Service principal via env vars (`EnvironmentCredential` from azure-identity):

    AZURE_TENANT_ID
    AZURE_CLIENT_ID
    AZURE_CLIENT_SECRET

The principal needs the `Storage Table Data Contributor` role on the storage account
(granted to it by an Azure admin, once). No other auth path is enabled — if the env
vars aren't set, the script fails loud rather than silently using whatever `az login`
happens to have cached.

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

Upsert (merge): if the row already exists, only the listed fields are overwritten —
server-set fields (certificateIssuedAt, etc.) are preserved unless --reset is passed.
With --reset, those server-set fields are cleared too so the IMEI can run the full
/certificate flow again. Dev/test only.
"""

from __future__ import annotations

import argparse
import sys
from typing import Any

# Force UTF-8 on Windows so the em-dashes in our output don't blow up under cp1252.
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")

from azure.core.exceptions import ClientAuthenticationError, HttpResponseError
from azure.data.tables import TableClient, UpdateMode
from azure.identity import EnvironmentCredential

DEFAULT_STORAGE_ACCOUNT = "nemopideviceonboarding"
DEFAULT_TABLE = "devices"
DEFAULT_PARTITION = "nemopi"
DEFAULT_MANUFACTURER = "Save Nemo e.V."
DEFAULT_MODEL = "nemopi-002"


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
    parser.add_argument("--storage-account", default=DEFAULT_STORAGE_ACCOUNT, help=f"Storage account name (default: {DEFAULT_STORAGE_ACCOUNT})")
    parser.add_argument("--table-name", default=DEFAULT_TABLE, help=f"Table name (default: {DEFAULT_TABLE})")
    parser.add_argument("--partition-key", default=DEFAULT_PARTITION, help=f"Partition key (default: {DEFAULT_PARTITION})")
    parser.add_argument("--manufacturer", default=DEFAULT_MANUFACTURER, help=f"manufacturer field (default: {DEFAULT_MANUFACTURER!r})")
    parser.add_argument("--model", default=DEFAULT_MODEL, help=f"model field (default: {DEFAULT_MODEL!r})")
    parser.add_argument("--developer", action="store_true", help="Set isDeveloperDevice=true (Dev CA / sandbox broker)")
    parser.add_argument("--provisioning-metadata", default="{}", help='provisioningMetadata field (JSON string, default: "{}")')
    parser.add_argument("--reset", action="store_true", help="Clear server-set cert/onboarding fields (dev/test only)")
    args = parser.parse_args()

    client = TableClient(
        endpoint=f"https://{args.storage_account}.table.core.windows.net",
        table_name=args.table_name,
        credential=EnvironmentCredential(),
    )

    entity = build_entity(args)
    action = "RESET + UPSERT" if args.reset else "UPSERT"
    print(f"{action} {args.storage_account}/{args.table_name} :: {entity['PartitionKey']}/{entity['RowKey']}")
    for k, v in entity.items():
        if k not in ("PartitionKey", "RowKey"):
            print(f"  {k} = {v!r}")

    try:
        client.upsert_entity(entity=entity, mode=UpdateMode.MERGE)
    except ClientAuthenticationError as exc:
        print(
            "\nERROR: Azure authentication failed.\n"
            "  Set AZURE_TENANT_ID + AZURE_CLIENT_ID + AZURE_CLIENT_SECRET for the\n"
            "  provisioning service principal.\n"
            f"  Underlying: {exc}",
            file=sys.stderr,
        )
        return 1
    except HttpResponseError as exc:
        if exc.status_code == 403:
            print(
                f"\nERROR: 403 Forbidden on table '{args.table_name}'.\n"
                f"  The authenticated principal needs the 'Storage Table Data Contributor' role\n"
                f"  on storage account '{args.storage_account}'.",
                file=sys.stderr,
            )
        else:
            print(f"\nERROR: {exc.status_code} {exc.reason}\n  {exc.message}", file=sys.stderr)
        return 1

    print("\nOK. Device is now eligible for /certificate and /onboard.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
