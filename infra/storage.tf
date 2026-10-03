# History data bucket: one JSON object per question and answer, under history/.

resource "aws_s3_bucket" "data" {
  #checkov:skip=CKV_AWS_18:Access logging would need a second bucket and adds cost; CloudTrail covers API access if needed.
  #checkov:skip=CKV_AWS_21:Objects are write-once and never overwritten, so versioning adds cost without protecting anything.
  #checkov:skip=CKV_AWS_144:Cross-region replication is out of scope for a prototype that must cost near zero idle.
  #checkov:skip=CKV_AWS_145:SSE-S3 encrypts at rest; a customer-managed KMS key costs about $1/month even when idle.
  #checkov:skip=CKV2_AWS_62:Nothing consumes bucket event notifications.
  #checkov:skip=CKV2_AWS_61:Lifecycle expiry would silently delete history that users expect to keep.
  bucket = "${local.name}-data"

  # Lets `terraform destroy` delete the bucket even when it still holds objects.
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "data" {
  bucket = aws_s3_bucket.data.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Disables ACLs entirely: access is governed only by IAM and bucket policies.
resource "aws_s3_bucket_ownership_controls" "data" {
  bucket = aws_s3_bucket.data.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data" {
  bucket = aws_s3_bucket.data.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Rejects any request that is not over HTTPS.
resource "aws_s3_bucket_policy" "data" {
  bucket = aws_s3_bucket.data.id
  policy = data.aws_iam_policy_document.data_bucket.json

  # Applying a policy while the public access block is still being created can
  # fail with AccessDenied.
  depends_on = [aws_s3_bucket_public_access_block.data]
}

data "aws_iam_policy_document" "data_bucket" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.data.arn,
      "${aws_s3_bucket.data.arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}
