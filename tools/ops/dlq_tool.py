#!/usr/bin/env python3
"""dlq_tool.py — inspect and recover messages stuck in a BSS Platform SQS DLQ.

Every consumer queue in `modules/eventbridge` has a matching `*-dlq` — see
billing-service's OrderEventListener (B-10/B-11/B-12). This tool answers the
on-call question "billing stopped invoicing, is anything stuck in the DLQ?"
without hand-rolling `aws sqs` one-liners under pressure.

Subcommands:
    list                          list every *-dlq queue + how many messages are stuck
    peek    <queue-name>          read up to N messages WITHOUT removing them (safe, default)
    redrive <queue-name> --target <source-queue-name>
                                   move messages back to the original queue for reprocessing
    purge   <queue-name> --yes    delete all messages in the queue (irreversible — requires --yes)

Examples:
    python tools/ops/dlq_tool.py list
    python tools/ops/dlq_tool.py peek bss-dev-billing-orders-dlq
    python tools/ops/dlq_tool.py redrive bss-dev-billing-orders-dlq --target bss-dev-billing-orders --yes
"""

from __future__ import annotations

import argparse
import json
import sys

import boto3

REGION = "ap-southeast-1"


def get_queue_url(client, name: str) -> str:
    return client.get_queue_url(QueueName=name)["QueueUrl"]


def cmd_list(client, args: argparse.Namespace) -> int:
    queues = client.list_queues(QueueNamePrefix="bss-").get("QueueUrls", [])
    dlqs = [u for u in queues if u.rsplit("/", 1)[-1].endswith("-dlq")]
    if not dlqs:
        print("No *-dlq queues found (wrong --profile/region, or nothing deployed).")
        return 0
    print(f"{'Queue':<45} {'Messages':>10} {'In-flight':>10}")
    for url in dlqs:
        name = url.rsplit("/", 1)[-1]
        attrs = client.get_queue_attributes(
            QueueUrl=url,
            AttributeNames=[
                "ApproximateNumberOfMessages",
                "ApproximateNumberOfMessagesNotVisible",
            ],
        )["Attributes"]
        visible = attrs.get("ApproximateNumberOfMessages", "0")
        in_flight = attrs.get("ApproximateNumberOfMessagesNotVisible", "0")
        flag = " ⚠️" if int(visible) > 0 else ""
        print(f"{name:<45} {visible:>10} {in_flight:>10}{flag}")
    return 0


def cmd_peek(client, args: argparse.Namespace) -> int:
    url = get_queue_url(client, args.queue)
    resp = client.receive_message(
        QueueUrl=url,
        MaxNumberOfMessages=min(args.count, 10),
        VisibilityTimeout=5,  # short: message reappears almost immediately, nothing is "consumed"
        MessageAttributeNames=["All"],
        AttributeNames=["All"],
    )
    messages = resp.get("Messages", [])
    if not messages:
        print(f"{args.queue}: empty.")
        return 0
    for i, msg in enumerate(messages, 1):
        print(f"--- message {i}/{len(messages)} (MessageId={msg['MessageId']}) ---")
        try:
            body = json.loads(msg["Body"])
            print(json.dumps(body, indent=2))
        except json.JSONDecodeError:
            print(msg["Body"])
    print(f"\n{len(messages)} message(s) shown, none deleted (VisibilityTimeout=5s).")
    return 0


def cmd_redrive(client, args: argparse.Namespace) -> int:
    if not args.yes:
        print("Refusing to redrive without --yes (this moves messages, not a dry run).")
        return 1
    source_arn = client.get_queue_attributes(
        QueueUrl=get_queue_url(client, args.queue), AttributeNames=["QueueArn"]
    )["Attributes"]["QueueArn"]
    target_arn = client.get_queue_attributes(
        QueueUrl=get_queue_url(client, args.target), AttributeNames=["QueueArn"]
    )["Attributes"]["QueueArn"]
    # SQS-native redrive (no manual receive/send/delete loop, no risk of
    # duplicating or dropping a message on our own bug).
    resp = client.start_message_move_task(
        SourceArn=source_arn, DestinationArn=target_arn
    )
    print(f"Started move task: {resp['TaskHandle']}")
    print("Check progress with: aws sqs list-message-move-tasks --source-arn " + source_arn)
    return 0


def cmd_purge(client, args: argparse.Namespace) -> int:
    if not args.yes:
        print("Refusing to purge without --yes (this permanently deletes every message).")
        return 1
    client.purge_queue(QueueUrl=get_queue_url(client, args.queue))
    print(f"Purge requested for {args.queue}. SQS applies it within up to 60s.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--profile", default=None, help="AWS CLI profile name")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("list", help="list all *-dlq queues and their depth")

    p_peek = sub.add_parser("peek", help="read messages without removing them")
    p_peek.add_argument("queue")
    p_peek.add_argument("--count", type=int, default=5)

    p_redrive = sub.add_parser("redrive", help="move messages back to the source queue")
    p_redrive.add_argument("queue", help="the *-dlq queue name")
    p_redrive.add_argument("--target", required=True, help="the original (source) queue name")
    p_redrive.add_argument("--yes", action="store_true")

    p_purge = sub.add_parser("purge", help="delete all messages in a queue")
    p_purge.add_argument("queue")
    p_purge.add_argument("--yes", action="store_true")

    args = parser.parse_args()
    session = boto3.Session(profile_name=args.profile, region_name=REGION)
    client = session.client("sqs")

    handlers = {
        "list": cmd_list,
        "peek": cmd_peek,
        "redrive": cmd_redrive,
        "purge": cmd_purge,
    }
    return handlers[args.command](client, args)


if __name__ == "__main__":
    sys.exit(main())
