#!/usr/bin/env bash
# Shared environment for the S3 Tables replication lab.
# Usage:  source ./env.sh

export AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
export SOURCE_REGION="${SOURCE_REGION:-us-east-1}"
export DEST_REGION="${DEST_REGION:-us-west-2}"
export SOURCE_TABLE_BUCKET="${SOURCE_TABLE_BUCKET:-source-table-bucket}"
export DEST_TABLE_BUCKET="${DEST_TABLE_BUCKET:-dest-table-bucket}"
export NAMESPACE="${NAMESPACE:-analytics}"
export TABLE_NAME="${TABLE_NAME:-orders}"
export REPLICATION_ROLE_NAME="${REPLICATION_ROLE_NAME:-S3TablesReplicationRole}"

export SOURCE_TABLE_BUCKET_ARN="${SOURCE_TABLE_BUCKET_ARN:-$(aws s3tables list-table-buckets \
  --region "${SOURCE_REGION}" \
  --query "tableBuckets[?name=='${SOURCE_TABLE_BUCKET}'].arn | [0]" \
  --output text 2>/dev/null || true)}"

export DEST_TABLE_BUCKET_ARN="${DEST_TABLE_BUCKET_ARN:-$(aws s3tables list-table-buckets \
  --region "${DEST_REGION}" \
  --query "tableBuckets[?name=='${DEST_TABLE_BUCKET}'].arn | [0]" \
  --output text 2>/dev/null || true)}"

if [[ -n "${SOURCE_TABLE_BUCKET_ARN}" && "${SOURCE_TABLE_BUCKET_ARN}" != "None" ]]; then
  export SOURCE_TABLE_ARN="${SOURCE_TABLE_ARN:-$(aws s3tables get-table \
    --table-bucket-arn "${SOURCE_TABLE_BUCKET_ARN}" \
    --namespace "${NAMESPACE}" \
    --name "${TABLE_NAME}" \
    --region "${SOURCE_REGION}" \
    --query 'tableARN' --output text 2>/dev/null || true)}"
fi

if [[ -n "${DEST_TABLE_BUCKET_ARN}" && "${DEST_TABLE_BUCKET_ARN}" != "None" ]]; then
  export DEST_TABLE_ARN="${DEST_TABLE_ARN:-$(aws s3tables get-table \
    --table-bucket-arn "${DEST_TABLE_BUCKET_ARN}" \
    --namespace "${NAMESPACE}" \
    --name "${TABLE_NAME}" \
    --region "${DEST_REGION}" \
    --query 'tableARN' --output text 2>/dev/null || true)}"
fi

export REPLICATION_ROLE_ARN="${REPLICATION_ROLE_ARN:-$(aws iam get-role \
  --role-name "${REPLICATION_ROLE_NAME}" \
  --query 'Role.Arn' --output text 2>/dev/null || true)}"

echo "AWS_ACCOUNT_ID=${AWS_ACCOUNT_ID}"
echo "SOURCE_REGION=${SOURCE_REGION}  DEST_REGION=${DEST_REGION}"
echo "SOURCE_TABLE_BUCKET=${SOURCE_TABLE_BUCKET}"
echo "DEST_TABLE_BUCKET=${DEST_TABLE_BUCKET}"
echo "SOURCE_TABLE_BUCKET_ARN=${SOURCE_TABLE_BUCKET_ARN:-<not created yet>}"
echo "DEST_TABLE_BUCKET_ARN=${DEST_TABLE_BUCKET_ARN:-<not created yet>}"
echo "SOURCE_TABLE_ARN=${SOURCE_TABLE_ARN:-<not created yet>}"
echo "DEST_TABLE_ARN=${DEST_TABLE_ARN:-<not created yet>}"
echo "REPLICATION_ROLE_ARN=${REPLICATION_ROLE_ARN:-<not created yet>}"
