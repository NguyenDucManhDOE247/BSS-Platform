# EventBridge custom bus + rules to route BSS domain events to SQS consumers.
#
# Pattern:
#   order-service ──publish──> EventBridge bus 'bss-events' ──rule──> SQS 'billing-orders'
#                                                        └──rule──> SQS 'inventory-orders'
#
# Each consumer service has its own SQS queue with a dead-letter queue.

resource "aws_cloudwatch_event_bus" "this" {
  name = "${var.name_prefix}-events"

  tags = var.tags
}

# ── Per-consumer SQS queue + DLQ + rule ────────────────────────────────
resource "aws_sqs_queue" "dlq" {
  for_each = var.consumers

  name                      = "${var.name_prefix}-${each.key}-dlq"
  message_retention_seconds = 1209600 # 14 days

  tags = var.tags
}

resource "aws_sqs_queue" "main" {
  for_each = var.consumers

  name                       = "${var.name_prefix}-${each.key}"
  visibility_timeout_seconds = each.value.visibility_timeout_seconds
  message_retention_seconds  = 345600 # 4 days

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = each.value.max_receive_count
  })

  tags = var.tags
}

resource "aws_sqs_queue_policy" "allow_eventbridge" {
  for_each  = var.consumers
  queue_url = aws_sqs_queue.main[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.main[each.key].arn
      Condition = {
        ArnEquals = {
          "aws:SourceArn" = aws_cloudwatch_event_rule.this[each.key].arn
        }
      }
    }]
  })
}

resource "aws_cloudwatch_event_rule" "this" {
  for_each       = var.consumers
  name           = "${var.name_prefix}-${each.key}"
  event_bus_name = aws_cloudwatch_event_bus.this.name
  event_pattern  = each.value.event_pattern

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "sqs" {
  for_each       = var.consumers
  rule           = aws_cloudwatch_event_rule.this[each.key].name
  event_bus_name = aws_cloudwatch_event_bus.this.name
  arn            = aws_sqs_queue.main[each.key].arn

  # Dead-letter for failed event delivery (EventBridge → SQS itself fails)
  dead_letter_config {
    arn = aws_sqs_queue.dlq[each.key].arn
  }

  retry_policy {
    maximum_retry_attempts       = 3
    maximum_event_age_in_seconds = 3600
  }
}

# ── Alarm on DLQ depth ────────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "dlq_depth" {
  for_each            = var.consumers
  alarm_name          = "${var.name_prefix}-${each.key}-dlq-depth"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "Messages landed in DLQ for ${each.key} — investigate"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = aws_sqs_queue.dlq[each.key].name
  }

  tags = var.tags
}
