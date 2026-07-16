variable "project_name" {
  type    = string
  default = "oidc-devops"
}

variable "github_org" {
  type    = string
  default = "Cybertemi"
}

variable "github_repo" {
  type    = string
  default = "oidc-devops-project"
}

variable "allowed_branches" {
  type        = list(string)
  default     = ["main", "dev", "staging"]
}

variable "ecr_repository_arn" {
  description = "Leave empty to allow all repos in account (fine for learning project)"
  type        = string
  default     = ""
}