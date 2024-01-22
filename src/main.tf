data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_security_group" "ws_sg" {
  name        = "${var.prefix}_workstation_sg"
  description = "Workstation security group"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP from Anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "TLS from Anywhere"
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

  count = var.ws_count

  ami           = data.aws_ami.ubuntu.id
  instance_type = var.ws_instance_type

  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.ws_sg.id]
  associate_public_ip_address = true

  iam_instance_profile = var.ws_iam_profile

  user_data = file("userdata.sh")

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }
  volume_tags = {
    Name = lower(var.owner)
  }

  metadata_options {
    http_endpoint          = "enabled"
    instance_metadata_tags = "enabled"
    http_tokens            = "optional"
  }

  tags = {
    Name : var.ws_count == 1 ? "${lower(var.owner)}" : "${lower(var.owner)}${count.index}"
    Layer : "computing"
  }
}

