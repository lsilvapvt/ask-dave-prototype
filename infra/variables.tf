# Every default here must be safe to deploy as-is into a fresh AWS account.
# Inputs are added in the iteration that first uses them (llm_api_key and the model
# settings arrive with the Secrets Manager and chat iterations).

variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.aws_region))
    error_message = "aws_region must be a valid AWS region code, for example us-east-1."
  }
}

variable "project_name" {
  description = "Prefix for resource names and the Project tag. A random suffix is appended where names must be globally unique (S3 buckets)."
  type        = string
  default     = "ask-dave"

  validation {
    # Kept short and S3-safe so "<project_name>-<purpose>-<random suffix>" stays
    # within the 63-character bucket name limit.
    condition     = can(regex("^[a-z][a-z0-9-]{1,18}[a-z0-9]$", var.project_name))
    error_message = "project_name must be 3-20 characters of lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "llm_api_key" {
  description = "LLM provider API key. Required, no default. Supply via the TF_VAR_llm_api_key environment variable; never commit it."
  type        = string
  sensitive   = true
  # Ephemeral: Terraform never writes this value to state or plan files. It only
  # reaches the write-only secret_string_wo argument in secrets.tf.
  ephemeral = true
  nullable  = false

  validation {
    condition     = length(trimspace(var.llm_api_key)) > 0
    error_message = "llm_api_key must not be empty. Export TF_VAR_llm_api_key before deploying."
  }
}

variable "llm_api_key_version" {
  description = "Increment to push a new llm_api_key value to Secrets Manager. Write-only values are not stored in state, so Terraform cannot detect a changed key by itself."
  type        = number
  default     = 1
}

variable "log_retention_days" {
  description = "Days to keep Lambda and API access logs in CloudWatch."
  type        = number
  default     = 14
}

variable "history_limit" {
  description = "Maximum number of most recent questions and answers GET /history returns."
  type        = number
  default     = 50

  validation {
    condition     = var.history_limit >= 1 && var.history_limit <= 500
    error_message = "history_limit must be between 1 and 500."
  }
}
