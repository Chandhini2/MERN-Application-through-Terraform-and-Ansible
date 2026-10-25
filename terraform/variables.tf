variable "aws_region" {
  type    = string
  default = "ap-south-1"
}

variable "my_ip_cidr" {
  description = "Your public IP in CIDR form, e.g. 203.0.113.10/32"
  type        = string
}

variable "public_key_path" {
  type    = string
  default = "~/.ssh/travel_key.pub"
}

variable "web_instance_type" {
  type    = string
  default = "t3.small" # React build needs more than 1 GB RAM
}

variable "db_instance_type" {
  type    = string
  default = "t3.small"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  type    = string
  default = "10.0.1.0/24"
}

variable "private_subnet_cidr" {
  type    = string
  default = "10.0.2.0/24"
}
