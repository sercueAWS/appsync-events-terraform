terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.9.0"
    }
  }
  required_version = ">= 1.13.3"
}

provider "aws" {
  region = "eu-west-1"
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  appsync_smowl_name = "smowltech-appsync-api"
}

# IAM role for Lambda authorizer
resource "aws_iam_role" "lambda_auth_role" {
  name = "appsync-lambda-authorizer-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
  
}

# IAM role for Lambda datasource
resource "aws_iam_role" "lambda_ds_role" {
  name = "appsync-lambda-datasource-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# IAM role for Appsync events CloudWatch logging
resource "awscc_iam_role" "appsync_logs_role" {
  role_name = "appsync-logs-role"
  assume_role_policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "appsync.amazonaws.com"
        }
      }
    ]
  })

  policies = [
    {
      policy_name = "appsync-cloudwatch-logs"
      policy_document = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Effect = "Allow"
            Action = [
              "logs:CreateLogGroup",
              "logs:CreateLogStream",
              "logs:PutLogEvents"
            ]
            Resource = [
              "arn:aws:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/appsync/*:*"
            ]
          }
        ]
      })
    }
  ]
}

resource "aws_iam_role_policy_attachment" "lambda_auth_basic_execution" {
  role       = aws_iam_role.lambda_auth_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_ds_basic_execution" {
  role       = aws_iam_role.lambda_ds_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "archive_file" "lambda_auth_zip_inline" {
  type        = "zip"
  output_path = "/tmp/lambda_auth_zip_inline.zip"
  source {
    content  = <<EOF
export const handler = async (event, context) => {
    console.log("AppSync Authorizer Event:", JSON.stringify(event, null, 2));
    
    return {
        isAuthorized: true
    };
};
EOF
    filename = "index.mjs"
  }
}

data "archive_file" "lambda_ds_zip_inline" {
  type        = "zip"
  output_path = "/tmp/lambda_ds_zip_inline.zip"
  source {
    content  = <<EOF
export const handler = async (event, context) => {
    console.log("Echo Lambda:: " + JSON.stringify(event));
  return {
        statusCode: 200,
        body: JSON.stringify({ functionName: context.functionName }),
    };
};
EOF
    filename = "index.mjs"
  }
}

# Dummy Lambda authorizer code
resource "aws_lambda_function" "appsync_authorizer" {
  function_name = "appsync-lambda-authorizer"
  role          = aws_iam_role.lambda_auth_role.arn
  handler       = "index.handler"
  runtime       = "nodejs20.x"

  filename         = data.archive_file.lambda_auth_zip_inline.output_path
  source_code_hash = data.archive_file.lambda_auth_zip_inline.output_base64sha256
}

# Dummy Lambda datasource code
resource "aws_lambda_function" "appsync_datasource" {
  function_name = "appsync-lambda-datasource"
  role          = aws_iam_role.lambda_ds_role.arn
  handler       = "index.handler"
  runtime       = "nodejs20.x"

  filename         = data.archive_file.lambda_ds_zip_inline.output_path
  source_code_hash = data.archive_file.lambda_ds_zip_inline.output_base64sha256
}

# AppSync Events API with Lambda authorizer
resource "aws_appsync_api" "events_api" {
  name = local.appsync_smowl_name

  event_config {
    log_config {
      cloudwatch_logs_role_arn = awscc_iam_role.appsync_logs_role.arn
      log_level                = "INFO"
    }

    auth_provider {
        auth_type = "AWS_LAMBDA"
        lambda_authorizer_config {
          authorizer_uri = aws_lambda_function.appsync_authorizer.arn
        }
    }

    connection_auth_mode {
        auth_type = "AWS_LAMBDA"
    }

    default_publish_auth_mode {
        auth_type = "AWS_LAMBDA"
    }

    default_subscribe_auth_mode {
        auth_type = "AWS_LAMBDA"
    }
  }
}

# Lambda datasource for Appsync
resource "aws_appsync_datasource" "lambda_datasource" {
  api_id           = aws_appsync_api.events_api.api_id
  type = "AWS_LAMBDA"
  name             = "appsyncevent_lambda_datasource"
  service_role_arn = aws_iam_role.lambda_ds_role.arn
  lambda_config {
    function_arn = aws_lambda_function.appsync_datasource.arn
  }
}

# Channel namespace
resource "aws_appsync_channel_namespace" "default_ns" {
  api_id = aws_appsync_api.events_api.api_id
  name   = "smowltech-namespace"

  handler_configs {
    on_publish {
      behavior = "DIRECT"
      integration {
         data_source_name = aws_appsync_datasource.lambda_datasource.name
         lambda_config {
           invoke_type = "EVENT"
         }
      }
    }

    on_subscribe {
      behavior = "DIRECT"
      integration {
         data_source_name = aws_appsync_datasource.lambda_datasource.name
         lambda_config {
           invoke_type = "EVENT"
         }
      }
    }
  }
}

# Allow Appsync to use Lambda auth function, otherwise it will pop "BadRequest" error
resource "aws_lambda_permission" "allow_appsync_authorizer" {
  statement_id  = "AllowExecutionFromAppsync"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.appsync_authorizer.function_name
  principal     = "appsync.amazonaws.com"
  source_arn    = "arn:aws:appsync:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:apis/${aws_appsync_api.events_api.api_id}"
}

# Outputs
output "events_api_id" {
  value = aws_appsync_api.events_api.api_id
}

output "events_api_http_endpoint" {
  value = aws_appsync_api.events_api.dns["HTTP"]
}

output "events_api_realtime_endpoint" {
  value = aws_appsync_api.events_api.dns["REALTIME"]
}