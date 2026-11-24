terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "region" {
  default = "us-east-1" # CHANGE to the region of your control EC2
}

variable "alert_email" {}

provider "aws" {
  region = var.region
}

locals {
  colours = ["blue", "green"]
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

# ---------- ECR: stores the Docker image ----------
resource "aws_ecr_repository" "app" {
  name         = "frappe-crm"
  force_delete = true
}

# ---------- Firewalls ----------
resource "aws_security_group" "alb" {
  name        = "frappe-crm-alb-sg"
  description = "Allow web traffic to the ALB"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "task" {
  name        = "frappe-crm-task-sg"
  description = "Only the ALB may reach the app on port 8000"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---------- ALB: one load balancer, two target groups (blue, green) ----------
resource "aws_lb" "app" {
  name               = "frappe-crm-alb"
  load_balancer_type = "application"
  subnets            = data.aws_subnets.default.ids
  security_groups    = [aws_security_group.alb.id]
}

resource "aws_lb_target_group" "tg" {
  for_each             = toset(local.colours)
  name                 = "frappe-crm-${each.key}-tg"
  port                 = 8000
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = data.aws_vpc.default.id
  deregistration_delay = 30

  health_check {
    path                = "/api/method/ping"
    matcher             = "200"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 10
  }
}

# THE SWITCH: the pipeline changes which target group this points to
resource "aws_lb_listener" "live" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg["blue"].arn
  }

  lifecycle {
    ignore_changes = [default_action]
  }
}

# ---------- ECS Fargate: blue and green services ----------
resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/frappe-crm"
  retention_in_days = 7
}

resource "aws_iam_role" "task_execution" {
  name        = "frappe-crm-task-execution-role"
  description = "Lets ECS pull images from ECR and write logs to CloudWatch"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_ecs_cluster" "app" {
  name = "frappe-crm-cluster"
}

resource "aws_ecs_task_definition" "app" {
  for_each                 = toset(local.colours)
  family                   = "frappe-crm-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 2048
  memory                   = 8192
  execution_role_arn       = aws_iam_role.task_execution.arn

  ephemeral_storage {
    size_in_gib = 40
  }

  container_definitions = jsonencode([
    {
      name      = "mariadb"
      image     = "public.ecr.aws/docker/library/mariadb:10.8"
      essential = true
      command = [
        "--character-set-server=utf8mb4",
        "--collation-server=utf8mb4_unicode_ci",
        "--skip-character-set-client-handshake",
        "--skip-innodb-read-only-compressed"
      ]
      environment = [{ name = "MYSQL_ROOT_PASSWORD", value = "123" }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = each.key
        }
      }
    },
    {
      name      = "redis"
      image     = "public.ecr.aws/docker/library/redis:alpine"
      essential = true
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = each.key
        }
      }
    },
    {
      name         = "frappe"
      image        = "${aws_ecr_repository.app.repository_url}:latest"
      essential    = true
      portMappings = [{ containerPort = 8000, protocol = "tcp" }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = each.key
        }
      }
    }
  ])
}

# Both services start with 0 tasks. The pipeline starts the idle one.
resource "aws_ecs_service" "app" {
  for_each                          = toset(local.colours)
  name                              = "frappe-crm-${each.key}"
  cluster                           = aws_ecs_cluster.app.id
  task_definition                   = aws_ecs_task_definition.app[each.key].arn
  desired_count                     = 0
  launch_type                       = "FARGATE"
  health_check_grace_period_seconds = 900

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.tg[each.key].arn
    container_name   = "frappe"
    container_port   = 8000
  }

  depends_on = [aws_lb_listener.live]

  lifecycle {
    ignore_changes = [desired_count]
  }
}

# ---------- CloudWatch: alarms + email + dashboard ----------
resource "aws_sns_topic" "alerts" {
  name = "frappe-crm-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "frappe-crm-alb-5xx"
  alarm_description   = "ALB is returning 5xx errors to users"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_ELB_5XX_Count"
  dimensions          = { LoadBalancer = aws_lb.app.arn_suffix }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 5
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "cpu" {
  for_each          = toset(local.colours)
  alarm_name        = "frappe-crm-${each.key}-high-cpu"
  alarm_description = "CPU above 80 percent on the ${each.key} service"
  namespace         = "AWS/ECS"
  metric_name       = "CPUUtilization"
  dimensions = {
    ClusterName = aws_ecs_cluster.app.name
    ServiceName = aws_ecs_service.app[each.key].name
  }
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_dashboard" "app" {
  dashboard_name = "frappe-crm-bluegreen"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title  = "CPU: blue vs green"
          region = var.region
          stat   = "Average"
          period = 60
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", aws_ecs_cluster.app.name, "ServiceName", aws_ecs_service.app["blue"].name],
            ["AWS/ECS", "CPUUtilization", "ClusterName", aws_ecs_cluster.app.name, "ServiceName", aws_ecs_service.app["green"].name]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title  = "Requests and 5xx errors"
          region = var.region
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.app.arn_suffix],
            ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", aws_lb.app.arn_suffix]
          ]
        }
      },
      {
        type = "log", x = 0, y = 6, width = 24, height = 6
        properties = {
          title  = "Latest application logs"
          region = var.region
          view   = "table"
          query  = "SOURCE '${aws_cloudwatch_log_group.app.name}' | fields @timestamp, @message | sort @timestamp desc | limit 50"
        }
      }
    ]
  })
}

output "alb_url" {
  value = "http://${aws_lb.app.dns_name}"
}

output "dashboard_url" {
  value = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards:name=frappe-crm-bluegreen"
}