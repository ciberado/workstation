variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "prefix" {
  description = "Prefix used to create the name of the resources"
  type        = string
  default     = "ws"
}

variable "vpc_addr_prefix" {
  description = "16 first bits of the VPC prefix, like 10.0"
  type        = string
  default     = "10.0"
}

variable "owner" {
  description = "The owner of the infrastructure."
  type        = string
}

variable "ws_instance_type" {
  description = "Instance type for the compute layer."
  type        = string
  default     = "t3.large"
}

variable "ws_az" {
  description = "AZ in which the vm will be created."
  type        = string
  default     = "b"
}