import logging
import boto3
import os
from datetime import datetime, timedelta, UTC
import json

# Environment variables
REGION = os.environ["REGION"]
VPC_ID = os.environ["VPC_ID"]
S3_GATEWAY_ID = os.environ["S3_GATEWAY_ID"]
STS_GATEWAY_ENTRY_POINT = os.environ["STS_GATEWAY_ENTRY_POINT"]
STS_GATEWAY_ENTRY_POINT_URL = f"https://{STS_GATEWAY_ENTRY_POINT}"
CLOUDTRAIL_GATEWAY_ENTRY_POINT = os.environ["CLOUDTRAIL_GATEWAY_ENTRY_POINT"]
CLOUDTRAIL_GATEWAY_ENTRY_POINT_URL = f"https://{CLOUDTRAIL_GATEWAY_ENTRY_POINT}"
BUCKET_NAME = os.environ["BUCKET_NAME"]
ROLE_ARN = os.environ["ROLE_ARN"]
ROLE_NAME = os.environ["ROLE_NAME"]
# Logging
log = logging.getLogger()
logHandler = logging.StreamHandler()
formatter = logging.Formatter('%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logHandler.setFormatter(formatter)
log.addHandler(logHandler)
log.setLevel(logging.INFO)

# Boto3 clients
sts = boto3.client("sts", endpoint_url=STS_GATEWAY_ENTRY_POINT_URL)
cloudtrail = boto3.client("cloudtrail", endpoint_url=CLOUDTRAIL_GATEWAY_ENTRY_POINT_URL)
cloudtrail_events = cloudtrail.get_paginator("lookup_events")


def wildcard_string(digit_position, digit):
    # e.g. wildcard_string(2, 7) returns "??7?????????"
    return f"{digit_position * '?'}{digit}{'?' * (11 - digit_position)}"


def wildcards():
    return [
        wildcard_string(digit_position, digit)
        for digit_position in range(12)
        for digit in range(10)
    ]

def wildcard_to_session_name(wildcard):
    return wildcard.replace("?", "-")

def make_s3_requests(bucket_name):
    for wildcard in wildcards():
        session_name = wildcard_to_session_name(wildcard)
        credentials = sts.assume_role(
            RoleArn=ROLE_ARN,
            RoleSessionName=session_name,
        )["Credentials"]

        wildcard_s3 = boto3.client("s3", region_name=REGION, aws_access_key_id=credentials["AccessKeyId"],
                                   aws_secret_access_key=credentials["SecretAccessKey"],
                                   aws_session_token=credentials["SessionToken"])

        log.info(f"Requesting {bucket_name} using session name {session_name}")
        try:
            wildcard_s3.get_bucket_acl(Bucket=bucket_name)
        except wildcard_s3.exceptions.ClientError:
            pass

def find_session_names_in_cloudtrail(vpc_endpoint_id, start_time, bucket_name):
    log.info("Finding session names which passed the VPC endpoint in CloudTrail...")
    session_names = set()
    while len(session_names) < 12 and datetime.now(UTC) < start_time + timedelta(minutes=10):
        for page in cloudtrail_events.paginate(
                LookupAttributes=[
                    {
                        "AttributeKey": "EventName",
                        "AttributeValue": "GetBucketAcl",
                    }
                ],
                StartTime=start_time - timedelta(minutes=1),
        ):
            for event in page["Events"]:
                body = json.loads(event["CloudTrailEvent"])
                if (
                        body.get("eventName") == "GetBucketAcl" and
                        body.get("requestParameters", {}).get("bucketName") == bucket_name and
                        body.get("userIdentity", {})
                                .get("sessionContext", {})
                                .get("sessionIssuer", {})
                                .get("userName") == ROLE_NAME
                ):
                    if body.get("vpcEndpointId") != vpc_endpoint_id:
                        raise RuntimeError(
                            f"Traffic not going through VPC endpoint ({vpc_endpoint_id}), check configuration")

                    session_name = body["userIdentity"]["principalId"].split(":")[1]

                    if session_name not in session_names:
                        print(f"Found {session_name} for {bucket_name} in CloudTrail")
                        session_names.add(session_name)

    return session_names

def account_id_from_session_names(session_names_seen):
    bucket_account_id = ["?"] * 12

    for session_name in session_names_seen:
        for i, session_name_char in enumerate(session_name):
            if session_name_char.isdigit():
                bucket_account_id[i] = session_name_char

    return "".join(bucket_account_id)

def lambda_handler(event, context):
    log.info("Received event: %s", event)

    start_time = datetime.now(UTC)
    make_s3_requests(BUCKET_NAME)
    session_names = find_session_names_in_cloudtrail(S3_GATEWAY_ID, start_time, BUCKET_NAME)
    account_id = account_id_from_session_names(session_names)

    return {
        "statusCode": 200,
        "body": json.dumps({
            "account_id": account_id
        })
    }

    
    
    