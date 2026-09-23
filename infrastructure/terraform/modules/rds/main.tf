# RDS PostgreSQL for BSS services.
#
# Sized for dev by default (db.t3.micro, 20GB).
# For prod: switch to db.t3.medium+, multi-AZ, longer backups.
#
# Note: we put all services' databases in ONE instance for cost (Phase ≤6).
# When QPS grows past ~100, split per-service.

resource "random_password" "master" {
  length  = 24
  special = false
}

resource "aws_secretsmanager_secret" "db_master" {
  name = "${var.name_prefix}/rds/master"
  # B-37: default (omitted) is a 30-day recovery window — a *deleted* secret's NAME stays
  # reserved for those 30 days, so the next `terraform apply` under the same name_prefix fails
  # with "You can't create this secret because a secret with this name is already scheduled for
  # deletion". That's exactly what happens on dev's "apply every morning, destroy every night"
  # cycle (CLAUDE.md §10) unless recovery is disabled. staging/prod keep real protection since
  # they're NOT destroyed nightly.
  recovery_window_in_days = var.secret_recovery_window_days

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "db_master" {
  secret_id = aws_secretsmanager_secret.db_master.id
  secret_string = jsonencode({
    username = var.master_username
    password = random_password.master.result
    host     = aws_db_instance.this.address
    # Giai đoạn 5: found for real — the Secrets Store CSI driver's AWS provider (jmespath-backed
    # extraction) rejects a non-string JMESPath result with "Invalid JMES search result type ...
    # Only string is allowed", and fails the ENTIRE secret fetch (not just this one field) when
    # it does. `aws_db_instance.this.port` is a Terraform number; jsonencode() would otherwise
    # write it as a JSON number (5432, no quotes) — tostring() forces it to a JSON string
    # ("5432") instead, which is all the provider actually requires (Spring reads it right back
    # into ${DB_PORT:5432} either way — see ADR-004).
    port = tostring(aws_db_instance.this.port)
  })
}

# ── B-21: one DB + one least-privilege user PER SERVICE ────────────────
# The instance only has ONE database (var.initial_database_name, "bss") out of the box — every
# service's `application.yml` actually points at "customer"/"product"/"orders"/"billing" (see
# deploy/postgres-init/01-create-databases.sh, the local-dev equivalent of what this does on real
# RDS), and every service used to share the SAME master user — a violation of least privilege
# (any compromised service could read/write every other service's data) that this fixes.
#
# This resource block only GENERATES the credentials + reserves them in Secrets Manager. It does
# NOT create the database/role inside Postgres itself — Terraform's AWS provider has no
# "run SQL on RDS" resource, and this repo doesn't want a `cyrilgdn/postgresql` provider
# connecting directly from wherever `terraform apply` runs (RDS sits in a private subnet;
# GitHub Actions runners aren't inside the VPC). The actual `CREATE DATABASE`/`CREATE ROLE` runs
# as a one-off Kubernetes Job (infrastructure/kubernetes/overlays/dev/db-bootstrap/), applied
# once per environment after the cluster + these secrets exist — see that directory's README.
locals {
  service_databases = {
    customer-service = "customer"
    product-catalog  = "product"
    order-management = "orders"
    billing-service  = "billing"
  }
}

resource "random_password" "service" {
  for_each = local.service_databases
  length   = 24
  special  = false
}

resource "aws_secretsmanager_secret" "service" {
  for_each = local.service_databases
  name     = "${var.name_prefix}/rds/${each.key}"

  recovery_window_in_days = var.secret_recovery_window_days

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "service" {
  for_each  = local.service_databases
  secret_id = aws_secretsmanager_secret.service[each.key].id
  secret_string = jsonencode({
    username = "${each.value}_svc" # e.g. "customer_svc" — distinct from the master user
    password = random_password.service[each.key].result
    host     = aws_db_instance.this.address
    port     = tostring(aws_db_instance.this.port) # see the identical comment on db_master above
    dbname   = each.value
  })
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.name_prefix}-db"
  subnet_ids = var.private_subnet_ids

  tags = var.tags
}

resource "aws_security_group" "rds" {
  name        = "${var.name_prefix}-rds-sg"
  description = "Allow Postgres from EKS nodes"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Postgres from EKS nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.eks_node_security_group_id]
  }

  # AWS-0104 fixed for real (not ignored): unlike the VPC-endpoints SG, RDS never initiates
  # outbound connections of its own — Postgres only replies on the connection a client already
  # opened, which security groups (stateful) already allow without any egress rule. No egress
  # block at all = deny all outbound, with zero effect on how Postgres actually works.

  tags = var.tags
}

resource "aws_db_parameter_group" "this" {
  name   = "${var.name_prefix}-pg${split(".", var.engine_version)[0]}"
  family = "postgres${split(".", var.engine_version)[0]}"

  parameter {
    name = "log_statement"
    # B-39: "all" logs the full text of EVERY SQL statement — including literal values, which
    # for this project means customer names/emails/order details end up in CloudWatch Logs
    # (PII in logs is explicitly banned by CLAUDE.md §10). "ddl" logs schema changes only
    # (CREATE/ALTER/DROP) — the audit trail you actually want without the data.
    value = var.log_statement
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000" # still log any query slower than 1s, regardless of log_statement above
  }

  tags = var.tags
}

resource "aws_db_instance" "this" {
  identifier        = "${var.name_prefix}-pg"
  engine            = "postgres"
  engine_version    = var.engine_version
  instance_class    = var.instance_class
  allocated_storage = var.allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.initial_database_name
  username = var.master_username
  password = random_password.master.result
  port     = 5432

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.this.name
  publicly_accessible    = false

  multi_az                = var.multi_az
  backup_retention_period = var.backup_retention_days
  backup_window           = "16:00-17:00" # 23-24 ICT
  maintenance_window      = "sun:17:00-sun:18:00"

  iam_database_authentication_enabled = true
  performance_insights_enabled        = var.performance_insights_enabled
  deletion_protection                 = var.deletion_protection
  skip_final_snapshot                 = !var.deletion_protection
  apply_immediately                   = !var.deletion_protection

  enabled_cloudwatch_logs_exports = ["postgresql"]

  tags = var.tags
}
