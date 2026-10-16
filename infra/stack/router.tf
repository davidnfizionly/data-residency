# Router Lambda and HTTP API in the management account, eu-west-1.
# The tenant registry (tenants.json) is the routing table: tenant_region is the contractual
# residency, storage_region is where the router writes. Changes go through a reviewed pull request.

variable "git_commit" {
  description = "Commit that produced this deployment, recorded on every span"
  type        = string
  default     = "local"
}

data "aws_caller_identity" "mgmt" {}

locals {
  tenants        = jsondecode(file("${path.module}/tenants.json"))
  router_name    = "data-residency-router"
  router_role    = "arn:aws:iam::${data.aws_caller_identity.mgmt.account_id}:role/${local.router_name}"
  router_logs    = "arn:aws:logs:eu-west-1:${data.aws_caller_identity.mgmt.account_id}:log-group:/aws/lambda/${local.router_name}"
  writer_role_eu = "arn:aws:iam::${var.member_account_ids["eu"]}:role/data-residency-writer-eu"
  writer_role_us = "arn:aws:iam::${var.member_account_ids["us"]}:role/data-residency-writer-us"

  data_planes = {
    "eu-west-1" = { zone = "eu", role_arn = local.writer_role_eu, table = module.data_plane_eu.table_name, bucket = module.data_plane_eu.log_bucket }
    "us-east-1" = { zone = "us", role_arn = local.writer_role_us, table = module.data_plane_us.table_name, bucket = module.data_plane_us.log_bucket }
  }
}

resource "aws_iam_role" "router" {
  name = local.router_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "router" {
  name = "route-to-regional-writers"
  role = aws_iam_role.router.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "WriteOwnLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${local.router_logs}:log-stream:*"
      },
      {
        Sid      = "ReadOwnSpans"
        Effect   = "Allow"
        Action   = ["logs:FilterLogEvents"]
        Resource = "${local.router_logs}:*"
      },
      {
        Sid      = "AssumeRegionalWriters"
        Effect   = "Allow"
        Action   = ["sts:AssumeRole", "sts:TagSession"]
        Resource = [local.writer_role_eu, local.writer_role_us]
      },
    ]
  })
}

module "writer_eu" {
  source          = "../modules/writer-role"
  providers       = { aws = aws.eu }
  zone            = "eu"
  router_role_arn = local.router_role
  table_arn       = module.data_plane_eu.table_arn
  log_bucket      = module.data_plane_eu.log_bucket

  # IAM rejects a trust policy whose principal does not exist yet.
  depends_on = [aws_iam_role.router]
}

module "writer_us" {
  source          = "../modules/writer-role"
  providers       = { aws = aws.us }
  zone            = "us"
  router_role_arn = local.router_role
  table_arn       = module.data_plane_us.table_arn
  log_bucket      = module.data_plane_us.log_bucket

  depends_on = [aws_iam_role.router]
}

resource "aws_cloudwatch_log_group" "router" {
  name              = "/aws/lambda/${local.router_name}"
  retention_in_days = 7
}

data "archive_file" "router" {
  type        = "zip"
  source_file = "${path.module}/../../lambdas/router/dist/index.js"
  output_path = "${path.module}/build/router.zip"
}

resource "aws_lambda_function" "router" {
  function_name    = local.router_name
  role             = aws_iam_role.router.arn
  runtime          = "nodejs22.x"
  architectures    = ["arm64"]
  handler          = "index.handler"
  memory_size      = 256
  timeout          = 10
  filename         = data.archive_file.router.output_path
  source_code_hash = data.archive_file.router.output_base64sha256

  environment {
    variables = {
      TENANT_REGISTRY = jsonencode(local.tenants)
      DATA_PLANES     = jsonencode(local.data_planes)
      GIT_COMMIT      = var.git_commit
      LOG_GROUP       = aws_cloudwatch_log_group.router.name
    }
  }

  depends_on = [aws_iam_role_policy.router, aws_cloudwatch_log_group.router]
}

resource "aws_apigatewayv2_api" "router" {
  name          = local.router_name
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "router" {
  api_id                 = aws_apigatewayv2_api.router.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.router.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "router" {
  for_each = toset(["POST /records", "GET /tenants", "GET /traces"])

  api_id             = aws_apigatewayv2_api.router.id
  route_key          = each.value
  target             = "integrations/${aws_apigatewayv2_integration.router.id}"
  authorization_type = "AWS_IAM"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.router.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "api" {
  statement_id  = "AllowHttpApiInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.router.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.router.execution_arn}/*/*"
}

output "api_endpoint" {
  value     = aws_apigatewayv2_stage.default.invoke_url
  sensitive = true
}
