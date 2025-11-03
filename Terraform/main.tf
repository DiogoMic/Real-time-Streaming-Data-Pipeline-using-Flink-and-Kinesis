
###############################################
# 1. Cloud9 Environment
###############################################
resource "aws_cloud9_environment_ec2" "cloud9_env" {
  name           = "project-cloud9-env"
  instance_type  = "t3.small"
  subnet_id      = data.aws_subnets.default.ids[0]
  automatic_stop_time_minutes = 30
  image_id = "amazonlinux-2-x86_64"
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

###############################################
# 2. S3 Bucket + Upload local files
###############################################
resource "aws_s3_bucket" "project_bucket" {
  bucket        = "project-bucket-us-accidents-new"
  force_destroy = true
  tags = {
    Name        = "ProjectBucket"
    Environment = "dev"
  }
}

# Upload raw data folder
resource "aws_s3_object" "raw_us_accidents" {
  bucket = aws_s3_bucket.project_bucket.id
  key    = "raw_us_accidents/US_Accidents_Dec20_sample_file.csv"
  source = "${path.module}/raw_us_accidents/US_Accidents_Dec20_sample_file.csv"
  etag   = filemd5("${path.module}/raw_us_accidents/US_Accidents_Dec20_sample_file.csv")
}

resource "aws_s3_object" "raw_us_accidents_original_data" {
  bucket = aws_s3_bucket.project_bucket.id
  key    = "raw_us_accidents/US_Accidents_Dec20_updated.csv"
  source = "${path.module}/raw_us_accidents/US_Accidents_Dec20_updated.csv"
  etag   = filemd5("${path.module}/raw_us_accidents/US_Accidents_Dec20_updated.csv")
}

# Upload Lambda zip
resource "aws_s3_object" "lambda_zip" {
  bucket = aws_s3_bucket.project_bucket.id
  key    = "src/lambda/read-stream-2-flink/lambda_function.zip"
  source = "${path.module}/src/lambda/lambda_function.zip"
  etag   = filemd5("${path.module}/src/lambda/lambda_function.zip")
}

###############################################
# 3. Kinesis Streams
###############################################
resource "aws_kinesis_stream" "stream_1" {
  name             = "kinesis-data-stream-1"
  retention_period = 24

  stream_mode_details {
    stream_mode = "ON_DEMAND"
  }
}

resource "aws_kinesis_stream" "stream_2" {
  name             = "kinesis-data-stream-2"
  retention_period = 24

  stream_mode_details {
    stream_mode = "ON_DEMAND"
  }
}

###############################################
# 4. Glue Database
###############################################
resource "aws_glue_catalog_database" "project_db" {
  name = "project_glue_db"
}


###############################################
# 5. SNS Topic & Subscription
###############################################
resource "aws_sns_topic" "project_alert_notification" {
  name         = "accidents-alert-notification"
  display_name = "Accidents Project Alert Notification"
}

resource "aws_sns_topic_subscription" "project_alert_notification_email" {
  topic_arn = aws_sns_topic.project_alert_notification.arn
  protocol  = "email"
  endpoint  = ""
}

###############################################
# 6. IAM Role for Lambda
###############################################
resource "aws_iam_role" "lambda_role" {
  name = "lambda-kinesis-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "lambda.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_policies" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonS3FullAccess",
    "arn:aws:iam::aws:policy/AmazonKinesisFullAccess",
    "arn:aws:iam::aws:policy/CloudWatchFullAccess",
    "arn:aws:iam::aws:policy/AmazonSNSFullAccess"
  ])
  role       = aws_iam_role.lambda_role.name
  policy_arn = each.value
}

###############################################
# 7. Lambda Function
###############################################
resource "aws_lambda_function" "stream_processor" {
  function_name = "us-accident-stream-processor"
  role          = aws_iam_role.lambda_role.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.9"
  s3_bucket     = aws_s3_bucket.project_bucket.id
  s3_key        = aws_s3_object.lambda_zip.key

  environment {
    variables = {
      CLOUDWATCH_NAMESPACE = "accidents_reports_namespace"
      CLOUDWATCH_METRIC    = "us_accidents_severity_high"
      TOPIC_ARN            = aws_sns_topic.project_alert_notification.arn
    }
  }

  depends_on = [
    aws_s3_object.lambda_zip,
    aws_iam_role_policy_attachment.lambda_policies,
    aws_sns_topic.project_alert_notification
  ]
}

resource "aws_lambda_event_source_mapping" "kinesis_trigger" {
  event_source_arn  = aws_kinesis_stream.stream_2.arn
  function_name     = aws_lambda_function.stream_processor.arn
  starting_position = "LATEST"
  batch_size        = 1
}

###############################################
# 8. CloudWatch Log Group
###############################################
resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${aws_lambda_function.stream_processor.function_name}"
  retention_in_days = 7
}

###############################################
# 9. CloudWatch Dashboard
###############################################
resource "aws_cloudwatch_dashboard" "us_accidents_dashboard" {
  dashboard_name = "USAccidentsDashboard"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric",
        x    = 0, y = 0, width = 12, height = 6,
        properties = {
          metrics = [
            ["USAccidentsNamespace", "HighSeverityAccidents", { "stat": "Sum" }]
          ],
          period = 60,
          region = "us-east-1",
          title  = "High Severity Accidents Count"
        }
      },
      {
        type = "log",
        x = 0, y = 6, width = 12, height = 6,
        properties = {
          query = "SOURCE '/aws/lambda/${aws_lambda_function.stream_processor.function_name}' | fields @timestamp, @message | sort @timestamp desc | limit 20",
          region = "us-east-1",
          title  = "Recent Lambda Logs"
        }
      }
    ]
  })
}

###############################################
# 10. IAM Role for Grafana Workspace
###############################################
resource "aws_iam_role" "grafana_service_role" {
  name = "grafana-service-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = { Service = "grafana.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "grafana_cloudwatch_access" {
  role       = aws_iam_role.grafana_service_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess"
}

resource "aws_iam_role_policy_attachment" "grafana_cloudwatch_access_full" {
  role       = aws_iam_role.grafana_service_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchFullAccess"
}

resource "aws_iam_role_policy" "grafana_inline" {
  name = "grafana-inline-policy"
  role = aws_iam_role.grafana_service_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "cloudwatch:DescribeAlarms",
          "cloudwatch:GetMetricData",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:ListMetrics",
          "logs:DescribeLogGroups",
          "logs:GetLogEvents",
          "logs:FilterLogEvents",
          "logs:DescribeLogStreams"
        ],
        Resource = "*"
      }
    ]
  })
}


###############################################
# Grafana Workspace
###############################################
resource "aws_grafana_workspace" "us_accidents_workspace" {
  name                     = "us-accidents-grafana-new"
  description              = "Grafana workspace for real-time monitoring"
  account_access_type      = "CURRENT_ACCOUNT"
  authentication_providers = ["AWS_SSO"]
  permission_type          = "SERVICE_MANAGED"
  role_arn                 = aws_iam_role.grafana_service_role.arn
  data_sources             = ["CLOUDWATCH"]

  tags = {
    Environment = "dev"
  }
}

############################################
# Kinesis Firehose Delivery Stream
############################################

resource "aws_iam_role" "firehose_role" {
  name = "firehose_s3_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = {
          Service = "firehose.amazonaws.com"
        }
      }
    ]
  })
}

# Attach policy to allow Firehose to write to S3
resource "aws_iam_role_policy_attachment" "firehose_s3_access" {
  role       = aws_iam_role.firehose_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

# Attach policy to allow Firehose to read from Kinesis
resource "aws_iam_role_policy_attachment" "firehose_kinesis_access" {
  role       = aws_iam_role.firehose_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonKinesisFullAccess"
}

# Firehose Delivery Stream
resource "aws_kinesis_firehose_delivery_stream" "us_accidents_firehose" {
  name        = "us-accidents-firehose"
  destination = "extended_s3"

  extended_s3_configuration {
    bucket_arn        = aws_s3_bucket.project_bucket.arn
    role_arn          = aws_iam_role.firehose_role.arn
    buffering_size    = 5        # MB, default
    buffering_interval = 60      # seconds, minimum 60
    compression_format = "UNCOMPRESSED" # Or "GZIP" if you want compression
  }

  kinesis_source_configuration {
    kinesis_stream_arn = aws_kinesis_stream.stream_1.arn
    role_arn           = aws_iam_role.firehose_role.arn
  }

  tags = {
    Environment = "dev"
    Project     = "USAccidents"
  }
}
