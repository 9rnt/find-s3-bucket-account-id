# Get current region and account id
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
# Create VPC
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "find-s3-account-vpc"
  }
}

# Create private subnet
resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "${data.aws_region.current.name}a"

  tags = {
    Name = "find-s3-account-private-subnet"
  }
}

# Create Private Route Table
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "private-rt"
  }
}

# Associate private subnet with private route table
resource "aws_route_table_association" "private_route_table_association" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# Create S3 Interface VPC Endpoint
resource "aws_vpc_endpoint" "s3_gateway" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway" 
  route_table_ids   = [aws_route_table.private.id]

  tags = {  
    Name = "s3-gateway-endpoint"
  }
}

# Create STS and CloudTrail Interface VPC Endpoints
## Security group for all interface endpoints
resource "aws_security_group" "interface_security_group" {
  name        = "${data.aws_region.current.name}-interface-security-group"
  description = "Security group for STS and CloudTrail gateway"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

## Create STS Interface VPC Endpoint
resource "aws_vpc_endpoint" "sts_gateway" {
  vpc_id             = aws_vpc.main.id
  service_name       = "com.amazonaws.${data.aws_region.current.name}.sts"
  vpc_endpoint_type  = "Interface" 
  security_group_ids = [aws_security_group.interface_security_group.id]
  subnet_ids         = [aws_subnet.private.id]

  private_dns_enabled = true

  tags = {  
    Name = "sts-gateway-endpoint"
  }
}

## Create CloudTrail Interface VPC Endpoint
resource "aws_vpc_endpoint" "cloudtrail_gateway" {
  vpc_id             = aws_vpc.main.id
  service_name       = "com.amazonaws.${data.aws_region.current.name}.cloudtrail"
  vpc_endpoint_type  = "Interface" 
  security_group_ids = [aws_security_group.interface_security_group.id]
  subnet_ids         = [aws_subnet.private.id]

  private_dns_enabled = true

  tags = {  
    Name = "cloudtrail-gateway-endpoint"
  }
}

# Security group for lambda function
resource "aws_security_group" "lambda_security_group" {
  name        = "${data.aws_region.current.name}-lambda-security-group"
  description = "Security group for lambda function"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
}

# Create lambda function
module "find_s3_account" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 7.20"

  function_name                     = "${data.aws_region.current.name}-find-s3-account"
  description                       = "Identify the account that owns the S3 bucket"
  handler                           = "handler.lambda_handler"
  runtime                           = local.runtime
  publish                           = true
  timeout                           = 300 # 5 minutes
  cloudwatch_logs_retention_in_days = 1
  architectures                     = ["arm64"]

  vpc_subnet_ids                     = [aws_subnet.private.id]
  vpc_security_group_ids             = [aws_security_group.lambda_security_group.id]
  attach_network_policy              = true

  # This path should be also defined as an artificats directory in gitlab-ci
  artifacts_dir = "${path.cwd}/builds"
  source_path   = "${path.module}/function"

  attach_policy_json = true
  policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [          
          # STS permissions for assuming roles
          "sts:AssumeRole",
          
          # CloudTrail permissions for looking up events
          "cloudtrail:LookupEvents"
        ]
        Resource = "*"
      }
    ]
  })

  environment_variables = {
    REGION                         = data.aws_region.current.name
    VPC_ID                         = aws_vpc.main.id
    S3_GATEWAY_ID                  = aws_vpc_endpoint.s3_gateway.id
    STS_GATEWAY_ENTRY_POINT        = aws_vpc_endpoint.sts_gateway.dns_entry[0].dns_name
    CLOUDTRAIL_GATEWAY_ENTRY_POINT = aws_vpc_endpoint.cloudtrail_gateway.dns_entry[0].dns_name
    BUCKET_NAME                    = var.bucket_name
    ROLE_ARN                       = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${data.aws_region.current.name}-find-s3-account-role-assumed-role"
    ROLE_NAME                      = "${data.aws_region.current.name}-find-s3-account-role-assumed-role"
  }
}

# Create IAM role to be assumed by lambda function
resource "aws_iam_role" "lambda_assumed_role" {
  name = "${data.aws_region.current.name}-find-s3-account-role-assumed-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "sts:AssumeRole"
        Principal = {
          AWS = module.find_s3_account.lambda_role_arn
        }
      }
    ]
  })
}

# Create IAM role policy
data "aws_iam_policy_document" "get_bucket_permissions" {
  # S3 permissions
  statement {
    actions   = ["s3:GetBucketAcl"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "policy-8675309"
  role = aws_iam_role.lambda_assumed_role.id
  policy = data.aws_iam_policy_document.get_bucket_permissions.json
}


# Create VPC endpoint policy for Interface endpoint
resource "aws_vpc_endpoint_policy" "s3_gateway_policy" {
  vpc_endpoint_id = aws_vpc_endpoint.s3_gateway.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Effect = "Allow"
          Action = "s3:*"
          Resource = "*"
          Principal = "*"
          Condition = {
            StringNotLikeIfExists = {
              "aws:PrincipalArn" = "*/${module.find_s3_account.lambda_role_name}"
            }
          }
        }
      ],
      [
        for pattern in local.wildcard_patterns : {
          Effect = "Allow"
          Action = ["s3:*"]
          Resource = "*"
          Principal = "*"
          Condition = {
            StringLike = {
              "aws:userid" = "*:${pattern.userid_wildcard}"
              "s3:ResourceAccount" = pattern.account_wildcard
            }
          }
        }
      ]
    )
  })
} 