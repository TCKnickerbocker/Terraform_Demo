# Select backend for download
terraform {
  # Assumes s3 bucket and dynamo DB table already set up, otherwise
  ### COMMENT OUT BACKEND CODE FOR FIRST RUN
  backend "s3" {
    bucket         = "tf-demo-data20231213044932486900000002"
    key            = "tf-test/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "tf-test-table1"
    encrypt        = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# Declare virtual private cloud
data "aws_vpc" "default_vpc" {
  default = true
}

data "aws_subnet_ids" "default_subnet" {
  vpc_id = data.aws_vpc.default_vpc.id
} 

# Use existing security groups
resource "aws_security_group" "instances" {
  name = "instance-security-group"
  vpc_id = data.aws_vpc.default_vpc.id
}

resource "aws_security_group" "alb" {
  name = "alb-security-group"
  vpc_id = data.aws_vpc.default_vpc.id
}

# Create two instances with different page contents to tell which is being shown by load balancer:
resource "aws_instance" "instance_1" {
  ami             = "ami-011899242bb902164" # Ubuntu 20.04 LTS // us-east-1
  instance_type   = "t2.micro" 
  security_groups = [aws_security_group.instances.name]
  user_data       = <<-EOF
              #!/bin/bash
              echo "Hello, World 1" > index.html
              python3 -m http.server 8080 &
              EOF
}

resource "aws_instance" "instance_2" {
  ami             = "ami-011899242bb902164" # Ubuntu 20.04 LTS // us-east-1
  instance_type   = "t2.micro"
  security_groups = [aws_security_group.instances.name]
  user_data       = <<-EOF
              #!/bin/bash
              echo "Hello, World 2" > index.html
              python3 -m http.server 8080 &
              EOF
}

# Setup bucket versioning, encryption
resource "aws_s3_bucket" "bucket" {
  bucket_prefix = "tf-demo-data"
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "bucket_versioning" {
  bucket = aws_s3_bucket.bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "bucket_crypto_conf" {
  bucket = aws_s3_bucket.bucket.bucket
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Load balancing listener
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.load_balancer.arn

  port = 80

  protocol = "HTTP"

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "404: page not found"
      status_code  = 404
    }
  }
}

resource "aws_lb_target_group" "instances" {
  name     = "example-target-group"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default_vpc.id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 3
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

# Init ports, arns for load instances
resource "aws_lb_target_group_attachment" "instance_1" {
  target_group_arn = aws_lb_target_group.instances.arn
  target_id        = aws_instance.instance_1.id
  port             = 8080
}

resource "aws_lb_target_group_attachment" "instance_2" {
  target_group_arn = aws_lb_target_group.instances.arn
  target_id        = aws_instance.instance_2.id
  port             = 8080
}

resource "aws_lb_listener_rule" "instances" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 100

  condition {
    path_pattern {
      values = ["*"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.instances.arn
  }
}

# Setup inbound, outbound traffic for security groups
resource "aws_security_group_rule" "allow_http_inbound" {
  type              = "ingress"
  security_group_id = aws_security_group.instances.id

  from_port   = 8080
  to_port     = 8080
  protocol    = "tcp"
  cidr_blocks = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "allow_alb_http_inbound" {
  type              = "ingress"
  security_group_id = aws_security_group.alb.id

  from_port   = 80
  to_port     = 80
  protocol    = "tcp"
  cidr_blocks = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "allow_alb_all_outbound" {
  type              = "egress"
  security_group_id = aws_security_group.alb.id

  from_port   = 0
  to_port     = 0
  protocol    = "-1"
  cidr_blocks = ["0.0.0.0/0"]
}

# Load balancer
resource "aws_lb" "load_balancer" {
  name               = "web-app-lb"
  load_balancer_type = "application"
  subnets            = data.aws_subnet_ids.default_subnet.ids
  security_groups    = [aws_security_group.alb.id]
}

# Routing
resource "aws_route53_zone" "local" {
  name = "mylocaldomain.com"  # Change this to the desired hostname for local testing
}

resource "aws_route53_record" "root" {
  zone_id = aws_route53_zone.local.zone_id
  name    = "mylocaldomain.com"
  type    = "A"

  alias {
    name                   = aws_lb.load_balancer.dns_name
    zone_id                = aws_lb.load_balancer.zone_id
    evaluate_target_health = true
  }
}

# DB Instance config
resource "aws_db_instance" "db_instance" {
  allocated_storage = 20

  auto_minor_version_upgrade = true
  storage_type               = "standard"
  engine                     = "postgres"
  engine_version             = "12"
  instance_class             = "db.t2.micro"
  db_name                       = "mydb"

  username                   = "foo"
  password                   = ""  # Replace w own pw
  skip_final_snapshot        = true
}

# Create a launch configuration
resource "aws_launch_configuration" "example" {
  name = "example-config"
  image_id = "ami-011899242bb902164"  # Specify your desired AMI ID
  instance_type = "t2.micro"  # Specify your desired instance type

  lifecycle {
    create_before_destroy = true
  }
}


# Create an Auto Scaling Group
resource "aws_autoscaling_group" "example" {
  desired_capacity     = 2  # Specify your desired initial capacity
  max_size             = 5  # Specify your desired maximum capacity
  min_size             = 1  # Specify your desired minimum capacity
  health_check_type    = "EC2"
  health_check_grace_period = 300  # 5 minutes
  force_delete         = true

  launch_configuration = aws_launch_configuration.example.id

  vpc_zone_identifier = ["subnet-xxxxxxxxxxxxxxxxx"] 

  tag {
    key                 = "Name"
    value               = "example-instance"
    propagate_at_launch = true
  }
}


### Policy as Code:
# Create an AWS Budget for 100/month on elastic compute
resource "aws_budgets_budget" "ec2" {
  name              = "budget-ec2-monthly"
  budget_type       = "COST"
  limit_amount      = "100"
  limit_unit        = "USD"
  time_period_end   = "2024-01-01_00:00"
  time_period_start = "2023-01-01_00:00"
  time_unit         = "MONTHLY"

  cost_filter {
    name = "Service"
    values = [
      "Amazon Elastic Compute Cloud - Compute",
    ]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = ["tombot1283@gmail.com"]
  }
}



# Code rollbacks:
data "terraform_remote_state" "previous_release" {
  backend = "s3"
  config = {
    bucket         = "tf-test-bucket3"
    key            = "path/to/releases/${var.release_version}/terraform.tfstate"
    region         = "us-east-1" 
    encrypt        = true
    shared_credentials_file = "~/.aws/credentials" 
  }
}

resource "aws_instance" "rollback_example" {
  ami           = data.terraform_remote_state.previous_release.outputs.example_ami
  instance_type = data.terraform_remote_state.previous_release.outputs.example_instance_type
  count         = 1

  lifecycle {
    create_before_destroy = true  # For seamless rollbacks
  }
}
