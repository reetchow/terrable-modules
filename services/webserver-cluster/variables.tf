variable "server_port" {
  description = "Server port number"
  type = number
}

variable "cluster_name" {
  description = "The name of the cluster"
  type = string
}

variable "db_remote_state_bucket" {
  description = "S3 bucket for the database's remote state"
  type = string
}

variable "db_remote_state_key" {
  description = "S3 key for the database's remote state"
  type = string
}