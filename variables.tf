variable "cluster_name" {
  type    = string
  default = "i2"
}

variable "cluster_version" {
  type    = string
  default = "1.22"
}

variable "cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "private_subnets" {
  type    = list(string)
  default = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "public_subnets" {
  type    = list(string)
  default = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]
}

variable "azs" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "efs_name" {
  type        = string
  description = "EFS service name"
  default     = "efs"
}

variable "aws_region" {
  type        = string
  description = "For AWS deployment - region name"
  default     = "us-east-1"
}