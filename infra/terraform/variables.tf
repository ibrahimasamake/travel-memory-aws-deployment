
variable "aws_region" {
  description = "AWS region for our VPC"
  type        = string
  default     = "ap-south-1"
}

variable "vpc_cidr" {
  description = "CIDR range for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR range for the public subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "public_2_subnet_cidr" {
  description = "CIDR range for the public 2 subnet"
  type        = string
  default     = "10.0.3.0/24"

}
variable "private_subnet_cidr" {
  description = "CIDR range for the private subnet"
  type        = string
  default     = "10.0.2.0/24"
}

variable "private_2_subnet_cidr" {
  description = "CIDR range for the private subnet 2"
  type        = string
  default     = "10.0.6.0/24"
}


variable "ssh_allowed_cidr" {
  description = "Your public IPv4 address in CIDR notation, for SSH"
  type        = string
}

variable "key_name" {
  description = "Name of the existing AWS EC2 key pair"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for our learning project"
  type        = string
  default     = "t3.micro"
}


variable "frontend_instance_type" {
  type    = string
  default = "t3.micro"
}

variable "backend_instance_type" {
  type    = string
  default = "t3.micro"
}


variable "frontend_ami_id" {
  description = "Existing Ubuntu AMI for the frontend"
  type        = string
}

variable "backend_ami_id" {
  description = "Existing Ubuntu AMI for the backend"
  type        = string
}

variable "backend_port_api" {
  description = "Port on which the backend application listens"
  type        = number
  default     = 3001
}


variable "backend_port_ssh" {
  description = "Port ssh on which the backend application listens"
  type        = number
  default     = 22
}

variable "acm_certificate_arn" {
  description = "ARN of the issued ACM certificate for the custom domain (HTTPS listener)"
  type        = string
}