terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ---------------------------------------------------------------------------
# Network: VPC, 2 public + 2 private subnets in two AZs, IGW, NAT Gateway
# ---------------------------------------------------------------------------

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "terraform-vpc"
  }
}

# Public Subnets
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = {
    Name = "public-subnet"
    Type = "public"
  }
}

resource "aws_subnet" "public_2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_2_subnet_cidr
  availability_zone       = "${var.aws_region}c"
  map_public_ip_on_launch = true

  tags = {
    Name = "public-subnet-2"
    Type = "public"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "terraform-igw"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "public-route-table"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Without this association the second public subnet uses the main route table
# (no route to the IGW) and the ALB node in that AZ is unreachable.
resource "aws_route_table_association" "public_2" {
  subnet_id      = aws_subnet.public_2.id
  route_table_id = aws_route_table.public.id
}

# Private Subnets
resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidr
  availability_zone = "${var.aws_region}a"

  tags = {
    Name = "private-subnet"
    Type = "private"
  }
}

resource "aws_subnet" "private_2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_2_subnet_cidr
  availability_zone = "${var.aws_region}c"

  tags = {
    Name = "private-subnet-2"
    Type = "private"
  }
}

# NAT Gateway needs an Elastic IP
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "my-nat-eip"
  }
}

# NAT Gateway in the PUBLIC subnet
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id

  tags = {
    Name = "my-nat-gateway"
  }

  depends_on = [aws_internet_gateway.main]
}

# Route table for PRIVATE subnets (egress through the NAT Gateway)
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = {
    Name = "private-route-table"
  }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_2" {
  subnet_id      = aws_subnet.private_2.id
  route_table_id = aws_route_table.private.id
}

# ---------------------------------------------------------------------------
# Security groups: Internet -> ALB -> frontend -> internal ALB -> backend
# ---------------------------------------------------------------------------

resource "aws_security_group" "alb_sg" {
  name        = "alb-sg"
  description = "Public ALB: HTTP and HTTPS from the internet"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
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

resource "aws_security_group" "frontend_sg" {
  name        = "sougba-frontend-sg"
  description = "Public web traffic and restricted SSH"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "HTTP from the public ALB only"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  ingress {
    description = "SSH from my IP only"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_allowed_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "sougba-frontend-sg"
  }
}

resource "aws_security_group" "alb_backend_sg" {
  name        = "alb-backend-sg"
  description = "Internal ALB: API port from the frontend instances only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "API from frontend (Nginx proxy)"
    from_port       = var.backend_port_api
    to_port         = var.backend_port_api
    protocol        = "tcp"
    security_groups = [aws_security_group.frontend_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "backend_sg" {
  name        = "sougba-backend-sg"
  description = "Backend instances: API from the internal ALB, SSH from frontend (bastion)"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "API from the internal ALB only"
    from_port       = var.backend_port_api
    to_port         = var.backend_port_api
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_backend_sg.id]
  }

  ingress {
    description     = "SSH from frontend instances (jump host)"
    from_port       = var.backend_port_ssh
    to_port         = var.backend_port_ssh
    protocol        = "tcp"
    security_groups = [aws_security_group.frontend_sg.id]
  }

  egress {
    description = "npm registry and MongoDB Atlas through the NAT Gateway"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "sougba-backend-sg"
  }
}

# ---------------------------------------------------------------------------
# Backend tier: internal ALB + launch template + Auto Scaling group
# ---------------------------------------------------------------------------

resource "aws_lb_target_group" "app_backend_tg" {
  name     = "app-backend-target-group"
  port     = var.backend_port_api
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  # The API has no route on "/", so /hello is used (returns 200 "Hello World!")
  health_check {
    path                = "/hello"
    protocol            = "HTTP"
    matcher             = "200-399"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }
}

resource "aws_lb" "app_backend_alb" {
  name               = "my-app-backend-alb"
  internal           = true
  load_balancer_type = "application"

  security_groups = [aws_security_group.alb_backend_sg.id]

  subnets = [
    aws_subnet.private.id,
    aws_subnet.private_2.id
  ]
}

resource "aws_lb_listener" "http_backend" {
  load_balancer_arn = aws_lb.app_backend_alb.arn
  port              = var.backend_port_api
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_backend_tg.arn
  }
}

resource "aws_launch_template" "app_backend_lt" {
  name_prefix   = "app-template-my-backend"
  image_id      = var.backend_ami_id
  instance_type = var.backend_instance_type
  key_name      = var.key_name

  vpc_security_group_ids = [
    aws_security_group.backend_sg.id
  ]

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "autoscaling-backend-server"
    }
  }
}

resource "aws_autoscaling_group" "app_asg_backend" {
  name             = "my-app-backend-asg"
  min_size         = 2
  desired_capacity = 2
  max_size         = 4
  vpc_zone_identifier = [
    aws_subnet.private.id,
    aws_subnet.private_2.id
  ]

  target_group_arns = [
    aws_lb_target_group.app_backend_tg.arn
  ]

  health_check_type         = "ELB"
  health_check_grace_period = 180

  launch_template {
    id      = aws_launch_template.app_backend_lt.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "autoscaling-app-backend"
    propagate_at_launch = true
  }
}

resource "aws_autoscaling_policy" "backend_cpu_scaling" {
  name                   = "backend-cpu-target-tracking"
  policy_type            = "TargetTrackingScaling"
  autoscaling_group_name = aws_autoscaling_group.app_asg_backend.name
  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }

    target_value = 50.0
  }
}

# ---------------------------------------------------------------------------
# Frontend tier: public ALB (HTTP -> HTTPS) + launch template + Auto Scaling group
# ---------------------------------------------------------------------------

resource "aws_lb_target_group" "app_tg" {
  name     = "app-target-group"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200-399"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }
}

resource "aws_lb" "app_alb" {
  name               = "my-app-alb"
  internal           = false
  load_balancer_type = "application"

  security_groups = [aws_security_group.alb_sg.id]

  subnets = [
    aws_subnet.public.id,
    aws_subnet.public_2.id
  ]
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.app_alb.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}

resource "aws_launch_template" "app_lt" {
  name_prefix   = "app-template-my-frontend"
  image_id      = var.frontend_ami_id
  instance_type = var.frontend_instance_type
  key_name      = var.key_name

  vpc_security_group_ids = [
    aws_security_group.frontend_sg.id
  ]

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "autoscaling-web-server"
    }
  }
}

resource "aws_autoscaling_group" "app_asg_frontend" {
  name             = "my-app-asg"
  min_size         = 2
  desired_capacity = 2
  max_size         = 4
  vpc_zone_identifier = [
    aws_subnet.public.id,
    aws_subnet.public_2.id
  ]

  target_group_arns = [
    aws_lb_target_group.app_tg.arn
  ]

  health_check_type         = "ELB"
  health_check_grace_period = 180

  launch_template {
    id      = aws_launch_template.app_lt.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "autoscaling-app"
    propagate_at_launch = true
  }
}

resource "aws_autoscaling_policy" "cpu_scaling" {
  name                   = "cpu-target-tracking"
  policy_type            = "TargetTrackingScaling"
  autoscaling_group_name = aws_autoscaling_group.app_asg_frontend.name
  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }

    target_value = 50.0
  }
}
