#!/usr/bin/env bash
set -euo pipefail

# =========================
# User-configurable settings
# =========================

# GitHub target. Leave owner blank to auto-detect from PAT identity.
GITHUB_OWNER=""
GITHUB_REPO_NAME="CIC-AskUSDA-main"
GITHUB_REPO_VISIBILITY="private"  # private|public
GITHUB_DEFAULT_BRANCH="main"

# AWS target defaults. Account is always auto-detected from STS.
DEFAULT_AWS_REGION="us-east-1"
AWS_REGION_OVERRIDE=""

# IAM OIDC provider + role settings.
OIDC_PROVIDER_URL="https://token.actions.githubusercontent.com"
OIDC_PROVIDER_HOST="token.actions.githubusercontent.com"
OIDC_AUDIENCE="sts.amazonaws.com"
OIDC_THUMBPRINT="6938fd4d98bab03faadb97b34396831e3780aea1"
IAM_ROLE_NAME="GitHubActionsAskUSDADeployRole"

# Role policies to attach. Replace if you want tighter permissions.
IAM_ROLE_POLICY_ARNS=(
  "arn:aws:iam::aws:policy/AdministratorAccess"
)

# Extra repository variables frequently needed by CI/CD.
STACK_NAME="AskUSDA-Backend"
CRAWLER_STACK_NAME="AskUSDA-Crawler"
AMPLIFY_APP_NAME="AskUSDA-Frontend"

# =========================
# Runtime defaults
# =========================

PAT=""
SOURCE_DIR="$(pwd)"
DO_PUSH=true

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1" >&2; }
ok() { echo -e "${GREEN}[OK]${NC} $1" >&2; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
die() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: ./bootstrap.sh --pat <github_pat> [options]

Required:
  --pat <token>                 GitHub PAT with repo/admin permissions.

Optional:
  --owner <github_owner>        GitHub org/user that will own the repo.
  --repo <repo_name>            Repository name (default: ${GITHUB_REPO_NAME}).
  --region <aws_region>         AWS region (default: auto-detect, fallback ${DEFAULT_AWS_REGION}).
  --role-name <name>            IAM role name for GitHub OIDC.
  --source-dir <path>           Local git directory to configure/push (default: current dir).
  --visibility <private|public> GitHub repo visibility.
  --branch <branch>             Branch name to push and allow in trust policy (default: ${GITHUB_DEFAULT_BRANCH}).
  --amplify-app-name <name>     Amplify app name used by infra workflow (default: ${AMPLIFY_APP_NAME}).
  --no-push                     Create resources only; do not push local code.
  --help                        Show this message.

Behavior:
  - Idempotently creates/updates IAM OIDC provider and IAM role.
  - Idempotently creates the GitHub repo if it does not exist.
  - Idempotently creates/updates GitHub Actions variables.
  - Optionally configures git remote and pushes local code.
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

urlencode() {
  jq -nr --arg v "$1" '$v|@uri'
}

github_api() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"

  if [[ -n "$data" ]]; then
    curl -sS -X "$method" \
      -H "Authorization: Bearer ${PAT}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com${endpoint}" \
      -d "$data"
  else
    curl -sS -X "$method" \
      -H "Authorization: Bearer ${PAT}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com${endpoint}"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pat)
        PAT="${2:-}"
        shift 2
        ;;
      --owner)
        GITHUB_OWNER="${2:-}"
        shift 2
        ;;
      --repo)
        GITHUB_REPO_NAME="${2:-}"
        shift 2
        ;;
      --region)
        AWS_REGION_OVERRIDE="${2:-}"
        shift 2
        ;;
      --role-name)
        IAM_ROLE_NAME="${2:-}"
        shift 2
        ;;
      --source-dir)
        SOURCE_DIR="${2:-}"
        shift 2
        ;;
      --visibility)
        GITHUB_REPO_VISIBILITY="${2:-}"
        shift 2
        ;;
      --branch)
        GITHUB_DEFAULT_BRANCH="${2:-}"
        shift 2
        ;;
      --amplify-app-name)
        AMPLIFY_APP_NAME="${2:-}"
        shift 2
        ;;
      --no-push)
        DO_PUSH=false
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done

  [[ -n "$PAT" ]] || die "--pat is required"
  [[ "$GITHUB_REPO_VISIBILITY" == "private" || "$GITHUB_REPO_VISIBILITY" == "public" ]] || \
    die "--visibility must be private or public"
}

detect_aws_region() {
  if [[ -n "$AWS_REGION_OVERRIDE" ]]; then
    echo "$AWS_REGION_OVERRIDE"
    return
  fi

  if [[ -n "${AWS_REGION:-}" ]]; then
    echo "$AWS_REGION"
    return
  fi

  local configured
  configured="$(aws configure get region 2>/dev/null || true)"
  if [[ -n "$configured" && "$configured" != "None" ]]; then
    echo "$configured"
    return
  fi

  local token az
  token="$(curl -sS -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" || true)"
  if [[ -n "$token" ]]; then
    az="$(curl -sS -H "X-aws-ec2-metadata-token: ${token}" "http://169.254.169.254/latest/meta-data/placement/availability-zone" || true)"
  else
    az="$(curl -sS "http://169.254.169.254/latest/meta-data/placement/availability-zone" || true)"
  fi

  if [[ -n "$az" ]]; then
    echo "${az::-1}"
    return
  fi

  echo "$DEFAULT_AWS_REGION"
}

ensure_oidc_provider() {
  local existing_arn
  existing_arn="$(aws iam list-open-id-connect-providers \
    --query "OpenIDConnectProviderList[?contains(Arn, '${OIDC_PROVIDER_HOST}')].Arn | [0]" \
    --output text)"

  if [[ -z "$existing_arn" || "$existing_arn" == "None" ]]; then
    log "Creating IAM OIDC provider for GitHub Actions"
    existing_arn="$(aws iam create-open-id-connect-provider \
      --url "${OIDC_PROVIDER_URL}" \
      --client-id-list "${OIDC_AUDIENCE}" \
      --thumbprint-list "${OIDC_THUMBPRINT}" \
      --query 'OpenIDConnectProviderArn' \
      --output text)"
    ok "Created OIDC provider: ${existing_arn}"
  else
    ok "OIDC provider already exists: ${existing_arn}"
  fi

  local client_ids
  client_ids="$(aws iam get-open-id-connect-provider \
    --open-id-connect-provider-arn "$existing_arn" \
    --query 'ClientIDList' --output json)"

  if ! echo "$client_ids" | jq -e --arg aud "$OIDC_AUDIENCE" 'index($aud)' >/dev/null; then
    log "Adding missing audience ${OIDC_AUDIENCE} to OIDC provider"
    aws iam add-client-id-to-open-id-connect-provider \
      --open-id-connect-provider-arn "$existing_arn" \
      --client-id "$OIDC_AUDIENCE" >/dev/null
  fi

  [[ "$existing_arn" =~ ^arn:aws:iam::[0-9]{12}:oidc-provider/ ]] || \
    die "Resolved OIDC provider ARN is invalid: ${existing_arn}"

  echo "$existing_arn"
}

ensure_iam_role_for_oidc() {
  local account_id="$1"
  local owner="$2"
  local repo="$3"
  local oidc_arn="$4"

  local trust_doc
  trust_doc="$(jq -cn \
    --arg federated "$oidc_arn" \
    --arg aud "$OIDC_AUDIENCE" \
    --arg sub "repo:${owner}/${repo}:ref:refs/heads/${GITHUB_DEFAULT_BRANCH}" \
    '{
      Version: "2012-10-17",
      Statement: [
        {
          Effect: "Allow",
          Principal: { Federated: $federated },
          Action: "sts:AssumeRoleWithWebIdentity",
          Condition: {
            StringEquals: {
              "token.actions.githubusercontent.com:aud": $aud
            },
            StringLike: {
              "token.actions.githubusercontent.com:sub": $sub
            }
          }
        }
      ]
    }')"

  if aws iam get-role --role-name "$IAM_ROLE_NAME" >/dev/null 2>&1; then
    log "IAM role exists. Updating trust policy: ${IAM_ROLE_NAME}"
    aws iam update-assume-role-policy \
      --role-name "$IAM_ROLE_NAME" \
      --policy-document "$trust_doc" >/dev/null || die "Failed to update trust policy for role ${IAM_ROLE_NAME}"
  else
    log "Creating IAM role: ${IAM_ROLE_NAME}"
    aws iam create-role \
      --role-name "$IAM_ROLE_NAME" \
      --assume-role-policy-document "$trust_doc" \
      --description "OIDC role for GitHub Actions deployments" >/dev/null || die "Failed to create role ${IAM_ROLE_NAME}. Check trust policy values."
  fi

  local policy_arn
  for policy_arn in "${IAM_ROLE_POLICY_ARNS[@]}"; do
    if aws iam list-attached-role-policies --role-name "$IAM_ROLE_NAME" \
      --query "AttachedPolicies[?PolicyArn=='${policy_arn}'].PolicyArn | [0]" \
      --output text | grep -q "${policy_arn}"; then
      ok "Policy already attached: ${policy_arn}"
    else
      log "Attaching policy to role: ${policy_arn}"
      aws iam attach-role-policy --role-name "$IAM_ROLE_NAME" --policy-arn "$policy_arn" >/dev/null
    fi
  done

  aws iam get-role --role-name "$IAM_ROLE_NAME" --query 'Role.Arn' --output text
}

resolve_github_owner() {
  if [[ -n "$GITHUB_OWNER" ]]; then
    echo "$GITHUB_OWNER"
    return
  fi

  local me
  me="$(github_api GET "/user" | jq -r '.login')"
  [[ -n "$me" && "$me" != "null" ]] || die "Unable to resolve GitHub owner from PAT"
  echo "$me"
}

ensure_github_repo() {
  local owner="$1"
  local repo="$2"
  local vis="$3"

  local repo_status
  repo_status="$(curl -sS -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${PAT}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${owner}/${repo}")"

  if [[ "$repo_status" == "200" ]]; then
    ok "GitHub repo already exists: ${owner}/${repo}"
    return
  fi

  [[ "$repo_status" == "404" ]] || die "Unexpected GitHub API response checking repo (${repo_status})"

  local owner_type
  owner_type="$(github_api GET "/users/$(urlencode "$owner")" | jq -r '.type')"
  [[ -n "$owner_type" && "$owner_type" != "null" ]] || die "Unable to resolve GitHub owner type for ${owner}"

  local private_flag
  if [[ "$vis" == "private" ]]; then
    private_flag=true
  else
    private_flag=false
  fi

  local payload
  payload="$(jq -cn \
    --arg name "$repo" \
    --argjson private "$private_flag" \
    '{name: $name, private: $private, auto_init: false}')"

  if [[ "$owner_type" == "Organization" ]]; then
    log "Creating org repository: ${owner}/${repo}"
    github_api POST "/orgs/$(urlencode "$owner")/repos" "$payload" >/dev/null
  else
    log "Creating user repository: ${owner}/${repo}"
    github_api POST "/user/repos" "$payload" >/dev/null
  fi

  ok "Created GitHub repo: ${owner}/${repo}"
}

set_repo_variable() {
  local owner="$1"
  local repo="$2"
  local name="$3"
  local value="$4"

  local payload
  payload="$(jq -cn --arg n "$name" --arg v "$value" '{name: $n, value: $v}')"

  local create_status
  create_status="$(curl -sS -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Authorization: Bearer ${PAT}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${owner}/${repo}/actions/variables" \
    -d "$payload")"

  if [[ "$create_status" == "201" || "$create_status" == "204" ]]; then
    ok "Set repo variable: ${name}"
    return
  fi

  if [[ "$create_status" == "409" || "$create_status" == "422" ]]; then
    local patch_payload
    patch_payload="$(jq -cn --arg v "$value" '{value: $v}')"
    local patch_status
    patch_status="$(curl -sS -o /dev/null -w "%{http_code}" \
      -X PATCH \
      -H "Authorization: Bearer ${PAT}" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com/repos/${owner}/${repo}/actions/variables/${name}" \
      -d "$patch_payload")"
    [[ "$patch_status" == "204" ]] || die "Failed to update repo variable ${name} (HTTP ${patch_status})"
    ok "Updated repo variable: ${name}"
    return
  fi

  die "Failed to set repo variable ${name} (HTTP ${create_status})"
}

push_local_code_if_requested() {
  local owner="$1"
  local repo="$2"

  if [[ "$DO_PUSH" != "true" ]]; then
    warn "--no-push set. Skipping git remote configuration and push."
    return
  fi

  [[ -d "$SOURCE_DIR" ]] || die "--source-dir does not exist: ${SOURCE_DIR}"
  pushd "$SOURCE_DIR" >/dev/null

  if [[ ! -d .git ]]; then
    warn "No .git directory in ${SOURCE_DIR}. Skipping push."
    popd >/dev/null
    return
  fi

  local commit_count
  commit_count="$(git rev-list --count HEAD 2>/dev/null || echo "0")"
  if [[ "$commit_count" == "0" ]]; then
    warn "Local git repo has no commits. Skipping push."
    popd >/dev/null
    return
  fi

  local remote_url="https://github.com/${owner}/${repo}.git"
  if git remote get-url origin >/dev/null 2>&1; then
    git remote set-url origin "$remote_url"
  else
    git remote add origin "$remote_url"
  fi

  local local_branch
  local_branch="$(git rev-parse --abbrev-ref HEAD)"
  if [[ -z "$local_branch" || "$local_branch" == "HEAD" ]]; then
    local_branch="$GITHUB_DEFAULT_BRANCH"
    git checkout -B "$local_branch" >/dev/null 2>&1 || true
  fi

  local auth_url="https://x-access-token:${PAT}@github.com/${owner}/${repo}.git"
  log "Pushing local branch ${local_branch} to ${owner}/${repo}:${GITHUB_DEFAULT_BRANCH}"
  git push -u "$auth_url" "${local_branch}:${GITHUB_DEFAULT_BRANCH}" >/dev/null
  ok "Code push complete"

  popd >/dev/null
}

main() {
  parse_args "$@"

  require_cmd aws
  require_cmd curl
  require_cmd jq
  require_cmd git

  local aws_region
  aws_region="$(detect_aws_region)"
  export AWS_REGION="$aws_region"
  export AWS_DEFAULT_REGION="$aws_region"

  local aws_account_id
  aws_account_id="$(aws sts get-caller-identity --query 'Account' --output text)"
  [[ -n "$aws_account_id" && "$aws_account_id" != "None" ]] || die "Could not resolve AWS account from STS"

  local owner
  owner="$(resolve_github_owner)"

  log "Resolved AWS account: ${aws_account_id}"
  log "Resolved AWS region: ${aws_region}"
  log "Resolved GitHub owner: ${owner}"

  local oidc_provider_arn
  oidc_provider_arn="$(ensure_oidc_provider)"

  local role_arn
  role_arn="$(ensure_iam_role_for_oidc "$aws_account_id" "$owner" "$GITHUB_REPO_NAME" "$oidc_provider_arn")"
  ok "IAM role ready: ${role_arn}"

  ensure_github_repo "$owner" "$GITHUB_REPO_NAME" "$GITHUB_REPO_VISIBILITY"

  set_repo_variable "$owner" "$GITHUB_REPO_NAME" "AWS_ACCOUNT_ID" "$aws_account_id"
  set_repo_variable "$owner" "$GITHUB_REPO_NAME" "AWS_REGION" "$aws_region"
  set_repo_variable "$owner" "$GITHUB_REPO_NAME" "CDK_DEFAULT_ACCOUNT" "$aws_account_id"
  set_repo_variable "$owner" "$GITHUB_REPO_NAME" "CDK_DEFAULT_REGION" "$aws_region"
  set_repo_variable "$owner" "$GITHUB_REPO_NAME" "AWS_ROLE_TO_ASSUME" "$role_arn"
  set_repo_variable "$owner" "$GITHUB_REPO_NAME" "AWS_ROLE_ARN" "$role_arn"
  set_repo_variable "$owner" "$GITHUB_REPO_NAME" "DEPLOY_ROLE_NAME" "$IAM_ROLE_NAME"
  set_repo_variable "$owner" "$GITHUB_REPO_NAME" "STACK_NAME" "$STACK_NAME"
  set_repo_variable "$owner" "$GITHUB_REPO_NAME" "CRAWLER_STACK_NAME" "$CRAWLER_STACK_NAME"
  set_repo_variable "$owner" "$GITHUB_REPO_NAME" "AMPLIFY_APP_NAME" "$AMPLIFY_APP_NAME"
  set_repo_variable "$owner" "$GITHUB_REPO_NAME" "DEPLOY_BRANCH" "$GITHUB_DEFAULT_BRANCH"

  push_local_code_if_requested "$owner" "$GITHUB_REPO_NAME"

  cat <<EOF

Bootstrap complete.

GitHub Repository:
  ${owner}/${GITHUB_REPO_NAME}

AWS OIDC Role:
  ${role_arn}

GitHub Actions variables configured:
  AWS_ACCOUNT_ID
  AWS_REGION
  CDK_DEFAULT_ACCOUNT
  CDK_DEFAULT_REGION
  AWS_ROLE_TO_ASSUME
  AWS_ROLE_ARN
  DEPLOY_ROLE_NAME
  STACK_NAME
  CRAWLER_STACK_NAME
  AMPLIFY_APP_NAME
  DEPLOY_BRANCH

Next step in GitHub Actions workflow:
  permissions:
    id-token: write
    contents: read

  and use aws-actions/configure-aws-credentials with role-to-assume: \$\{\{ vars.AWS_ROLE_TO_ASSUME \}\}
EOF
}

main "$@"
