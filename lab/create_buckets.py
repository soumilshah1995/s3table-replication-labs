#!/usr/bin/env python3
"""
Create S3 table buckets for the replication lab (boto3).

Examples:
  python3 create_buckets.py
  python3 create_buckets.py --source-only
  python3 create_buckets.py --dest-only
  python3 create_buckets.py --source-name my-source --dest-name my-dest
"""

from __future__ import annotations

import argparse
import os
import sys

import boto3
from botocore.exceptions import ClientError


def create_table_bucket(region: str, name: str) -> str:
    client = boto3.client("s3tables", region_name=region)
    try:
        resp = client.create_table_bucket(name=name)
        arn = resp["arn"]
        print(f"Created table bucket: {arn}")
        return arn
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "")
        if code in ("ConflictException", "BucketAlreadyExists", "Conflict"):
            print(f"Bucket already exists or transitional in {region}: {name}", file=sys.stderr)
            arn = resolve_arn(region, name)
            if arn:
                print(f"Resolved existing ARN: {arn}")
                return arn
        raise


def resolve_arn(region: str, name: str) -> str | None:
    client = boto3.client("s3tables", region_name=region)
    paginator = client.get_paginator("list_table_buckets")
    for page in paginator.paginate():
        for bucket in page.get("tableBuckets", []):
            if bucket.get("name") == name:
                return bucket.get("arn")
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description="Create S3 Tables lab buckets")
    parser.add_argument("--source-region", default=os.environ.get("SOURCE_REGION", "us-east-1"))
    parser.add_argument("--dest-region", default=os.environ.get("DEST_REGION", "us-west-2"))
    parser.add_argument(
        "--source-name",
        default=os.environ.get("SOURCE_TABLE_BUCKET", "source-table-bucket"),
    )
    parser.add_argument(
        "--dest-name",
        default=os.environ.get("DEST_TABLE_BUCKET", "dest-table-bucket"),
    )
    parser.add_argument("--source-only", action="store_true")
    parser.add_argument("--dest-only", action="store_true")
    args = parser.parse_args()

    if args.source_only and args.dest_only:
        print("Use only one of --source-only / --dest-only", file=sys.stderr)
        return 2

    do_source = args.source_only or not args.dest_only
    do_dest = args.dest_only or not args.source_only

    if do_source:
        source_arn = create_table_bucket(args.source_region, args.source_name)
        print(f"export SOURCE_TABLE_BUCKET_ARN={source_arn}")

    if do_dest:
        dest_arn = create_table_bucket(args.dest_region, args.dest_name)
        print(f"export DEST_TABLE_BUCKET_ARN={dest_arn}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
