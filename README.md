# Amazon S3 Tables Replication Lab

Hands-on lab: create source and destination S3 table buckets, write an Iceberg table, configure cross-Region replication, verify the read-only replica, then promote the replica to a writable table and write from Spark.

**Announcement:** [Amazon S3 Tables now support promoting replicas to writable tables](https://aws.amazon.com/about-aws/whats-new/2026/11/amazon-s3-tables-replication-writable-tables/)

## What you will build

```
us-east-1                              us-west-2 (Oregon)
┌─────────────────────┐                ┌─────────────────────┐
│ source-table-bucket │ ──replicate──▶ │  dest-table-bucket  │
│  analytics.orders   │                │  analytics.orders   │
│  (writable source)  │                │  (read-only replica)│
└─────────────────────┘                └─────────────────────┘
                                              │
                                   disassociate (promote)
                                              ▼
                                       writable table
                                    (same name / namespace)
```

## Prerequisites

- AWS account with permissions for S3 Tables, IAM, Athena, and (optionally) EMR/Spark
- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) with `s3tables` commands
- Python 3 + `boto3` (optional path for creating buckets)
- Athena workgroups available in **both** Regions
- Enable **Integration with AWS analytics services** for table buckets in each Region (one-time per Region). This creates the Glue federated catalog `s3tablescatalog/<table-bucket-name>` used by Athena.

> **Lake Formation tip:** If Athena’s Catalog dropdown does not show `s3tablescatalog`, grant your console principal `SUPER_USER` (or `ALL`) on the `s3tablescatalog` catalog in that Region via Lake Formation.

## Lab layout

```
s3table replication/
├── README.md                 ← you are here
└── lab/
    ├── env.sh                ← shared environment variables
    ├── create_buckets.py     ← boto3: create source + dest table buckets
    ├── commands.txt          ← copy/paste CLI reference
    └── clean.sh              ← delete all lab resources when finished
```

---

## Step 0 — Set environment variables

From the `lab/` directory:

```bash
cd lab
source ./env.sh
```

Or set them yourself:

```bash
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export SOURCE_REGION=us-east-1
export DEST_REGION=us-west-2
export SOURCE_TABLE_BUCKET=source-table-bucket
export DEST_TABLE_BUCKET=dest-table-bucket
export NAMESPACE=analytics
export TABLE_NAME=orders
export REPLICATION_ROLE_NAME=S3TablesReplicationRole
```

Use lowercase names for namespaces and tables so Athena / Glue can see them.

---

## Step 1 — Create the source table bucket

### Option A — AWS CLI

```bash
aws s3tables create-table-bucket \
  --name "${SOURCE_TABLE_BUCKET}" \
  --region "${SOURCE_REGION}"

export SOURCE_TABLE_BUCKET_ARN=$(aws s3tables list-table-buckets \
  --region "${SOURCE_REGION}" \
  --query "tableBuckets[?name=='${SOURCE_TABLE_BUCKET}'].arn | [0]" \
  --output text)

echo "${SOURCE_TABLE_BUCKET_ARN}"
```

### Option B — boto3

```bash
python3 create_buckets.py --source-only
source ./env.sh   # re-load ARNs written by the script, or export manually from script output
```

In the S3 console (source Region), open the table bucket and enable **Integration with AWS analytics services** if prompted.

---

## Step 2 — Create the destination table bucket (Oregon)

```bash
aws s3tables create-table-bucket \
  --name "${DEST_TABLE_BUCKET}" \
  --region "${DEST_REGION}"

export DEST_TABLE_BUCKET_ARN=$(aws s3tables list-table-buckets \
  --region "${DEST_REGION}" \
  --query "tableBuckets[?name=='${DEST_TABLE_BUCKET}'].arn | [0]" \
  --output text)

echo "${DEST_TABLE_BUCKET_ARN}"
```

Or with boto3:

```bash
python3 create_buckets.py --dest-only
```

Enable analytics integration in the destination Region as well.

---

## Step 3 — Create the IAM role for replication

S3 Tables assumes this role to read the source and write the replica.

**Trust policy** (`replication.s3tables.amazonaws.com` must be able to assume the role):

```bash
cat > /tmp/s3tables-replication-trust.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "replication.s3tables.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

aws iam create-role \
  --role-name "${REPLICATION_ROLE_NAME}" \
  --assume-role-policy-document file:///tmp/s3tables-replication-trust.json \
  --description "Role for S3 Tables replication (lab)"
```

**Permissions policy** (read source, write destination):

```bash
cat > /tmp/s3tables-replication-permissions.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadSourceTables",
      "Effect": "Allow",
      "Action": [
        "s3tables:GetTable",
        "s3tables:GetTableMetadataLocation",
        "s3tables:GetTableMaintenanceConfiguration",
        "s3tables:GetTableData"
      ],
      "Resource": "arn:aws:s3tables:${SOURCE_REGION}:${AWS_ACCOUNT_ID}:bucket/${SOURCE_TABLE_BUCKET}/table/*"
    },
    {
      "Sid": "ListSourceBucket",
      "Effect": "Allow",
      "Action": ["s3tables:ListTables"],
      "Resource": "arn:aws:s3tables:${SOURCE_REGION}:${AWS_ACCOUNT_ID}:bucket/${SOURCE_TABLE_BUCKET}"
    },
    {
      "Sid": "CreateOnDestinationBucket",
      "Effect": "Allow",
      "Action": [
        "s3tables:CreateTable",
        "s3tables:CreateNamespace"
      ],
      "Resource": "arn:aws:s3tables:${DEST_REGION}:${AWS_ACCOUNT_ID}:bucket/${DEST_TABLE_BUCKET}"
    },
    {
      "Sid": "WriteDestinationTables",
      "Effect": "Allow",
      "Action": [
        "s3tables:PutTableData",
        "s3tables:GetTableData",
        "s3tables:UpdateTableMetadataLocation",
        "s3tables:PutTableMaintenanceConfiguration"
      ],
      "Resource": "arn:aws:s3tables:${DEST_REGION}:${AWS_ACCOUNT_ID}:bucket/${DEST_TABLE_BUCKET}/table/*"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name "${REPLICATION_ROLE_NAME}" \
  --policy-name S3TablesReplicationPermissions \
  --policy-document file:///tmp/s3tables-replication-permissions.json

export REPLICATION_ROLE_ARN=$(aws iam get-role \
  --role-name "${REPLICATION_ROLE_NAME}" \
  --query 'Role.Arn' --output text)

echo "${REPLICATION_ROLE_ARN}"
```

Your caller identity also needs `iam:PassRole` for roles passed to `replication.s3tables.amazonaws.com`.

---

## Step 4 — Create the Iceberg table and write data (source)

Create the namespace (CLI or Athena):

```bash
aws s3tables create-namespace \
  --table-bucket-arn "${SOURCE_TABLE_BUCKET_ARN}" \
  --namespace "${NAMESPACE}" \
  --region "${SOURCE_REGION}"
```

In **Athena (source Region)**:

- Data source: `AwsDataCatalog`
- Catalog: `s3tablescatalog/<your-source-table-bucket-name>`
- Database / namespace: `analytics`

```sql
CREATE TABLE analytics.orders (
  order_id    STRING,
  customer_id STRING,
  order_date  DATE,
  amount      DOUBLE,
  status      STRING
)
PARTITIONED BY (month(order_date))
TBLPROPERTIES ('table_type' = 'ICEBERG');

INSERT INTO analytics.orders VALUES
  ('ORD-001', 'CUST-A', DATE '2025-01-15', 150.00, 'completed'),
  ('ORD-002', 'CUST-B', DATE '2025-01-20', 275.50, 'completed'),
  ('ORD-003', 'CUST-A', DATE '2025-02-10',  89.99, 'pending'),
  ('ORD-004', 'CUST-C', DATE '2025-02-14', 432.00, 'completed'),
  ('ORD-005', 'CUST-B', DATE '2025-03-01',  67.25, 'cancelled');

SELECT * FROM analytics.orders ORDER BY order_id;
SELECT COUNT(*) AS row_count FROM analytics.orders;
```

Capture the source table ARN (needed for replication):

```bash
export SOURCE_TABLE_ARN=$(aws s3tables get-table \
  --table-bucket-arn "${SOURCE_TABLE_BUCKET_ARN}" \
  --namespace "${NAMESPACE}" \
  --name "${TABLE_NAME}" \
  --region "${SOURCE_REGION}" \
  --query 'tableARN' --output text)

echo "${SOURCE_TABLE_ARN}"
```

---

## Step 5 — Configure replication to the destination Region

```bash
aws s3tables put-table-replication \
  --table-arn "${SOURCE_TABLE_ARN}" \
  --region "${SOURCE_REGION}" \
  --configuration "{
    \"role\": \"${REPLICATION_ROLE_ARN}\",
    \"rules\": [
      {
        \"destinations\": [
          {
            \"destinationTableBucketARN\": \"${DEST_TABLE_BUCKET_ARN}\"
          }
        ]
      }
    ]
  }"
```

Poll until the destination is ready (usually a few minutes for a small table):

```bash
aws s3tables get-table-replication-status \
  --table-arn "${SOURCE_TABLE_ARN}" \
  --region "${SOURCE_REGION}"
```

Look for `replicationStatus` of `completed` / `ready` and a populated `lastSuccessfulReplicatedUpdate`.

Optional: insert another row in the source Athena session, wait, and confirm it appears on the replica.

---

## Step 6 — Verify the replica (destination Region)

```bash
aws s3tables list-tables \
  --table-bucket-arn "${DEST_TABLE_BUCKET_ARN}" \
  --namespace "${NAMESPACE}" \
  --region "${DEST_REGION}"

export DEST_TABLE_ARN=$(aws s3tables get-table \
  --table-bucket-arn "${DEST_TABLE_BUCKET_ARN}" \
  --namespace "${NAMESPACE}" \
  --name "${TABLE_NAME}" \
  --region "${DEST_REGION}" \
  --query 'tableARN' --output text)

echo "${DEST_TABLE_ARN}"
```

In **Athena (destination Region)**, select catalog `s3tablescatalog/<your-dest-table-bucket-name>`:

```sql
SELECT * FROM analytics.orders ORDER BY order_id;
SELECT COUNT(*) AS row_count FROM analytics.orders;
```

While the table is still a replica, writes fail (read-only), for example:

```sql
INSERT INTO analytics.orders VALUES
  ('ORD-999', 'CUST-X', DATE '2025-04-01', 10.00, 'test');
```

Expected: an error such as *Updates to service managed tables are not allowed*.

---

## Step 7 — Promote the replica and write in the secondary Region

### 7a — Disassociate (promote to writable in place)

This is a **one-way** operation. The table keeps the same namespace and name.

```bash
aws s3tables get-table-replication-status \
  --table-arn "${SOURCE_TABLE_ARN}" \
  --region "${SOURCE_REGION}"

aws s3tables disassociate-table-replication \
  --table-arn "${DEST_TABLE_ARN}" \
  --region "${DEST_REGION}"
```

Writes may return access denied for a few minutes after promote — retry if needed.

### 7b — Write with Athena (destination Region)

```sql
INSERT INTO analytics.orders VALUES
  ('ORD-007', 'CUST-E', DATE '2025-04-01', 55.00, 'pending');

SELECT * FROM analytics.orders WHERE order_id = 'ORD-007';
```

### 7c — Write with Spark (Iceberg REST catalog)

Point Spark at the **destination** table bucket ARN and Region:

```bash
spark-shell \
  --packages "org.apache.iceberg:iceberg-spark-runtime-3.5_2.12:1.6.1,software.amazon.awssdk:bundle:2.29.38,software.amazon.awssdk:url-connection-client:2.29.38" \
  --conf spark.sql.extensions=org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions \
  --conf spark.sql.defaultCatalog=s3tables \
  --conf spark.sql.catalog.s3tables=org.apache.iceberg.spark.SparkCatalog \
  --conf spark.sql.catalog.s3tables.type=rest \
  --conf spark.sql.catalog.s3tables.uri="https://s3tables.${DEST_REGION}.amazonaws.com/iceberg" \
  --conf spark.sql.catalog.s3tables.warehouse="${DEST_TABLE_BUCKET_ARN}" \
  --conf spark.sql.catalog.s3tables.rest.sigv4-enabled=true \
  --conf spark.sql.catalog.s3tables.rest.signing-name=s3tables \
  --conf spark.sql.catalog.s3tables.rest.signing-region="${DEST_REGION}" \
  --conf spark.sql.catalog.s3tables.io-impl=org.apache.iceberg.aws.s3.S3FileIO \
  --conf spark.sql.catalog.s3tables.rest-metrics-reporting-enabled=false
```

```scala
spark.sql("SHOW NAMESPACES IN s3tables").show()
spark.sql("SELECT * FROM s3tables.analytics.orders ORDER BY order_id").show()
spark.sql("""
  INSERT INTO s3tables.analytics.orders VALUES
    ('ORD-008', 'CUST-F', DATE '2025-04-10', 120.00, 'completed')
""")
```

Alternative catalog: [Amazon S3 Tables Catalog for Apache Iceberg](https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-tables-client-catalog.html) (`software.amazon.s3tables.iceberg.S3TablesCatalog`) with `warehouse` set to the destination table bucket ARN.

---

## Step 8 — Cleanup

When you are done, delete tables, namespaces, both table buckets, and the IAM role:

```bash
cd lab
./clean.sh
```

Non-interactive:

```bash
./clean.sh --yes
```

Override names / Regions if you changed them:

```bash
SOURCE_TABLE_BUCKET=my-source DEST_TABLE_BUCKET=my-dest ./clean.sh --yes
```

> After delete, recreating a table bucket with the **same name** can fail for a while (`ConflictException` / transitional state). Wait and retry, or use a new name.

---

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| `The specified table ARN is not valid` | Env var empty — re-export ARN from `get-table` / `list-table-buckets` |
| Athena Catalog = `None`, no `s3tablescatalog` | Enable analytics integration; grant LF `SUPER_USER` on `s3tablescatalog` to your console principal |
| Replication stuck `pending` | Wait a few minutes for small tables; confirm IAM role permissions and `PassRole` |
| Insert on replica fails | Expected while still associated — promote with `disassociate-table-replication` |
| Create bucket ConflictException after delete | Name still transitional — wait or pick a new bucket name |

## References

- [S3 Tables overview](https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-tables.html)
- [Setting up S3 Tables replication](https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-tables-replication-setting-up.html)
- [Disassociating a replica table](https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-tables-replication-disassociate.html)
- [Integrating S3 Tables with AWS analytics services](https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-tables-integrating-aws.html)
