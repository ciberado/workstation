module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "${var.prefix}-vpc"
  cidr = "${var.vpc_addr_prefix}.0.0/16"

  azs = ["${var.region}${var.ws_az}"]
  public_subnets = ["${var.vpc_addr_prefix}.101.0/24"]

  enable_dns_hostnames = true
  enable_dns_support   = true

  enable_nat_gateway = false

  tags = {
    Layer : "network fabric"
  }
}

resource "aws_security_group" "app_sg" {
  name        = "${var.prefix}_app_sg"
  description = "Workstation security group"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description      = "HTTP from Anywhere"
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
  }

  ingress {
    description      = "TLS from Anywhere"
    from_port        = 443
    to_port          = 443
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
  }  

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
  }

  tags = {
    Layer : "network fabric"
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] /* Ubuntu */

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

resource "aws_instance" "workstation" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.ws_instance_type

  subnet_id                   = module.vpc.public_subnets[0]
  vpc_security_group_ids      = [aws_security_group.app_sg.id]
  associate_public_ip_address = true

  iam_instance_profile = "LabInstanceProfile"

  user_data = file("userdata.sh")

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }
  volume_tags = {
    Name = lower(var.owner)
  }

  metadata_options {
    http_endpoint = "enabled"
    instance_metadata_tags = "enabled"
  }
  
  tags = {
    Name  : lower(var.owner)
    Layer : "computing"
  }  
}

resource "aws_eip" "workstationip" {
  instance = aws_instance.workstation.id
  domain   = "vpc"

  tags = {
    Name  : "${lower(var.owner)}-workstation"
    Layer : "networking"
  }  
}
