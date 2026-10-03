# Shared naming. Resources live in purpose-named files: storage.tf, secrets.tf, and
# iam.tf, lambda.tf, api.tf and (in later iterations) cloudfront.tf, alarms.tf.

# Random suffix for names that must be unique: S3 bucket names are global across
# all AWS accounts, and the suffix also lets two copies of this stack coexist in
# one account. It is stored in state, so names are stable across applies.
resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  name = "${var.project_name}-${random_id.suffix.hex}"

  # Shared by both Lambda functions.
  lambda_runtime      = "python3.14"
  lambda_architecture = "arm64" # Graviton: about 20% cheaper per GB-second than x86
}
