terraform {
  required_providers {
    rhcs = {
      source = "terraform-redhat/rhcs"
    }
  }
}

provider "aws" {
  region  = local.aws_config.region
  profile = local.aws_profile
}

provider "aws" {
  alias   = "personal"
  profile = local.aws_config.route53AWSProfile
  region  = local.aws_config.region
}

provider "aws" {
  alias   = "route53"
  profile = local.aws_config.route53AWSProfile
  region  = local.aws_config.region
}

provider "azurerm" {
  features {}
  subscription_id = local.azure_config.subscriptionId
  tenant_id       = local.azure_config.tenantId
}

provider "rhcs" {
  token = try(local.aws_config.rhcsToken, "")
}


