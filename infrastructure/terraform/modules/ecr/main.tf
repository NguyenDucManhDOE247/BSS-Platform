# One ECR repository per service. Lifecycle policy auto-deletes old images
# to keep storage cost near $0.
#
# Image scanning is on by default — fail-fast on critical CVEs (enforced in CI).

resource "aws_ecr_repository" "this" {
  for_each = toset(var.service_names)

  name                 = "${var.name_prefix}/${each.key}"
  image_tag_mutability = "IMMUTABLE" # tags are git SHA; never overwrite
  force_delete         = var.force_delete

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = var.tags
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name

  policy = jsonencode({
    rules = [
      # Giai đoạn 6 (ADR-005): images that have been PROMOTED must never be garbage-collected.
      # Promotion = `aws ecr put-image` adds a tag `rc-vX.Y.Z` (staging) / `vX.Y.Z` (prod) to an
      # image that also carries its SHA tag. Without these two rules, rule 3 below ("keep last 20
      # tagged") would eventually expire the SHA-tagged image a running staging/prod release — or a
      # `deploy-state` rollback target — still points at, and the next pod restart on a fresh node
      # would hit ImagePullBackOff in production.
      #
      # ECR has no "keep forever" action: `imageCountMoreThan 1000` is the idiom (a repo never gets
      # near that). ONE rule per tag pattern on purpose: for `tagPatternList` with several patterns
      # an image must match ALL of them (an image is never both `v*` and `rc-v*`), so
      # ["v*", "rc-v*"] in one rule would match nothing. An image matched by a lower-numbered rule is
      # not evaluated by the higher-numbered ones — verify after `apply` with
      # `aws ecr start-lifecycle-policy-preview` + `get-lifecycle-policy-preview` (docs/runbooks/cd-promotion.md).
      {
        rulePriority = 1
        description  = "Never expire production releases (v*)"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["v*"]
          countType      = "imageCountMoreThan"
          countNumber    = 1000
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Never expire release candidates (rc-v*)"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["rc-v*"]
          countType      = "imageCountMoreThan"
          countNumber    = 1000
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 3
        description  = "Keep last 20 tagged images"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*"]
          countType      = "imageCountMoreThan"
          countNumber    = 20
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 4
        description  = "Delete untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      }
    ]
  })
}
