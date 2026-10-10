variable "aws_region" {
  type    = string
  default = "ap-south-1"
}

variable "project_name" {
  type    = string
  default = "gitops-platform"
}

variable "instance_type" {
  type    = string
  default = "t3.small"
}

variable "my_ip_cidr" {
  description = "Your public IP in CIDR form, e.g. 103.21.4.5/32"
  type        = string

  validation {
    condition     = can(cidrhost(var.my_ip_cidr, 0)) && var.my_ip_cidr != "0.0.0.0/0"
    error_message = "Provide a valid CIDR like 1.2.3.4/32 and do NOT use 0.0.0.0/0."
  }
}

variable "public_key_path" {
  type    = string
  default = "~/.ssh/gitops-platform.pub"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  type    = string
  default = "10.0.1.0/24"
}

variable "root_volume_size_gb" {
  type    = number
  default = 20
}
