# S3
resource "aws_cloudfront_origin_access_identity" "origin_access_identity" {
  comment = "access-identity-${var.bucket_name}.s3.amazonaws.com"
}

data "aws_iam_policy_document" "s3_bucket_policy" {
  statement {
    sid = "1"

    actions = [
      "s3:GetObject",
    ]

    resources = [
      "arn:aws:s3:::${var.bucket_name}/*",
    ]

    principals {
      type = "AWS"

      identifiers = ["*"]
    }
  }
}

resource "aws_s3_bucket" "s3_bucket" {
  bucket = var.bucket_name
}

resource "aws_s3_bucket_public_access_block" "s3_bucket_public_access_block" {
  bucket = aws_s3_bucket.s3_bucket.id
  block_public_acls   = false
  block_public_policy = false
}

resource "aws_s3_bucket_ownership_controls" "s3_bucket_acl_ownership" {
  bucket = aws_s3_bucket.s3_bucket.id
  rule {
    object_ownership = "ObjectWriter"
  }
}

resource "aws_s3_bucket_acl" "s3_bucket_acl" {
  bucket = aws_s3_bucket.s3_bucket.id
  acl    = "private"
  depends_on = [aws_s3_bucket_ownership_controls.s3_bucket_acl_ownership, aws_s3_bucket_public_access_block.s3_bucket_public_access_block]
}

resource "aws_s3_bucket_policy" "cf_policy" {
  bucket = aws_s3_bucket.s3_bucket.id
  policy = data.aws_iam_policy_document.s3_bucket_policy.json
}

resource "aws_s3_bucket_website_configuration" "s3_bucket_website_config" {
  bucket = aws_s3_bucket.s3_bucket.id

  index_document {
    suffix = var.index_document
  }

  error_document {
    key = var.error_document
  }
}

module "template_files" {
  source = "hashicorp/dir/template"
  base_dir = var.files_folder_path
}

resource "aws_s3_object" "object" {
  for_each = module.template_files.files
  bucket   = aws_s3_bucket.s3_bucket.id
  key      = each.key
  content_type = each.value.content_type
  source   = each.value.source_path
  content = each.value.content
  etag = each.value.digests.md5
}

# Cloudfront
resource "aws_cloudfront_distribution" "s3_distribution" {
  depends_on = [
    aws_s3_bucket.s3_bucket
  ]

  origin {
    domain_name = aws_s3_bucket_website_configuration.s3_bucket_website_config.website_endpoint
    origin_id   = var.bucket_name

    custom_origin_config {
      http_port              = "80"
      https_port             = "443"
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1", "TLSv1.1", "TLSv1.2"]
    }
  }

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"

  aliases = ["${var.host_name}.${var.domain_name}"]

  default_cache_behavior {
    allowed_methods = [
      "GET",
      "HEAD",
    ]

    cached_methods = [
      "GET",
      "HEAD",
    ]

    target_origin_id = var.bucket_name

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 86400
    max_ttl                = 31536000
  }


  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }


  viewer_certificate {
    acm_certificate_arn      = var.acm_cert_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1"
  }

  custom_error_response {
    error_code            = 403
    response_code         = 200
    error_caching_min_ttl = 0
    response_page_path    = var.error_403_path
  }

  custom_error_response {
    error_code            = 404
    response_code         = 200
    error_caching_min_ttl = 0
    response_page_path    = var.error_404_path
  }

  wait_for_deployment = false
}

# Route 53
data "aws_route53_zone" "domain_name" {
  count        = 1
  name         = var.domain_name
  private_zone = false
}

resource "aws_route53_record" "route53_record" {
  count      = 1
  depends_on = [
    aws_cloudfront_distribution.s3_distribution
  ]

  zone_id = data.aws_route53_zone.domain_name[0].zone_id
  name    = "${var.host_name}.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.s3_distribution.domain_name
    zone_id                = "Z2FDTNDATAQYW2"
    //HardCoded value for CloudFront
    evaluate_target_health = false
  }
}

resource "null_resource" "invalidate_cf_cache" {
  triggers = {
    always_run = timestamp()
  }
  provisioner "local-exec" {
    command = "AWS_PROFILE=${var.aws_profile} aws cloudfront create-invalidation --distribution-id ${aws_cloudfront_distribution.s3_distribution.id} --paths '/*'"
  }
}
