terraform {
  required_version = ">= 1.11, < 2.0" # 1.11+ for write-only arguments (secret_string_wo)

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }

  # State is deliberately local (the default backend). A remote S3 backend would
  # need a state bucket that this stack cannot itself destroy, which conflicts with
  # "destroy leaves nothing behind" and adds a bootstrap step for anyone deploying.
  # See docs/architecture-decisions.md.
}

provider "aws" {
  # Region always comes from a variable, never a literal. Credentials come from the
  # standard AWS credential chain (env vars, ~/.aws profile, SSO), never from code.
  region = var.aws_region

  # Every resource this stack creates carries these tags. scripts/verify-destroyed.sh
  # (added with the first real resources) queries by them to prove destroy left
  # nothing behind.
  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform"
    }
  }
}
