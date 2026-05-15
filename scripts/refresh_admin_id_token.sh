#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Refresh ADMIN_DEBUG_ID_TOKEN GitHub secret for AskUSDA diagnostics.

Required:
  --username <admin_username_or_email>
  --repo <owner/repo>            (unless inferable from git remote)

Optional:
  --password <password>          (if omitted, you will be prompted securely)
  --pat <github_pat>             (or set GITHUB_PAT env var)
  --stack-name <name>            default: AskUSDA-Backend
  --region <aws_region>          default: AWS_REGION/AWS_DEFAULT_REGION/IMDS/us-east-1
  --client-id <cognito_client_id>
  --client-secret <value>        optional Cognito app client secret
  --user-pool-id <cognito_user_pool_id>
  --auth-flow <flow>             default: auto
                                 options: auto|user|admin
  --secret-name <name>           default: ADMIN_DEBUG_ID_TOKEN
  --debug                        print Cognito auth diagnostics

Examples:
  ./scripts/refresh_admin_id_token.sh \
    --username admin@example.com \
    --repo davidcolon-USDA/ai-foundry-cic-askusda

  ./scripts/refresh_admin_id_token.sh \
    --username admin@example.com \
    --password 'YourPasswordHere' \
    --repo davidcolon-USDA/ai-foundry-cic-askusda \
    --pat "$GITHUB_PAT" \
    --region us-east-1
USAGE
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

json_extract() {
  local json="$1"
  local key="$2"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r "$key // empty"
  else
    printf '%s' "$json" | sed -n "s/.*\"${key#*.}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n1
  fi
}

get_imds_token() {
  curl -fsS -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" || true
}

get_region_from_imds() {
  local token="$1"
  if [ -n "$token" ]; then
    curl -fsS -H "X-aws-ec2-metadata-token: ${token}" \
      "http://169.254.169.254/latest/dynamic/instance-identity/document" \
      | sed -n 's/.*"region"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' || true
  else
    curl -fsS "http://169.254.169.254/latest/dynamic/instance-identity/document" \
      | sed -n 's/.*"region"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' || true
  fi
}

infer_repo_from_git() {
  local url repo
  if ! command -v git >/dev/null 2>&1; then
    return 0
  fi

  url="$(git remote get-url origin 2>/dev/null || true)"
  if [ -z "$url" ]; then
    return 0
  fi

  # Supports https://github.com/owner/repo(.git) and git@github.com:owner/repo(.git)
  repo="$(printf '%s' "$url" | sed -E 's#^https?://([^@/]+@)?github.com/##; s#^git@github.com:##; s#\.git$##')"
  if printf '%s' "$repo" | grep -q '/'; then
    printf '%s' "$repo"
  fi
}

stack_output() {
  local stack_name="$1"
  local region="$2"
  local key="$3"
  local value

  value="$(aws cloudformation describe-stacks \
    --stack-name "$stack_name" \
    --region "$region" \
    --query "Stacks[0].Outputs[?OutputKey=='${key}'].OutputValue | [0]" \
    --output text 2>/dev/null || true)"

  if [ "$value" = "None" ]; then
    value=""
  fi
  printf '%s' "$value"
}

describe_user_pool_client_secret() {
  local region="$1"
  local user_pool_id="$2"
  local client_id="$3"

  aws cognito-idp describe-user-pool-client \
    --region "$region" \
    --user-pool-id "$user_pool_id" \
    --client-id "$client_id" \
    --query 'UserPoolClient.ClientSecret' \
    --output text 2>/dev/null || true
}

build_secret_hash() {
  local username="$1"
  local client_id="$2"
  local client_secret="$3"

  printf '%s' "${username}${client_id}" \
    | openssl dgst -sha256 -hmac "$client_secret" -binary \
    | openssl enc -base64
}

AUTH_DIAGNOSTIC=""
AUTH_RESULT_TOKEN=""

call_cognito_user_flow() {
  local client_id="$1"
  local username="$2"
  local password="$3"
  local secret_hash="$4"
  local region="$5"

  local output status
  set +e
  if [ -n "$secret_hash" ]; then
    output="$(aws cognito-idp initiate-auth \
      --region "$region" \
      --auth-flow USER_PASSWORD_AUTH \
      --client-id "$client_id" \
      --auth-parameters "USERNAME=${username},PASSWORD=${password},SECRET_HASH=${secret_hash}" \
      --output json 2>&1)"
  else
    output="$(aws cognito-idp initiate-auth \
      --region "$region" \
      --auth-flow USER_PASSWORD_AUTH \
      --client-id "$client_id" \
      --auth-parameters "USERNAME=${username},PASSWORD=${password}" \
      --output json 2>&1)"
  fi
  status=$?
  set -e

  if [ $status -ne 0 ]; then
    AUTH_DIAGNOSTIC="USER_PASSWORD_AUTH failed: ${output}"
    AUTH_RESULT_TOKEN=""
    return 0
  fi

  local token challenge
  token="$(printf '%s' "$output" | sed -n 's/.*"IdToken"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  challenge="$(printf '%s' "$output" | sed -n 's/.*"ChallengeName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"

  if [ -n "$token" ]; then
    AUTH_DIAGNOSTIC="USER_PASSWORD_AUTH succeeded."
    AUTH_RESULT_TOKEN="$token"
    return 0
  fi

  if [ -n "$challenge" ]; then
    AUTH_DIAGNOSTIC="USER_PASSWORD_AUTH returned challenge: ${challenge}."
  else
    AUTH_DIAGNOSTIC="USER_PASSWORD_AUTH returned no IdToken and no challenge. Raw: ${output}"
  fi
  AUTH_RESULT_TOKEN=""
}

call_cognito_admin_flow() {
  local user_pool_id="$1"
  local client_id="$2"
  local username="$3"
  local password="$4"
  local region="$5"
  local secret_hash="$6"

  local output status
  set +e
  if [ -n "$secret_hash" ]; then
    output="$(aws cognito-idp admin-initiate-auth \
      --region "$region" \
      --user-pool-id "$user_pool_id" \
      --client-id "$client_id" \
      --auth-flow ADMIN_USER_PASSWORD_AUTH \
      --auth-parameters "USERNAME=${username},PASSWORD=${password},SECRET_HASH=${secret_hash}" \
      --output json 2>&1)"
  else
    output="$(aws cognito-idp admin-initiate-auth \
      --region "$region" \
      --user-pool-id "$user_pool_id" \
      --client-id "$client_id" \
      --auth-flow ADMIN_USER_PASSWORD_AUTH \
      --auth-parameters "USERNAME=${username},PASSWORD=${password}" \
      --output json 2>&1)"
  fi
  status=$?
  set -e

  if [ $status -ne 0 ]; then
    AUTH_DIAGNOSTIC="ADMIN_USER_PASSWORD_AUTH failed: ${output}"
    AUTH_RESULT_TOKEN=""
    return 0
  fi

  local token challenge
  token="$(printf '%s' "$output" | sed -n 's/.*"IdToken"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  challenge="$(printf '%s' "$output" | sed -n 's/.*"ChallengeName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"

  if [ -n "$token" ]; then
    AUTH_DIAGNOSTIC="ADMIN_USER_PASSWORD_AUTH succeeded."
    AUTH_RESULT_TOKEN="$token"
    return 0
  fi

  if [ -n "$challenge" ]; then
    AUTH_DIAGNOSTIC="ADMIN_USER_PASSWORD_AUTH returned challenge: ${challenge}."
  else
    AUTH_DIAGNOSTIC="ADMIN_USER_PASSWORD_AUTH returned no IdToken and no challenge. Raw: ${output}"
  fi
  AUTH_RESULT_TOKEN=""
}

USERNAME=""
PASSWORD=""
REPO=""
GITHUB_PAT="${GITHUB_PAT:-}"
STACK_NAME="AskUSDA-Backend"
REGION=""
CLIENT_ID=""
CLIENT_SECRET=""
USER_POOL_ID=""
AUTH_FLOW="auto"
SECRET_NAME="ADMIN_DEBUG_ID_TOKEN"
DEBUG="false"

while [ $# -gt 0 ]; do
  case "$1" in
    --username)
      USERNAME="${2:-}"
      shift 2
      ;;
    --password)
      PASSWORD="${2:-}"
      shift 2
      ;;
    --repo)
      REPO="${2:-}"
      shift 2
      ;;
    --pat)
      GITHUB_PAT="${2:-}"
      shift 2
      ;;
    --stack-name)
      STACK_NAME="${2:-}"
      shift 2
      ;;
    --region)
      REGION="${2:-}"
      shift 2
      ;;
    --client-id)
      CLIENT_ID="${2:-}"
      shift 2
      ;;
    --client-secret)
      CLIENT_SECRET="${2:-}"
      shift 2
      ;;
    --user-pool-id)
      USER_POOL_ID="${2:-}"
      shift 2
      ;;
    --auth-flow)
      AUTH_FLOW="${2:-}"
      shift 2
      ;;
    --secret-name)
      SECRET_NAME="${2:-}"
      shift 2
      ;;
    --debug)
      DEBUG="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

require_cmd aws
require_cmd gh
require_cmd curl
require_cmd openssl

if [ -z "$USERNAME" ]; then
  echo "Missing required --username" >&2
  usage
  exit 1
fi

if [ -z "$REPO" ]; then
  REPO="$(infer_repo_from_git || true)"
fi

if [ -z "$REPO" ]; then
  echo "Missing required --repo (and unable to infer from git remote)." >&2
  usage
  exit 1
fi

if [ -z "$PASSWORD" ]; then
  read -r -s -p "Enter Cognito password for ${USERNAME}: " PASSWORD
  echo
fi

if [ -z "$GITHUB_PAT" ]; then
  read -r -s -p "Enter GitHub PAT (repo + workflow scopes): " GITHUB_PAT
  echo
fi

if [ -z "$REGION" ]; then
  REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
fi

if [ -z "$REGION" ]; then
  IMDS_TOKEN="$(get_imds_token)"
  REGION="$(get_region_from_imds "$IMDS_TOKEN")"
fi

if [ -z "$REGION" ]; then
  REGION="us-east-1"
fi

echo "Using region: ${REGION}"
echo "Using stack: ${STACK_NAME}"
echo "Using repo: ${REPO}"

if [ -z "$CLIENT_ID" ]; then
  CLIENT_ID="$(stack_output "$STACK_NAME" "$REGION" "AdminUserPoolClientId")"
fi

if [ -z "$USER_POOL_ID" ]; then
  USER_POOL_ID="$(stack_output "$STACK_NAME" "$REGION" "AdminUserPoolId")"
fi

if [ -z "$CLIENT_SECRET" ] && [ -n "$USER_POOL_ID" ] && [ -n "$CLIENT_ID" ]; then
  CLIENT_SECRET="$(describe_user_pool_client_secret "$REGION" "$USER_POOL_ID" "$CLIENT_ID")"
  if [ "$CLIENT_SECRET" = "None" ]; then
    CLIENT_SECRET=""
  fi
fi

if [ -z "$CLIENT_ID" ]; then
  echo "Failed to resolve Cognito client ID. Pass --client-id or verify stack outputs." >&2
  exit 1
fi

ID_TOKEN=""
SECRET_HASH=""
if [ -n "$CLIENT_SECRET" ]; then
  SECRET_HASH="$(build_secret_hash "$USERNAME" "$CLIENT_ID" "$CLIENT_SECRET")"
fi

case "$AUTH_FLOW" in
  user)
    call_cognito_user_flow "$CLIENT_ID" "$USERNAME" "$PASSWORD" "$SECRET_HASH" "$REGION"
    ID_TOKEN="$AUTH_RESULT_TOKEN"
    ;;
  admin)
    if [ -z "$USER_POOL_ID" ]; then
      echo "--auth-flow admin requires user pool ID. Pass --user-pool-id or ensure stack output exists." >&2
      exit 1
    fi
    call_cognito_admin_flow "$USER_POOL_ID" "$CLIENT_ID" "$USERNAME" "$PASSWORD" "$REGION" "$SECRET_HASH"
    ID_TOKEN="$AUTH_RESULT_TOKEN"
    ;;
  auto)
    call_cognito_user_flow "$CLIENT_ID" "$USERNAME" "$PASSWORD" "$SECRET_HASH" "$REGION"
    ID_TOKEN="$AUTH_RESULT_TOKEN"
    if [ -z "$ID_TOKEN" ] || [ "$ID_TOKEN" = "None" ] || [ "$ID_TOKEN" = "null" ]; then
      if [ -z "$USER_POOL_ID" ]; then
        echo "USER_PASSWORD_AUTH did not return a token and user pool ID is unavailable for admin flow fallback." >&2
        if [ "$DEBUG" = "true" ] && [ -n "$AUTH_DIAGNOSTIC" ]; then
          echo "Diagnostics: ${AUTH_DIAGNOSTIC}" >&2
        fi
        exit 1
      fi
      call_cognito_admin_flow "$USER_POOL_ID" "$CLIENT_ID" "$USERNAME" "$PASSWORD" "$REGION" "$SECRET_HASH"
      ID_TOKEN="$AUTH_RESULT_TOKEN"
    fi
    ;;
  *)
    echo "Invalid --auth-flow value: ${AUTH_FLOW} (use auto|user|admin)" >&2
    exit 1
    ;;
esac

if [ -z "$ID_TOKEN" ] || [ "$ID_TOKEN" = "None" ] || [ "$ID_TOKEN" = "null" ]; then
  echo "Failed to generate IdToken. Verify username/password, app client auth flow, and Cognito settings." >&2
  if [ "$DEBUG" = "true" ] && [ -n "$AUTH_DIAGNOSTIC" ]; then
    echo "Diagnostics: ${AUTH_DIAGNOSTIC}" >&2
  fi
  exit 1
fi

# Update the GitHub Actions repository secret with PAT-based auth.
GH_TOKEN="$GITHUB_PAT" gh secret set "$SECRET_NAME" --repo "$REPO" --body "$ID_TOKEN"

echo "Updated GitHub secret '${SECRET_NAME}' for ${REPO}."
echo "Token generated from client ${CLIENT_ID}."
if [ -n "$USER_POOL_ID" ]; then
  echo "User pool: ${USER_POOL_ID}"
fi
