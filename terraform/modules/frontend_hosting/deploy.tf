# Uploads the Vite build output (frontend/dist, built out of band by
# `npm run build` — see docs/deployment.md) the same way the knowledge_base
# module uploads its sample docs: plain aws_s3_object + fileset, no external
# `aws s3 sync` shell-out needed.
#
# index.html gets no-cache (it references the *current* hashed asset
# filenames, so a stale cached copy would point at deleted files); the
# hashed JS/CSS/asset files Vite produces are safe to cache far in the
# future since a content change always means a new filename.

locals {
  dist_dir = "${path.module}/../../../frontend/dist"

  mime_types = {
    ".html"  = "text/html"
    ".js"    = "application/javascript"
    ".css"   = "text/css"
    ".json"  = "application/json"
    ".svg"   = "image/svg+xml"
    ".png"   = "image/png"
    ".jpg"   = "image/jpeg"
    ".jpeg"  = "image/jpeg"
    ".ico"   = "image/x-icon"
    ".woff"  = "font/woff"
    ".woff2" = "font/woff2"
    ".map"   = "application/json"
  }
}

resource "aws_s3_object" "frontend_assets" {
  for_each = fileexists("${local.dist_dir}/index.html") ? fileset(local.dist_dir, "**") : toset([])

  bucket       = aws_s3_bucket.frontend.id
  key          = each.value
  source       = "${local.dist_dir}/${each.value}"
  etag         = filemd5("${local.dist_dir}/${each.value}")
  content_type = lookup(local.mime_types, regex("\\.[^.]+$", each.value), "application/octet-stream")

  cache_control = each.value == "index.html" ? "no-cache, no-store, must-revalidate" : "public, max-age=31536000, immutable"
}
