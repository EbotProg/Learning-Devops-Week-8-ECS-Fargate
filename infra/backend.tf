# Remote state: same bucket + lock table as Weeks 5/6, separate key for Week 8.
# Bucket and table already exist (bootstrapped manually in Week 5).
terraform {
  backend "s3" {
    bucket         = "ebotprog-terraform-state"
    key            = "week8/terraform.tfstate"
    region         = "eu-north-1"
    encrypt        = true
    dynamodb_table = "terraform-locks"
  }
}
