#!/usr/bin/env python3
"""Create Cognito users from a JSON config.

Usage:
  python add-user.py --config config.json

Behavior:
- Supports one-to-many users in config.
- Uses config user_pool_id when present.
- If user_pool_id is missing, lists Cognito user pools and prompts selection by number.
- Creates users with temporary passwords (force reset on first login).
- Marks email as verified automatically.
"""

from __future__ import annotations

import argparse
import json
import os
import secrets
import string
import sys
from dataclasses import dataclass
from typing import Any, Dict, List, Optional

import boto3
from botocore.exceptions import BotoCoreError, ClientError


@dataclass
class UserSpec:
    username: str
    email: str
    temporary_password: str
    attributes: Dict[str, str]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Create Cognito users from config.")
    parser.add_argument(
        "--config",
        required=True,
        help="Path to JSON config file.",
    )
    parser.add_argument(
        "--region",
        default=None,
        help="AWS region override (otherwise config, AWS_REGION/AWS_DEFAULT_REGION, then us-east-1).",
    )
    return parser.parse_args()


def load_config(path: str) -> Dict[str, Any]:
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except FileNotFoundError:
        raise SystemExit(f"Config file not found: {path}")
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Invalid JSON in config file {path}: {exc}")

    if not isinstance(data, dict):
        raise SystemExit("Config root must be a JSON object.")
    return data


def resolve_region(args_region: Optional[str], config: Dict[str, Any]) -> str:
    return (
        args_region
        or config.get("region")
        or os.getenv("AWS_REGION")
        or os.getenv("AWS_DEFAULT_REGION")
        or "us-east-1"
    )


def list_user_pools(client: Any) -> List[Dict[str, str]]:
    pools: List[Dict[str, str]] = []
    next_token: Optional[str] = None

    while True:
        params: Dict[str, Any] = {"MaxResults": 60}
        if next_token:
            params["NextToken"] = next_token

        resp = client.list_user_pools(**params)
        for p in resp.get("UserPools", []):
            pools.append(
                {
                    "Id": p.get("Id", ""),
                    "Name": p.get("Name", ""),
                    "CreationDate": str(p.get("CreationDate", "")),
                }
            )

        next_token = resp.get("NextToken")
        if not next_token:
            break

    return pools


def select_user_pool_interactively(client: Any) -> str:
    pools = list_user_pools(client)
    if not pools:
        raise SystemExit("No Cognito user pools found in this region/account.")

    print("No user_pool_id provided in config. Select a Cognito User Pool:")
    for idx, pool in enumerate(pools, start=1):
        print(f"  {idx}. {pool['Name']} ({pool['Id']})")

    while True:
        choice = input("Enter pool number: ").strip()
        if not choice.isdigit():
            print("Please enter a number.")
            continue

        index = int(choice)
        if index < 1 or index > len(pools):
            print("Selection out of range.")
            continue

        selected = pools[index - 1]
        print(f"Selected: {selected['Name']} ({selected['Id']})")
        return selected["Id"]


def generate_temp_password(length: int = 16) -> str:
    # Meets common Cognito complexity requirements.
    upper = secrets.choice(string.ascii_uppercase)
    lower = secrets.choice(string.ascii_lowercase)
    digit = secrets.choice(string.digits)
    symbol = secrets.choice("!@#$%^&*()-_=+[]{}")

    alphabet = string.ascii_letters + string.digits + "!@#$%^&*()-_=+[]{}"
    rest = "".join(secrets.choice(alphabet) for _ in range(max(0, length - 4)))
    chars = list(upper + lower + digit + symbol + rest)
    secrets.SystemRandom().shuffle(chars)
    return "".join(chars)


def parse_users(config: Dict[str, Any]) -> List[UserSpec]:
    raw_users = config.get("users")
    if not isinstance(raw_users, list) or not raw_users:
        raise SystemExit("Config must contain a non-empty users array.")

    default_temp = config.get("default_temporary_password")
    users: List[UserSpec] = []

    for idx, item in enumerate(raw_users, start=1):
        if not isinstance(item, dict):
            raise SystemExit(f"users[{idx}] must be an object.")

        username = str(item.get("username", "")).strip()
        email = str(item.get("email", "")).strip()

        if not username:
            raise SystemExit(f"users[{idx}] is missing username.")
        if not email:
            raise SystemExit(f"users[{idx}] is missing email.")

        temp_password = str(item.get("temporary_password") or default_temp or "").strip()
        if not temp_password:
            temp_password = generate_temp_password()

        attrs = {
            "email": email,
            "email_verified": "true",
        }

        extra_attrs = item.get("attributes", {})
        if extra_attrs is not None:
            if not isinstance(extra_attrs, dict):
                raise SystemExit(f"users[{idx}].attributes must be an object if provided.")
            for key, val in extra_attrs.items():
                attrs[str(key)] = str(val)

        users.append(
            UserSpec(
                username=username,
                email=email,
                temporary_password=temp_password,
                attributes=attrs,
            )
        )

    return users


def create_user(client: Any, user_pool_id: str, user: UserSpec) -> None:
    attributes = [{"Name": k, "Value": v} for k, v in user.attributes.items()]

    try:
        client.admin_create_user(
            UserPoolId=user_pool_id,
            Username=user.username,
            TemporaryPassword=user.temporary_password,
            UserAttributes=attributes,
            MessageAction="SUPPRESS",
            DesiredDeliveryMediums=["EMAIL"],
            ForceAliasCreation=False,
        )
        print(
            f"Created user {user.username} ({user.email}) with temporary password: {user.temporary_password}"
        )
    except client.exceptions.UsernameExistsException:
        print(f"Skipped existing user: {user.username}")
    except ClientError as exc:
        raise SystemExit(f"Failed to create user {user.username}: {exc}")


def main() -> None:
    args = parse_args()
    config = load_config(args.config)
    region = resolve_region(args.region, config)

    try:
        cognito = boto3.client("cognito-idp", region_name=region)
    except (BotoCoreError, ClientError) as exc:
        raise SystemExit(f"Unable to initialize Cognito client: {exc}")

    user_pool_id = str(config.get("user_pool_id", "")).strip()
    if not user_pool_id:
        if not sys.stdin.isatty():
            raise SystemExit(
                "Config is missing user_pool_id and no interactive terminal is available for selection."
            )
        user_pool_id = select_user_pool_interactively(cognito)

    users = parse_users(config)
    print(f"Using region: {region}")
    print(f"Using user pool: {user_pool_id}")
    print(f"Users in config: {len(users)}")

    for user in users:
        create_user(cognito, user_pool_id, user)


if __name__ == "__main__":
    main()
