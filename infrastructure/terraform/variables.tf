# ==============================================================================
# Production variables for the Mogok Maung ECS Fargate platform.
# Copy terraform.tfvars.example -> terraform.tfvars and fill real values.
# NEVER commit terraform.tfvars (contains endpoints/SSM names).
# ==============================================================================

variable "region" {
  description = "AWS region (market: Southeast Asia)."
  type        = string
  default     = "ap-southeast-1"
}

variable "environment" {
  description = "Deployment environment suffix (prod/staging)."
  type        = string
  default     = "prod"
}

variable "tags" {
  description = "Default resource tags."
  type        = map(string)
  default = {
    Project   = "mogok-maung"
    ManagedBy = "opencode-tf"
  }
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------
variable "vpc_id" {
  description = "ID of the platform VPC."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for Fargate tasks (2+ AZs for HA)."
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "Public subnet IDs for the internet-facing ALB."
  type        = list(string)
}

# ---------------------------------------------------------------------------
# ECS / Fargate
# ---------------------------------------------------------------------------
variable "ecr_repository_url" {
  description = "ECR repo URL, e.g. 123456789012.dkr.ecr.ap-southeast-1.amazonaws.com/mm-bet-api"
  type        = string
}

variable "image_tag" {
  description = "Tag to deploy (usually the Git SHA)."
  type        = string
  default     = "latest"
}

variable "api_port" {
  type    = number
  default = 8080
}

variable "desired_count" {
  description = "Always-on Fargate tasks (HA minimum)."
  type        = number
  default     = 2
}

variable "min_capacity" {
  type    = number
  default = 2
}

variable "max_capacity" {
  description = "Autoscaling ceiling (absorbs the surge right before match kickoff)."
  type        = number
  default     = 10
}

variable "cpu_scale_target" {
  description = "CPU% at which the service scales out."
  type        = number
  default     = 70
}

variable "memory_scale_target" {
  description = "Memory% at which the service scales out."
  type        = number
  default     = 80
}

variable "log_retention_days" {
  type    = number
  default = 30
}

# ---------------------------------------------------------------------------
# Database (RDS PostgreSQL)
# ---------------------------------------------------------------------------
variable "create_rds" {
  description = "Provision the RDS instance here (false reuses external RDS)."
  type        = bool
  default     = true
}

variable "existing_rds_endpoint" {
  description = "RDS endpoint when create_rds=false (no port)."
  type        = string
  default     = ""
}

variable "db_instance_class" {
  type    = string
  default = "db.r6g.large"
}

variable "db_allocated_storage" {
  type    = number
  default = 200
}

variable "db_name" {
  type    = string
  default = "myanmar_bet_prod"
}

variable "db_username" {
  description = "Master username (password is AWS-managed + auto-rotated; stored in Secrets Manager)."
  type        = string
  default     = "bet_admin"
}

variable "db_sslmode" {
  type    = string
  default = "require"
}

variable "backup_retention_days" {
  description = "PITR window (>= 7). See scripts/dr/enable-pitr.sh."
  type        = number
  default     = 7
}

# ---------------------------------------------------------------------------
# Redis (ElastiCache) for live-odds pub/sub + cache
# ---------------------------------------------------------------------------
variable "create_redis" {
  type    = bool
  default = true
}

variable "existing_redis_endpoint" {
  type    = string
  default = ""
}

variable "redis_node_type" {
  type    = string
  default = "cache.t3.medium"
}

# ---------------------------------------------------------------------------
# TLS / certificates
# ---------------------------------------------------------------------------
variable "acm_certificate_arn" {
  description = "ACM certificate ARN for https://myanmarbet.com."
  type        = string
}

# ---------------------------------------------------------------------------
# Secrets (Parameter Store / Secrets Manager names — values never in tfvars)
# ---------------------------------------------------------------------------
variable "db_password_ssm" {
  description = "SSM Parameter name holding the RDS master password."
  type        = string
  default     = "/mm-bet/prod/db_password"
}

variable "jwt_secret_ssm" {
  description = "SSM Parameter name holding the JWT signing secret."
  type        = string
  default     = "/mm-bet/prod/jwt_secret"
}