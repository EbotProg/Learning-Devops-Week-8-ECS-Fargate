variable "region" {
  type    = string
  default = "eu-north-1"
}

variable "project" {
  description = "Name prefix for every resource. The pipeline (deploy.yml) uses the same prefix."
  type        = string
  default     = "ebotprog-w8"
}

variable "vpc_cidr" {
  description = "Different from Weeks 5/6 so nothing overlaps"
  type        = string
  default     = "10.20.0.0/16"
}

# Only used for the FIRST task definition revision Terraform registers.
# After that, GitHub Actions + CodeDeploy own deployments.
variable "image_tags" {
  type = map(string)
  default = {
    frontend = "latest"
    backend  = "latest"
  }
}

# 0.5 vCPU / 1 GB per task (valid Fargate pair)
variable "task_cpu" {
  type    = number
  default = 512
}

variable "task_memory" {
  type    = number
  default = 1024
}

# Autoscaling
variable "min_tasks" {
  type    = number
  default = 2
}

variable "max_tasks" {
  type    = number
  default = 4
}

variable "cpu_target" {
  description = "Target average CPU % for target tracking"
  type        = number
  default     = 60
}

# Blue/green: how long the old (blue) tasks stay alive after traffic moves to green.
# This is your window for an instant manual rollback.
variable "blue_termination_wait_minutes" {
  type    = number
  default = 5
}

# Parse
variable "parse_app_id" {
  type    = string
  default = "myAppId"
}

variable "database_uri" {
  description = "MongoDB Atlas connection string (mongodb+srv://...)"
  type        = string
  sensitive   = true
}

variable "parse_master_key" {
  type      = string
  sensitive = true
}

# Optional DNS (Step 6). Leave empty to use the ALB DNS name.
variable "domain_name" {
  description = "e.g. w8.ebotprog.ink"
  type        = string
  default     = ""
}

variable "hosted_zone_name" {
  description = "e.g. ebotprog.ink"
  type        = string
  default     = ""
}
