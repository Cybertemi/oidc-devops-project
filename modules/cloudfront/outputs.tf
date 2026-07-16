output "distribution_domain_name" {
  description = "The *.cloudfront.net address your app is now reachable at"
  value       = aws_cloudfront_distribution.main.domain_name
}

output "distribution_id" {
  value = aws_cloudfront_distribution.main.id
}