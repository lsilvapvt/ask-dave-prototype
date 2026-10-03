# HTTPS frontend: CloudFront in front of the private frontend bucket. The default
# *.cloudfront.net certificate gives HTTPS with no domain, certificate request, or
# DNS validation, so the app works right after deploy in any account.

resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${local.name}-frontend"
  description                       = "Lets the ${var.project_name} distribution read its private bucket."
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# AWS-managed policies, looked up by name rather than hardcoded IDs.
data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_response_headers_policy" "security_headers" {
  name = "Managed-SecurityHeadersPolicy" # HSTS, nosniff, frame-options, referrer-policy, XSS protection
}

resource "aws_cloudfront_distribution" "frontend" {
  #checkov:skip=CKV_AWS_68:AWS WAF costs at least $5/month even idle; API throttling is the abuse control for this prototype.
  #checkov:skip=CKV2_AWS_47:No WAF (see CKV_AWS_68).
  #checkov:skip=CKV_AWS_86:Access logging needs a log bucket with ACLs enabled; API Gateway access logs cover the dynamic traffic.
  #checkov:skip=CKV_AWS_174:The default *.cloudfront.net certificate fixes the minimum TLS version; setting TLS 1.2 needs a custom domain and certificate.
  #checkov:skip=CKV2_AWS_42:A custom certificate needs a domain the deployer owns, which would add a manual DNS step.
  #checkov:skip=CKV_AWS_310:Origin failover needs a second bucket in another region; out of scope for the prototype.
  #checkov:skip=CKV_AWS_374:The app is meant to be reachable from anywhere.
  enabled             = true
  comment             = "${var.project_name} frontend"
  default_root_object = "index.html"
  http_version        = "http2and3"
  price_class         = "PriceClass_100" # cheapest edge set (North America and Europe)

  origin {
    origin_id                = "frontend-bucket"
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  default_cache_behavior {
    target_origin_id           = "frontend-bucket"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.caching_optimized.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security_headers.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  # `apply` waits until the distribution is live (several minutes on first deploy),
  # so the printed URL works the moment the deploy command finishes.
  wait_for_deployment = true
}

# Site files. Both are served with Cache-Control: no-cache, so a redeploy is visible
# immediately rather than after CloudFront's default 24-hour cache.

resource "aws_s3_object" "index_html" {
  bucket        = aws_s3_bucket.frontend.id
  key           = "index.html"
  source        = "${path.module}/../frontend/index.html" # uploaded byte-for-byte, never edited
  etag          = filemd5("${path.module}/../frontend/index.html")
  content_type  = "text/html; charset=utf-8"
  cache_control = "no-cache"
}

resource "aws_s3_object" "config_js" {
  bucket = aws_s3_bucket.frontend.id
  key    = "config.js"
  content = templatefile("${path.module}/../frontend/config.js.tmpl", {
    api_url = aws_apigatewayv2_api.http.api_endpoint
  })
  content_type  = "text/javascript; charset=utf-8"
  cache_control = "no-cache"
}
