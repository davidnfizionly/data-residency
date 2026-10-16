resource "aws_s3_bucket" "fixture" {
  bucket = "data-residency-gate-fixture"
}

resource "aws_iam_role" "fixture" {
  name = "data-residency-gate-fixture"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "lambda.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy" "fixture" {
  role = aws_iam_role.fixture.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = ["s3:PutObject"], Resource = "arn:aws:s3:::data-residency-gate-fixture/logs/*" }]
  })
}
