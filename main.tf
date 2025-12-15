################################################################################
# 1. Provider & Backend Configuration
################################################################################
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "hyb-dr-lab" 
    key            = "dr-demo/terraform.tfstate"
    region         = "ap-northeast-3"
    dynamodb_table = "hyb-dr-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = "ap-northeast-3"
}

locals {
    key_name = "osaka-han"
    ssh_cidr  = "0.0.0.0/0"
    http_cidr = "0.0.0.0/0"
}

################################################################################
# 2. Networking (VPC, Subnet, IGW)
################################################################################
resource "aws_vpc" "dr_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "DR-Lab-VPC"
  }
}

resource "aws_internet_gateway" "dr_igw" {
  vpc_id = aws_vpc.dr_vpc.id

  tags = {
    Name = "DR-Lab-IGW"
  }
}

resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.dr_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-northeast-3a"
  map_public_ip_on_launch = true

  tags = {
    Name = "DR-Lab-Public-Subnet"
  }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.dr_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.dr_igw.id
  }

  tags = {
    Name = "DR-Lab-Public-RT"
  }
}

resource "aws_route_table_association" "public_rta" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

################################################################################
# 3. Security Group
################################################################################
resource "aws_security_group" "ec2_sg" {
  name        = "dr-ec2-sg"
  description = "Allow SSH and ICMP, and HTTP"
  vpc_id      = aws_vpc.dr_vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = ["0.0.0.0/0"]
  }

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

################################################################################
# 4. EC2 Instance (Primary Resource)
################################################################################
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

resource "aws_instance" "app_server" {
  ami           = data.aws_ami.amazon_linux_2023.id
  instance_type = "t3.micro"
  subnet_id     = aws_subnet.public_subnet.id
  vpc_security_group_ids = [aws_security_group.ec2_sg.id]
  key_name = local.key_name

  user_data = <<-EOF
        #!/bin/bash
        yum update -y
        amazon-linux-extras install nginx1 -y || yum install -y nginx
        systemctl enable nginx
        systemctl start nginx
        echo "<h1>1215 - DR test server</h1>" > /usr/share/nginx/html/index.html
    EOF

  tags = {
    Name = "DR-Source-EC2"
  }
}

################################################################################
# 5. Monitoring & Event Trigger (CloudWatch & EventBridge)
################################################################################
resource "aws_cloudwatch_metric_alarm" "ec2_failure_alarm" {
  alarm_name          = "ec2-status-check-failed"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "2"
  metric_name         = "StatusCheckFailed"
  namespace           = "AWS/EC2"
  period              = "60"
  statistic           = "Maximum"
  threshold           = "1"
  treat_missing_data  = "breaching"
  alarm_description   = "Trigger when EC2 status check fails"
  
  dimensions = {
    InstanceId = aws_instance.app_server.id
  }
}

resource "aws_cloudwatch_event_rule" "console_rule" {
  name        = "capture-ec2-alarm"
  description = "Capture CloudWatch Alarm State Change"

  event_pattern = jsonencode({
    "source": ["aws.cloudwatch"],
    "detail-type": ["CloudWatch Alarm State Change"],
    "detail": {
      "alarmName": [aws_cloudwatch_metric_alarm.ec2_failure_alarm.alarm_name],
      "state": {
        "value": ["ALARM"]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "lambda_target" {
  rule      = aws_cloudwatch_event_rule.console_rule.name
  target_id = "TriggerLambda"
  arn       = aws_lambda_function.dr_recovery_lambda.arn
}

################################################################################
# 6. Lambda Function (Recovery Handler)
################################################################################
resource "aws_iam_role" "lambda_exec_role" {
  name = "dr_lambda_execution_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

# 편의상 AdministratorAccess 부여
resource "aws_iam_role_policy_attachment" "lambda_policy" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# Lambda 함수 정의
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "lambda_function.py"
  output_path = "lambda_function_payload.zip"
}

resource "aws_lambda_layer_version" "tf_layer" {
  filename   = "terraform-layer.zip"
  layer_name = "terraform_execution_layer"
  compatible_runtimes = ["python3.9"]
}

resource "aws_lambda_function" "dr_recovery_lambda" {
  filename      = "lambda_function_payload.zip"
  function_name = "DR-Recovery-Function"
  role          = aws_iam_role.lambda_exec_role.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.9"
  timeout       = 300
  layers        = [aws_lambda_layer_version.tf_layer.arn]

  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  memory_size   = 1024
  ephemeral_storage {
    size = 1024
  }

  environment {
    variables = {
      SECRET_NAME  = "dr/github-token"
      GITHUB_OWNER = "playdelaybluelay-stack"
      GITHUB_REPO  = "dr-lab"
    }
  }
}

# EventBridge가 Lambda를 호출할 수 있도록 권한 부여
resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.dr_recovery_lambda.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.console_rule.arn
}

#################
# Outputs       #
#################

output "source_ec2_public_ip" {
  value = aws_instance.app_server.public_ip
}