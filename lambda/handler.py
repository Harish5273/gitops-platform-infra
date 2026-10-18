import json
import os

import boto3

ec2 = boto3.client("ec2")
INSTANCE_ID = os.environ["INSTANCE_ID"]


def handler(event, context):
    print(json.dumps(event))
    state = ec2.describe_instances(InstanceIds=[INSTANCE_ID])["Reservations"][0]["Instances"][0]["State"]["Name"]
    if state != "running":
        print(f"Instance {INSTANCE_ID} is {state}, not rebooting")
        return {"action": "skipped", "state": state}
    ec2.reboot_instances(InstanceIds=[INSTANCE_ID])
    print(f"Reboot requested for {INSTANCE_ID}")
    return {"action": "rebooted", "instance": INSTANCE_ID}
