provider "aws" {
  region = "ap-northeast-2"
}

variable "env" {}
variable "vpc_cidr_block" {}
variable "subnet_cidr_block" {}
variable "az" {}

data "aws_ec2_managed_prefix_list" "ec2_instance_connect" {
  name = "com.amazonaws.ap-northeast-2.ec2-instance-connect"
}

# vpc
resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr_block
  tags = {
    Name = "${var.env}-vpc"
  }
}
#subnet
resource "aws_subnet" "main_public" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.subnet_cidr_block
  availability_zone = var.az
  tags = {
    Name = "${var.env}-subnet-main-public"
  }
}
#route_table <-> vpc , <-> igw
resource "aws_route_table" "main_public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main_igw.id
  }
  tags = {
    Name = "${var.env}-route-table-main-public"
  }
}
#igw <-> vpc
resource "aws_internet_gateway" "main_igw" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "${var.env}-internet-gateway-main"
  }
}
#route_table_association many to many route 
resource "aws_route_table_association" "main_public" {
  subnet_id      = aws_subnet.main_public.id
  route_table_id = aws_route_table.main_public.id
}


resource "aws_security_group" "web_sg" {
  name        = "${var.env}-web-sg"
  description = "Allow web inbound traffic"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Web from VPC"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr_block]
  }

  ingress {
    description     = "SSH from EC2 Instance Connect"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.ec2_instance_connect.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

#ec2
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

resource "aws_instance" "web" {
  ami             = data.aws_ami.amazon_linux.id
  instance_type   = "t2.micro"
  subnet_id       = aws_subnet.main_public.id
  security_groups = [aws_security_group.web_sg.name]

  tags = {
    Name = "${var.env}-web-instance"
  }

  associate_public_ip_address = true
}
