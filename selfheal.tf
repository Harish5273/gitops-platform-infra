# =============================================================================
# selfheal.tf - CloudWatch alarm -> SNS -> (email + Lambda reboot)
# =============================================================================

variable "alert_email" {
  description = "Email address that receives alarm notifications"
  type        = string

  validation {
    condition     = length(split("@", var.alert_email)) == 2
    error_message = "alert_email must be a valid email address."
  }
}

# Zips lambda/handler.py during plan/apply
data "archive_file" "selfheal" {
  type        = "zip"
  source_file = "${path.module}/lambda/handler.py"
  output_path = "${path.module}/lambda/selfheal.zip"
}

# ---------------------------- SNS topic + email ------------------------------
resource "aws_sns_topic" "alerts" {
  name = "${var.project_name}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ---------------------------- Lambda IAM role --------------------------------
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "selfheal" {
  name               = "${var.project_name}-selfheal-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

# Write logs to CloudWatch
resource "aws_iam_role_policy_attachment" "selfheal_logs" {
  role       = aws_iam_role.selfheal.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Least privilege: may reboot ONLY this one instance
data "aws_iam_policy_document" "selfheal_ec2" {
  statement {
    actions   = ["ec2:RebootInstances"]
    resources = [aws_instance.k3s.arn]
  }

  statement {
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "selfheal_ec2" {
  name   = "reboot-k3s-instance"
  role   = aws_iam_role.selfheal.id
  policy = data.aws_iam_policy_document.selfheal_ec2.json
}

# ---------------------------- Lambda function --------------------------------
resource "aws_lambda_function" "selfheal" {
  function_name    = "${var.project_name}-selfheal"
  role             = aws_iam_role.selfheal.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.selfheal.output_path
  source_code_hash = data.archive_file.selfheal.output_base64sha256
  timeout          = 30

  environment {
    variables = {
      INSTANCE_ID = aws_instance.k3s.id
    }
  }
}

# Allow the SNS topic to invoke the function
resource "aws_lambda_permission" "sns" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.selfheal.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alerts.arn
}

resource "aws_sns_topic_subscription" "lambda" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.selfheal.arn
}

# ---------------------------- CloudWatch alarm -------------------------------
# Fires when the instance fails its EC2 health checks for 2 minutes in a row.
# treat_missing_data = notBreaching so a stopped instance does not trigger it.
resource "aws_cloudwatch_metric_alarm" "status_check" {
  alarm_name          = "${var.project_name}-instance-status-check"
  alarm_description   = "EC2 status check failed: reboot via Lambda and notify"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    InstanceId = aws_instance.k3s.id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
}

output "alarm_name" {
  value = aws_cloudwatch_metric_alarm.status_check.alarm_name
}

output "lambda_name" {
  value = aws_lambda_function.selfheal.function_name
}
