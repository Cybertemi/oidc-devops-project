variable "project_name" {
  description = "Short project name, used in tags/comments"
  type        = string
  default     = "oidc-devops"
}

variable "origin_domain_name" {
  description = "The hostname CloudFront forwards requests to — your Ingress's Load Balancer DNS name"
  type        = string
}