# ==============================================================================
# IAM for ECS: execution role (pull image, push logs) + task role (read SSM).
# The DB password and JWT secret NEVER appear in tfvars — tasks read them from
# SSM Parameter Store at startup via valueFrom.
# ==============================================================================

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# --- Execution role: ECR pull + CloudWatch logs ---------------------------------
resource "aws_iam_role" "ecs_execution" {
  name               = "mm-bet-${var.environment}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "exec_main" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_policy" "ecr_pull" {
  name = "mm-bet-${var.environment}-ecr-pull"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ecr:GetAuthorizationToken",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "exec_ecr" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = aws_iam_policy.ecr_pull.arn
}

# --- Task role: read secrets at container start ---------------------------------
resource "aws_iam_role" "ecs_task" {
  name               = "mm-bet-${var.environment}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_policy" "ssm_secrets" {
  name = "mm-bet-${var.environment}-ssm-read"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssm:GetParameter",
        "ssm:GetParameters",
      ]
      Resource = [
        "arn:aws:ssm:${var.region}:*:parameter${var.db_password_ssm}",
        "arn:aws:ssm:${var.region}:*:parameter${var.jwt_secret_ssm}",
      ]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "task_ssm" {
  role       = aws_iam_role.ecs_task.name
  policy_arn = aws_iam_policy.ssm_secrets.arn
}