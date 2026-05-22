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

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "db_master" {
  secret_id = aws_secretsmanager_secret.db_master.id
  secret_string = jsonencode({
    username = var.master_username
    password = random_password.master.result
    host     = aws_db_instance.this.address
    port     = aws_db_instance.this.port
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

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}

resource "aws_db_parameter_group" "this" {
  name   = "${var.name_prefix}-pg15"
  family = "postgres15"

  parameter {
    name  = "log_statement"
    value = "all"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
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
