variable "project_name"      { type = string }
variable "environment"       { type = string }
variable "vpc_id"            { type = string }
variable "subnet_ids"        { type = list(string) }
variable "security_group_id" { type = string }
variable "instance_class"    { type = string }
variable "db_name"           { type = string }
variable "db_username"       { type = string; sensitive = true }
variable "db_password"       { type = string; sensitive = true }
variable "multi_az"          { type = bool; default = false }
