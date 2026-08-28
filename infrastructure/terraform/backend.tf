terraform {
  backend "s3" {
    bucket         = "octabyteai-terraform-state"
    key            = "octabyteai/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "octabyteai-terraform-locks"
  }
}
