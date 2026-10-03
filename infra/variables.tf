# Every default here must be safe to deploy as-is into a fresh AWS account.
# Only llm_api_key is required. Set any variable with TF_VAR_<name>; see README
# "Configuration".

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

variable "llm_model" {
  description = "Anthropic model ID used for answers. Defaults to Claude Haiku 4.5 for cost; claude-sonnet-5-5 or claude-opus-5-5 give stronger answers at higher cost."
  type        = string
  default     = "claude-haiku-4-5"

  validation {
    condition     = can(regex("^claude-[a-z0-9.-]+$", var.llm_model))
    error_message = "llm_model must be an Anthropic model ID, for example claude-haiku-4-5."
  }
}

variable "llm_max_tokens" {
  description = "Maximum length of one answer in tokens. Caps the cost of each request."
  type        = number
  default     = 1024

  validation {
    condition     = var.llm_max_tokens >= 64 && var.llm_max_tokens <= 8192
    error_message = "llm_max_tokens must be between 64 and 8192."
  }
}

variable "max_prompt_chars" {
  description = "Longest question POST /chat accepts, in characters. Longer ones get HTTP 400."
  type        = number
  default     = 4000

  validation {
    condition     = var.max_prompt_chars >= 1 && var.max_prompt_chars <= 100000
    error_message = "max_prompt_chars must be between 1 and 100000."
  }
}

variable "alarm_email" {
  description = "Optional email address for alarm notifications. Empty (the default) means alarms still trigger and show in CloudWatch, but nobody is emailed. When set, AWS sends a confirmation email that must be accepted before notifications arrive."
  type        = string
  default     = ""

  validation {
    condition     = var.alarm_email == "" || can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alarm_email))
    error_message = "alarm_email must be empty or a valid email address."
  }
}

# API throttling (token bucket). These limits apply to the whole API, not per client:
# they cap load and LLM spend, and excess requests get HTTP 429.

variable "api_rate_limit" {
  description = "Sustained requests per second allowed on routes without their own limit (GET /history)."
  type        = number
  default     = 10
}

variable "api_burst_limit" {
  description = "Short burst of requests allowed above api_rate_limit. Kept at 10 because new AWS accounts often allow only 10 concurrent Lambda executions; beyond that Lambda refuses invocations and the API answers 503."
  type        = number
  default     = 10
}

variable "chat_rate_limit" {
  description = "Sustained POST /chat requests per second. Each one is a paid LLM call."
  type        = number
  default     = 1
}

variable "chat_burst_limit" {
  description = "Short burst of POST /chat requests allowed above chat_rate_limit."
  type        = number
  default     = 5
}
