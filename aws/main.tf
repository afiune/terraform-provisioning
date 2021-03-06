////////////////////////////////
// Terraform Provider AWS
terraform {
  required_version = ">= 0.12.0" 
}

provider "aws" {
  region                  = var.aws_region
  profile                 = var.aws_profile
  shared_credentials_file = file(var.credentials_file)
}

resource "random_id" "instance_id" {
  byte_length = 4
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "lacework_cloudtrail_bucket" {
  bucket        = "${var.bucket_name}-${random_id.instance_id.hex}"
  force_destroy = var.force_destroy_bucket
}

resource "aws_s3_bucket_policy" "lacework_cloudtrail_bucket_policy" {
  bucket = aws_s3_bucket.lacework_cloudtrail_bucket.id

  policy = <<POLICY
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AWSCloudTrailAclCheck20150319",
            "Effect": "Allow",
            "Principal": {
              "Service": "cloudtrail.amazonaws.com"
            },
            "Action": "s3:GetBucketAcl",
            "Resource": "arn:aws:s3:::${aws_s3_bucket.lacework_cloudtrail_bucket.id}"
        },
        {
            "Sid": "AWSCloudTrailWrite20150319",
            "Effect": "Allow",
            "Principal": {
              "Service": "cloudtrail.amazonaws.com"
            },
            "Action": "s3:PutObject",
            "Resource": "arn:aws:s3:::${aws_s3_bucket.lacework_cloudtrail_bucket.id}/AWSLogs/${data.aws_caller_identity.current.account_id}/*",
            "Condition": {
                "StringEquals": {
                    "s3:x-amz-acl": "bucket-owner-full-control"
                }
            }
        }
    ]
}
POLICY
}

resource "aws_sns_topic" "lacework_cloudtrail_sns_topic" {
  name = var.sns_topic_name
}

resource "aws_sqs_queue" "lacework_cloudtrail_sqs_queue" {
  name = var.sqs_queue_name
}

resource "aws_sns_topic_policy" "default" {
  arn = aws_sns_topic.lacework_cloudtrail_sns_topic.arn
  
  policy = <<POLICY
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AWSCloudTrailSNSPolicy20131101",
            "Effect": "Allow",
            "Principal": {
                "Service": "cloudtrail.amazonaws.com"
            },
            "Action": "SNS:Publish",
            "Resource": "${aws_sns_topic.lacework_cloudtrail_sns_topic.id}"
        }
    ]
}
POLICY
}

resource "aws_sqs_queue_policy" "lacework_sqs_queue_policy" {
  queue_url = aws_sqs_queue.lacework_cloudtrail_sqs_queue.id

  policy = <<POLICY
{
  "Version": "2012-10-17",
  "Id": "lacework_sqs_policy_${random_id.instance_id.hex}",
  "Statement": [
    {
      "Sid": "AllowLaceworkSNSTopicToSendMessage",
      "Effect": "Allow",
      "Principal": {
        "AWS": "*"
      },
      "Action": "SQS:SendMessage",
      "Resource": "${aws_sqs_queue.lacework_cloudtrail_sqs_queue.arn}",
      "Condition": {
        "ArnEquals": {
          "aws:SourceArn": "${aws_sns_topic.lacework_cloudtrail_sns_topic.id}"
        }
      }
    }
  ]
}
POLICY
}

resource "aws_sns_topic_subscription" "lacework_sns_topic_sub" {
  topic_arn = aws_sns_topic.lacework_cloudtrail_sns_topic.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.lacework_cloudtrail_sqs_queue.arn
}

resource "aws_cloudtrail" "lacework_cloudtrail" {
  name                          = var.cloudtrail_name
  s3_bucket_name                = aws_s3_bucket.lacework_cloudtrail_bucket.id
  include_global_service_events = true
  is_multi_region_trail         = true
  sns_topic_name                = aws_sns_topic.lacework_cloudtrail_sns_topic.id
  depends_on                    = [aws_s3_bucket_policy.lacework_cloudtrail_bucket_policy, aws_s3_bucket.lacework_cloudtrail_bucket]
}

resource "aws_iam_role" "lacework_iam_role" {
  name = var.iam_role_name
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": {
    "Effect": "Allow",
    "Principal": {
      "AWS": "arn:aws:iam::${var.lacework_aws_account_id}:root"
    },
    "Action": "sts:AssumeRole",
    "Condition": {
      "StringEquals": {
        "sts:ExternalId": "${var.external_id}"
      }
    }
  }
}
EOF
}

resource "aws_iam_role_policy_attachment" "security_audit_iam_role_policy_attachment" {
  role       = aws_iam_role.lacework_iam_role.name
  policy_arn = "arn:aws:iam::aws:policy/SecurityAudit"
}

resource "aws_iam_policy" "cross_account_policy" {
  name        = var.cross_account_policy_name
  description = "A cross account policy to allow Lacework to pull config and cloudtrail"

  policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Action": [
                "sqs:GetQueueAttributes",
                "sqs:GetQueueUrl",
                "sqs:DeleteMessage",
                "sqs:ReceiveMessage"
            ],
            "Resource": [
                "${aws_sqs_queue.lacework_cloudtrail_sqs_queue.arn}"
            ],
            "Effect": "Allow",
            "Sid": "ConsumeNotifications"
        },
        {
            "Condition": {
                "StringLike": {
                    "s3:prefix": [
                        "*AWSLogs/"
                    ]
                }
            },
            "Action": [
                "s3:ListBucket"
            ],
            "Resource": [
                "${aws_s3_bucket.lacework_cloudtrail_bucket.arn}"
            ],
            "Effect": "Allow",
            "Sid": "ListLogFiles"
        },
        {
            "Action": [
                "s3:Get*"
            ],
            "Resource": [
                "${aws_s3_bucket.lacework_cloudtrail_bucket.arn}/*"
            ],
            "Effect": "Allow",
            "Sid": "ReadLogFiles"
        },
        {
            "Action": [
                "iam:ListAccountAliases"
            ],
            "Resource": "*",
            "Effect": "Allow",
            "Sid": "GetAccountAlias"
        },
        {
            "Action": [
                "cloudtrail:DescribeTrails",
                "cloudtrail:GetTrailTopics",
                "cloudtrail:GetTrailStatus",
                "cloudtrail:ListPublicKeys",
                "s3:GetBucketAcl",
                "s3:GetBucketPolicy",
                "s3:ListAllMyBuckets",
                "s3:GetBucketLocation",
                "s3:GetBucketLogging",
                "sns:GetSubscriptionAttributes",
                "sns:GetTopicAttributes",
                "sns:ListSubscriptions",
                "sns:ListSubscriptionsByTopic",
                "sns:ListTopics"
            ],
            "Resource": "*",
            "Effect": "Allow",
            "Sid": "Debug"
        }
    ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "lacework_crossaccount_iam_role_policy_attachment" {
  role       = aws_iam_role.lacework_iam_role.name
  policy_arn = aws_iam_policy.cross_account_policy.arn 
}

provider "lacework" {
  account    = var.lacework_account
  api_key    = var.lacework_api_key
  api_secret = var.lacework_api_secret
}

resource "lacework_integration_aws_cfg" "default" {
  name = var.lacework_integration_config_name
  credentials {
      role_arn    = aws_iam_role.lacework_iam_role.arn
      external_id = var.external_id
  }
  depends_on = [
    aws_iam_role_policy_attachment.security_audit_iam_role_policy_attachment,
    aws_sns_topic_subscription.lacework_sns_topic_sub,
    aws_sqs_queue_policy.lacework_sqs_queue_policy,
    aws_iam_policy.cross_account_policy,
    aws_cloudtrail.lacework_cloudtrail
  ]
}

resource "lacework_integration_aws_ct" "default" {
  name      = var.lacework_integration_cloudtrail_name
  queue_url = aws_sqs_queue.lacework_cloudtrail_sqs_queue.id
  credentials {
      role_arn    = aws_iam_role.lacework_iam_role.arn
      external_id = var.external_id
  }
  depends_on = [
    aws_iam_role_policy_attachment.security_audit_iam_role_policy_attachment,
    aws_sns_topic_subscription.lacework_sns_topic_sub,
    aws_sqs_queue_policy.lacework_sqs_queue_policy,
    aws_iam_policy.cross_account_policy,
    lacework_integration_aws_cfg.default,
    aws_cloudtrail.lacework_cloudtrail
  ]
}
