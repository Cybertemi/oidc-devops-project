# ---------------------------------------------------------------------------
# CloudFront distribution — sits in front of your Ingress's Load Balancer,
# caching and speeding up delivery to users worldwide.
# ---------------------------------------------------------------------------
resource "aws_cloudfront_distribution" "main" {
  enabled = true
  comment = "${var.project_name} CDN"

  origin {
    domain_name = var.origin_domain_name
    origin_id   = "eks-ingress-origin"

    custom_origin_config {
      # Since your origin (the ELB) already terminates HTTPS itself
      # (via cert-manager's Let's Encrypt cert), CloudFront talks to
      # it over HTTPS too — this keeps the whole path encrypted,
      # not just the CloudFront-to-viewer leg.
      http_port                = 80
      https_port                = 443
      origin_protocol_policy    = "http-only"
      origin_ssl_protocols      = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    allowed_methods         = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    target_origin_id         = "eks-ingress-origin"
    viewer_protocol_policy   = "redirect-to-https"

    # Nextcloud is a dynamic app, not a static site — we don't want
    # CloudFront aggressively caching logged-in pages, API responses,
    # or file uploads. Forwarding everything through keeps it functionally
    # correct; true static-asset caching would need Nextcloud-specific
    # cache rules, which is a reasonable "next step" to mention in an
    # interview rather than something to over-engineer here.
    forwarded_values {
      query_string = true
      headers      = ["*"]

      cookies {
        forward = "all"
      }
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 0
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # No custom domain / ACM cert attached — using CloudFront's default
  # certificate on its own *.cloudfront.net address, since this project
  # doesn't have a purchased domain. In production, this is where you'd
  # attach an ACM certificate for a custom domain instead.
  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = {
    Project = var.project_name
  }
}