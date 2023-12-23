terraform {
  ### Uncomment code below after running on local backend to migrate to aws
  backend "s3" {
    bucket         = "tf-test-bucket3"
    key            = "tf-test/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "tf-test-table3"
    encrypt        = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

resource "aws_instance" "myInstance" {
  ami           = "ami-011899242bb902164" # Ubuntu 20.04 LTS // us-east-1
  instance_type = "t2.micro"
}

resource "aws_s3_bucket" "myBucket" {
  bucket        = "tf-test-bucket3"
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "tf_bucket_versioning" {
  bucket = aws_s3_bucket.myBucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "myBucket_crypto_conf" {
  bucket        = aws_s3_bucket.myBucket.bucket 
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_dynamodb_table" "myTable" {
  name         = "tf-test-table3"
  billing_mode = "PAY_PER_REQUEST" 
  hash_key     = "LockID"
  attribute {
    name = "LockID"
    type = "S"
  }
}
