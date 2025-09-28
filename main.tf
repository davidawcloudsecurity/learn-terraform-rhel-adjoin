# Provider configuration
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  
  # Comment out backend initially, uncomment after bootstrap
  # backend "s3" {
  #   bucket = "your-terraform-state-bucket"
  #   key    = "infrastructure/terraform.tfstate"
  #   region = "us-east-1"
  #   dynamodb_table = "terraform-state-lock"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = "us-east-1"
}

# VPC
resource "aws_vpc" "main" {
  cidr_block           = "172.16.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "main-vpc"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "main-igw"
  }
}

# Public Subnet
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "172.16.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "public-subnet"
  }
}

# Route Table for Public Subnet
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "public-rt"
  }
}

# Route Table Association
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Data source for availability zones
data "aws_availability_zones" "available" {
  state = "available"
}

# Security Group for RHEL instance
resource "aws_security_group" "rhel_sg" {
  name        = "rhel-sg"
  description = "Security group for RHEL instance"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
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
    Name = "rhel-sg"
  }
}

# AWS Managed Microsoft AD
resource "aws_directory_service_directory" "main" {
  name     = "gccnhb.gov.sg"
  password = "P@ssw0rd123"
  type     = "MicrosoftAD"
  edition  = "Standard"

  vpc_settings {
    vpc_id     = aws_vpc.main.id
    subnet_ids = [aws_subnet.public.id, aws_subnet.private.id]
  }

  tags = {
    Name = "main-ad"
  }
}

# Private Subnet for AD (required for AWS Managed AD)
resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "172.16.2.0/24"
  availability_zone = data.aws_availability_zones.available.names[1]

  tags = {
    Name = "private-subnet"
  }
}

# Get latest RHEL AMI
data "aws_ami" "rhel" {
  most_recent = true
  owners      = ["309956199498"] # Red Hat

  filter {
    name   = "name"
    values = ["RHEL-9*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# IAM role for EC2 instance
resource "aws_iam_role" "ec2_role" {
  name = "ec2-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

# Attach SSM managed policy
resource "aws_iam_role_policy_attachment" "ssm_policy" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Instance profile
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ec2-ssm-profile"
  role = aws_iam_role.ec2_role.name
}

# RHEL EC2 Instance
resource "aws_instance" "rhel" {
  ami                    = data.aws_ami.rhel.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.rhel_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name

  user_data = base64encode(<<-EOF
    #!/bin/bash
    yum update -y
    
    # Install AD join dependencies
    yum install -y realmd sssd oddjob oddjob-mkhomedir adcli samba-common-tools krb5-workstation
    
    # Create new user ssm-user2
    useradd -m ssm-user2
    echo "ssm-user2:P@ssw0rd123" | chpasswd
    usermod -aG wheel ssm-user2
    
    # Install SSM agent
    sudo dnf install -y https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/linux_amd64/amazon-ssm-agent.rpm
    systemctl enable amazon-ssm-agent
    systemctl start amazon-ssm-agent
    
    # Configure DNS to use AD DNS servers
    AD_DNS1="${aws_directory_service_directory.main.dns_ip_addresses[0]}"
    AD_DNS2="${aws_directory_service_directory.main.dns_ip_addresses[1]}"
    
    # Update resolv.conf
    cat > /etc/resolv.conf << EOL
nameserver $AD_DNS1
nameserver $AD_DNS2
search ${aws_directory_service_directory.main.name}
EOL
    
    # Join domain
    echo "P@ssw0rd123" | realm join -U Administrator ${aws_directory_service_directory.main.name}
    
    # Configure SSSD
    systemctl enable sssd
    systemctl start sssd
    
    # Allow domain users to login
    realm permit --all
  EOF
  )

  tags = {
    Name = "rhel-instance"
  }
}

# Outputs
output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_id" {
  value = aws_subnet.public.id
}

output "directory_id" {
  value = aws_directory_service_directory.main.id
}

output "rhel_instance_id" {
  value = aws_instance.rhel.id
}

output "rhel_public_ip" {
  value = aws_instance.rhel.public_ip
}
