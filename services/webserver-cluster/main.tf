terraform {
  backend "s3" {
    bucket = "reet-terraform-state"
    key = "stage/services/webserver-cluster/terraform.tfstate"
    region = "us-east-2"

    dynamodb_table = "reet-terraform-locks"
    encrypt = true
  }
}

# Data is a way to get information from the provider about existing resources
data "aws_vpc"  "default" {
  default = true
}

data "aws_subnet_ids" "default" {
  vpc_id = data.aws_vpc.default.id
}

data "terraform_remote_state" "db" {
  backend = "s3"

  config = {
    bucket = var.db_remote_state_bucket
    key = var.db_remote_state_key
    region = "us-east-2"
  }
}

locals {
  http_port = 80
  any_port = 0
  any_protocol = "-1"
  tcp_protocol = "tcp"
  all_ips = ["0.0.0.0/0"]
}

resource "aws_launch_configuration" "example" {
  image_id = "ami-0010d386b82bc06f0"
  instance_type = "t2.micro"

  security_groups = [aws_security_group.instance.id]

  user_data = <<-EOF
    #!/bin/bash
    echo "Hello, world!\n" > index.html
    echo ${data.terraform_remote_state.db.outputs.address} >> index.html
    echo ${data.terraform_remote_state.db.outputs.port} >> index.html
    nohup busybox httpd -f -p ${var.server_port} &
  EOF

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "asg" {
  launch_configuration = aws_launch_configuration.example.name
  vpc_zone_identifier = data.aws_subnet_ids.default.ids

  target_group_arns = [aws_lb_target_group.asg.arn]
  health_check_type = "ELB" # Uses the health_check in the target group

  min_size = 2
  max_size = 10

  tag {
    key = "Name"
    value = "terraform-asg-example"
    propagate_at_launch = true
  }
}

resource "aws_security_group" "instance" {
  name = "${var.cluster_name}-instance"

  ingress {
    from_port = var.server_port
    to_port = var.server_port
    protocol = local.tcp_protocol
    cidr_blocks = local.all_ips
  }
}

resource "aws_security_group" "alb" {
  name = "${var.cluster_name}-alb"

  ingress {
    from_port = local.http_port
    to_port = local.http_port
    protocol = local.tcp_protocol
    cidr_blocks = local.all_ips
  }

  egress {
    from_port = local.any_port
    to_port = local.any_port
    protocol = local.any_protocol
    cidr_blocks = local.all_ips
  }
}

resource "aws_lb" "example" {
  name = "terraform-asg-example"
  load_balancer_type = "application"
  security_groups = [aws_security_group.alb.id]
  subnets = data.aws_subnet_ids.default.ids
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.example.arn
  port = local.http_port
  protocol = "HTTP"

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "404: page not found"
      status_code = 404
    }
  }
}

resource "aws_lb_target_group" "asg" {
  name = "asg-target-group"
  port = var.server_port
  protocol = "HTTP"
  vpc_id = data.aws_vpc.default.id

  # This is used to check if the service is up, also see health_check_type
  # under the ASG as that makes sure this is used
  health_check {
    path = "/"
    protocol = "HTTP"
    port = var.server_port
    matcher = "200"
    interval = 15
    timeout = 3
    healthy_threshold = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener_rule" "asg" {
  listener_arn = aws_lb_listener.http.arn
  priority = 100

  condition {
    path_pattern {
      values = ["*"]
    }
  }

  action {
    type = "forward"
    target_group_arn = aws_lb_target_group.asg.arn
  }
}
