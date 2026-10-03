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
