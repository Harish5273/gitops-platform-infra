# =============================================================================
# main.tf - Self-Healing GitOps Platform (Day 1)
#
# SECTIONS (search for the number to jump):
#   1. DATA SOURCES ........ look up the Ubuntu AMI and availability zones
#   2. NETWORKING .......... VPC, internet gateway, subnet, route table
#   3. SECURITY GROUP ...... firewall rules (only YOUR IP can connect)
#   4. IAM ROLE ............ permissions the EC2 server gets (ECR, CloudWatch, SSM)
#   5. SSH KEY PAIR ........ uploads your PUBLIC key to AWS
#   6. EC2 INSTANCE ........ the k3s server itself
#   7. ELASTIC IP .......... the one fixed public IP address
# =============================================================================


# =============================================================================
# 1. DATA SOURCES (read-only lookups, they create nothing)
# =============================================================================

# All availability zones in the region (we use the first one)
data "aws_availability_zones" "available" {
  state = "available"
}

# Latest Ubuntu 22.04 LTS image published by Canonical (the official publisher)
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical's AWS account ID

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}


# =============================================================================
# 2. NETWORKING (public subnet only, NO NAT Gateway, so no extra cost)
# =============================================================================

# The private network that holds everything
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project_name}-vpc" }
}

# Door between the VPC and the internet
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${var.project_name}-igw" }
}

# One public subnet in the first availability zone
resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.public_subnet_cidr
  availability_zone = data.aws_availability_zones.available.names[0]

  # IMPORTANT: false = servers do NOT get an automatic public IP.
  # We attach a single Elastic IP instead (section 7), so we only pay for one.
  map_public_ip_on_launch = false

  tags = { Name = "${var.project_name}-public-subnet" }
}

# Routing rule: all internet-bound traffic goes through the internet gateway
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = { Name = "${var.project_name}-public-rt" }
}

# Attach that routing rule to the subnet
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}


# =============================================================================
# 3. SECURITY GROUP (the firewall)
#    Every inbound rule uses var.my_ip_cidr, so ONLY your IP can connect.
#    If you get timeouts, your ISP IP changed: update terraform.tfvars and apply.
# =============================================================================

resource "aws_security_group" "k3s" {
  name        = "${var.project_name}-sg"
  description = "Access to k3s node from admin IP only"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project_name}-sg" }
}



# HTTP: reach web apps on port 80
resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.k3s.id
  description       = "HTTP"
  cidr_ipv4         = var.my_ip_cidr
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

# Kubernetes API: lets kubectl on your laptop talk to k3s
resource "aws_vpc_security_group_ingress_rule" "k8s_api" {
  security_group_id = aws_security_group.k3s.id
  description       = "Kubernetes API"
  cidr_ipv4         = var.my_ip_cidr
  ip_protocol       = "tcp"
  from_port         = 6443
  to_port           = 6443
}

# NodePorts: where ArgoCD, Grafana and your app will be exposed
resource "aws_vpc_security_group_ingress_rule" "nodeports" {
  security_group_id = aws_security_group.k3s.id
  description       = "Kubernetes NodePorts"
  cidr_ipv4         = var.my_ip_cidr
  ip_protocol       = "tcp"
  from_port         = 30000
  to_port           = 32767
}

# Outbound: allow everything (package installs, image pulls, GitHub)
resource "aws_vpc_security_group_egress_rule" "all_out" {
  security_group_id = aws_security_group.k3s.id
  description       = "Allow all outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}


# =============================================================================
# 4. IAM ROLE (what the SERVER itself is allowed to do in AWS)
# =============================================================================

# Trust policy: only the EC2 service may use this role
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name               = "${var.project_name}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

# Permission 1: pull container images from ECR (read-only)
resource "aws_iam_role_policy_attachment" "ecr_read" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# Permission 2: send metrics and logs to CloudWatch
resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Permission 3: Session Manager (browser shell if SSH is blocked)
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Wrapper that lets an EC2 instance use the role above
resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.ec2.name
}


# =============================================================================
# 5. SSH KEY PAIR
#    Uploads only the PUBLIC key. The private key never leaves your laptop.
# =============================================================================

resource "aws_key_pair" "main" {
  key_name   = "${var.project_name}-key"
  public_key = file(pathexpand(var.public_key_path))
}


# =============================================================================
# 6. EC2 INSTANCE (the k3s server)
# =============================================================================

resource "aws_instance" "k3s" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type # t3.micro (Free Tier)
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.k3s.id]
  key_name               = aws_key_pair.main.key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  # NOTE: do NOT add "associate_public_ip_address = false" here.
  # Once the Elastic IP is attached, AWS reports the instance as having a public
  # IP, so Terraform saw "true -> false" and REBUILT the server on every apply.
  # The subnet already has map_public_ip_on_launch = false, which is enough.

  # Boot script (swap + base packages). Will move to Ansible on Day 2.
  # WARNING: changing user_data destroys and recreates the instance.
  user_data                   = file("${path.module}/user_data.sh")
  user_data_replace_on_change = true

  # Require IMDSv2 (blocks a common credential-theft attack)
  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  # 20 GB encrypted disk (Free Tier allows up to 30 GB)
  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gb
    encrypted             = true
    delete_on_termination = true
  }

  # Don't rebuild the server just because Canonical published a newer Ubuntu image
  lifecycle {
    ignore_changes = [ami]
  }

  tags = { Name = "${var.project_name}-k3s-node" }
}


# =============================================================================
# 7. ELASTIC IP (the ONE public IPv4 address, stays the same across reboots)
# =============================================================================

resource "aws_eip" "k3s" {
  domain     = "vpc"
  instance   = aws_instance.k3s.id
  depends_on = [aws_internet_gateway.igw]

  tags = { Name = "${var.project_name}-eip" }
}
