resource "aws_organizations_policy" "fixture" {
  name    = "data-residency-gate-fixture"
  content = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Deny", Action = "s3:DeleteBucket", Resource = "*" }] })
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
    Statement = [{ Effect = "Allow", Action = "s3:*", Resource = "*" }]
  })
}

resource "aws_iam_role_policy_attachment" "fixture" {
  role       = aws_iam_role.fixture.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
