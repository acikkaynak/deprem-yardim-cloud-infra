resource "aws_ecs_task_definition" "api-go-TD" {
  family                   = "api-go-TD"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 2048
  memory                   = 4096
  execution_role_arn       = data.aws_iam_role.ecs_task_execution_role.arn
  container_definitions = jsonencode([
    {
      name   = "container-name"
      image  = "nginx" //bunu düzelticem
      cpu    = 2048
      memory = 4096
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-create-group  = "true"
          awslogs-group         = "/ecs/api-go"
          awslogs-region        = var.region
          awslogs-stream-prefix = "ecs"
        }
      }
      essential = true
      portMappings = [
        {
          containerPort = 80
          hostPort      = 80
        }
      ]
    }
  ])
}

resource "aws_lb_target_group" "api-go-tg" {
  name        = "api-go-tg"
  port        = 80
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.vpc.id
  health_check {
    enabled  = true
    path     = "/healthcheck"
    port     = 80
    protocol = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 10
  }
  tags = {
    Name        = "api-go-tg"
    Environment = var.environment
  }
}

resource "aws_ecs_service" "api-go-service" {
  name            = "api-go-service"
  cluster         = aws_ecs_cluster.base-cluster.id
  task_definition = aws_ecs_task_definition.api-go-TD.id
  desired_count   = 20
  depends_on = [
    aws_ecs_cluster.base-cluster,
    aws_ecs_task_definition.api-go-TD,
    aws_lb_target_group.api-go-tg,
  ]
  launch_type = "FARGATE"

  network_configuration {
    subnets          = [aws_subnet.private-subnet-a.id, aws_subnet.private-subnet-b.id]
    security_groups  = [aws_security_group.service-sg.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api-go-tg.arn
    container_name   = "container-name"
    container_port   = 80
  }

  lifecycle {
    ignore_changes = [
      task_definition,
      desired_count
    ]
  }
}

resource "aws_appautoscaling_target" "api-go-target" {
  max_capacity = 50
  min_capacity = 10
  resource_id = "service/${aws_ecs_cluster.base-cluster.name}/${aws_ecs_service.api-go-service.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace = "ecs"
}

resource "aws_appautoscaling_policy" "api-go-memory" {
  name               = "api-go-memory"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.api-go-target.resource_id
  scalable_dimension = aws_appautoscaling_target.api-go-target.scalable_dimension
  service_namespace  = aws_appautoscaling_target.api-go-target.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }

    target_value       = 80
  }
}

resource "aws_appautoscaling_policy" "api-go-cpu" {
  name = "api-go-cpu"
  policy_type = "TargetTrackingScaling"
  resource_id = aws_appautoscaling_target.api-go-target.resource_id
  scalable_dimension = aws_appautoscaling_target.api-go-target.scalable_dimension
  service_namespace = aws_appautoscaling_target.api-go-target.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }

    target_value = 60
  }
}

resource "aws_lb_listener_rule" "api-go-rule" {
  listener_arn = aws_lb_listener.backend-go-alb-listener.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api-go-tg.arn
  }

  condition {
    path_pattern {
      values = ["*"]
    }
  }
}

resource "aws_lb" "backend-go-alb" {
  name               = "backend-go-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = ["sg-09d6376212dfa6ea1"] // Todo change
  subnets            = [aws_subnet.public-subnet-a.id, aws_subnet.public-subnet-b.id]

  enable_deletion_protection = true

  tags = {
    Name = "backend-go-alb"
  }
}

resource "aws_wafv2_web_acl_association" "backend-go-alb" {
  resource_arn = aws_lb.backend-go-alb.arn
  web_acl_arn  = aws_wafv2_web_acl.generic.arn
}

resource "aws_lb_listener" "backend-go-alb-listener" {
  load_balancer_arn = aws_lb.backend-go-alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api-go-tg.arn
  }
  depends_on = [
    aws_lb.backend-go-alb
  ]
}
