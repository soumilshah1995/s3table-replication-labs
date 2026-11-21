#!/usr/bin/env bash
# Delete all resources created by the S3 Tables replication lab:
#   - tables and namespaces in source + dest table buckets
#   - source + dest table buckets
#   - replication IAM role (+ inline policy)
#
# Usage:
#   ./clean.sh
#   ./clean.sh --yes
#   SOURCE_TABLE_BUCKET=my-src DEST_TABLE_BUCKET=my-dst ./clean.sh --yes
set -euo pipefail

export AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
export SOURCE_REGION="${SOURCE_REGION:-us-east-1}"
export DEST_REGION="${DEST_REGION:-us-west-2}"
export SOURCE_TABLE_BUCKET="${SOURCE_TABLE_BUCKET:-source-table-bucket}"
export DEST_TABLE_BUCKET="${DEST_TABLE_BUCKET:-dest-table-bucket}"
export REPLICATION_ROLE_NAME="${REPLICATION_ROLE_NAME:-S3TablesReplicationRole}"

SOURCE_TABLE_BUCKET_ARN="${SOURCE_TABLE_BUCKET_ARN:-arn:aws:s3tables:${SOURCE_REGION}:${AWS_ACCOUNT_ID}:bucket/${SOURCE_TABLE_BUCKET}}"
DEST_TABLE_BUCKET_ARN="${DEST_TABLE_BUCKET_ARN:-arn:aws:s3tables:${DEST_REGION}:${AWS_ACCOUNT_ID}:bucket/${DEST_TABLE_BUCKET}}"

echo "Account:              ${AWS_ACCOUNT_ID}"
echo "Source bucket ARN:    ${SOURCE_TABLE_BUCKET_ARN}"
echo "Dest bucket ARN:      ${DEST_TABLE_BUCKET_ARN}"
echo "Replication role:     ${REPLICATION_ROLE_NAME}"
echo

confirm="${1:-}"
if [[ "${confirm}" != "--yes" && "${confirm}" != "-y" ]]; then
  read -r -p "Delete lab resources above? [y/N] " ans
  case "${ans}" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; exit 0 ;;
  esac
fi

ns_names_from_json() {
  python3 -c '
import json,sys
data=json.load(sys.stdin)
for item in data.get("namespaces", []):
    n = item.get("namespace") if isinstance(item, dict) else item
    if isinstance(n, list):
        n = n[0] if n else ""
    if n:
        print(n)
'
}

table_names_from_json() {
  python3 -c '
import json,sys
data=json.load(sys.stdin)
for t in data.get("tables", []):
    name=t.get("name")
    if name:
        print(name)
'
}

cleanup_table_bucket() {
  local region="$1"
  local arn="$2"
  local label="$3"

  echo "======== Cleaning ${label} (${region}) ========"

  local found
  found="$(aws s3tables list-table-buckets --region "${region}" \
    --query "tableBuckets[?arn=='${arn}' || name=='${label}'].arn | [0]" \
    --output text 2>/dev/null || true)"
  if [[ -z "${found}" || "${found}" == "None" ]]; then
    echo "Table bucket not found (already deleted): ${arn}"
    return 0
  fi

  aws s3tables delete-table-bucket-replication \
    --table-bucket-arn "${arn}" \
    --region "${region}" 2>/dev/null || true

  local ns_json
  ns_json="$(aws s3tables list-namespaces --table-bucket-arn "${arn}" --region "${region}" --output json)"
  while IFS= read -r ns; do
    [[ -z "${ns}" ]] && continue
    echo "--- namespace: ${ns} ---"

    local tables_json
    tables_json="$(aws s3tables list-tables --table-bucket-arn "${arn}" --namespace "${ns}" --region "${region}" --output json)"
    while IFS= read -r tname; do
      [[ -z "${tname}" ]] && continue
      echo "Deleting table: ${tname}"

      local table_arn
      table_arn="$(aws s3tables get-table \
        --table-bucket-arn "${arn}" \
        --namespace "${ns}" \
        --name "${tname}" \
        --region "${region}" \
        --query 'tableARN' --output text 2>/dev/null || true)"

      if [[ -n "${table_arn}" && "${table_arn}" != "None" ]]; then
        aws s3tables delete-table-replication --table-arn "${table_arn}" --region "${region}" 2>/dev/null || true
        aws s3tables disassociate-table-replication --table-arn "${table_arn}" --region "${region}" 2>/dev/null || true
      fi

      aws s3tables delete-table \
        --table-bucket-arn "${arn}" \
        --namespace "${ns}" \
        --name "${tname}" \
        --region "${region}"
    done < <(echo "${tables_json}" | table_names_from_json)

    echo "Deleting namespace: ${ns}"
    aws s3tables delete-namespace \
      --table-bucket-arn "${arn}" \
      --namespace "${ns}" \
      --region "${region}"
  done < <(echo "${ns_json}" | ns_names_from_json)

  echo "Deleting table bucket: ${arn}"
  aws s3tables delete-table-bucket \
    --table-bucket-arn "${arn}" \
    --region "${region}"
  echo "Done: ${label}"
  echo
}

cleanup_table_bucket "${SOURCE_REGION}" "${SOURCE_TABLE_BUCKET_ARN}" "${SOURCE_TABLE_BUCKET}"
cleanup_table_bucket "${DEST_REGION}" "${DEST_TABLE_BUCKET_ARN}" "${DEST_TABLE_BUCKET}"

echo "======== Deleting IAM role ${REPLICATION_ROLE_NAME} ========"
aws iam delete-role-policy \
  --role-name "${REPLICATION_ROLE_NAME}" \
  --policy-name S3TablesReplicationPermissions 2>/dev/null || true

while IFS= read -r policy_arn; do
  [[ -z "${policy_arn}" || "${policy_arn}" == "None" ]] && continue
  aws iam detach-role-policy --role-name "${REPLICATION_ROLE_NAME}" --policy-arn "${policy_arn}" 2>/dev/null || true
done < <(aws iam list-attached-role-policies --role-name "${REPLICATION_ROLE_NAME}" \
  --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null | tr '\t' '\n')

aws iam delete-role --role-name "${REPLICATION_ROLE_NAME}" 2>/dev/null || \
  echo "IAM role already gone or could not delete: ${REPLICATION_ROLE_NAME}"

echo
echo "======== Remaining table buckets ========"
echo "${SOURCE_REGION}:"
aws s3tables list-table-buckets --region "${SOURCE_REGION}" \
  --query 'tableBuckets[].name' --output text || true
echo "${DEST_REGION}:"
aws s3tables list-table-buckets --region "${DEST_REGION}" \
  --query 'tableBuckets[].name' --output text || true

echo
echo "Cleanup complete."
