# CIC Code Review Workspace

## AWS Architecture Overview (ASCII Diagram)

```
        +-------------------+
        |   GitHub Actions  |
        +---------+---------+
              |
              | OIDC AssumeRole
              v
        +-------------------+
        |    AWS IAM Role   |
        +---------+---------+
              |
    +-----------------+-------------------+
    |                                     |
    v                                     v
 +--------------+                  +-------------------+
 |   AWS CDK    |                  |   AWS Amplify     |
 | (Infra Code) |                  |  (Frontend Host)  |
 +------+-------+                  +---------+---------+
    |                                     |
    v                                     |
 +--------------+                             |
 | AWS Lambda   |                             |
 | (Backend)    |                             |
 +--------------+                             |
    |                                     |
    v                                     v
 +--------------+                  +-------------------+
 |   Crawler    |                  |   Next.js App     |
 +--------------+                  +-------------------+
```

---

## GitHub Actions CI/CD Flow (ASCII Diagram)

```
  +-------------------+
  |   Developer Push  |
  +---------+---------+
        |
        v
  +--------------------------+
  |   GitHub Repository      |
  +--------------------------+
        |
        v
  +--------------------------+
  |  Infra Workflow (CDK)    |
  |  - Deploys AWS infra     |
  |  - Creates Amplify app   |
  |  - Sets repo variables   |
  +--------------------------+
        |
        v
  +--------------------------+
  |  App Workflow            |
  |  - Deploys backend code  |
  |  - Builds frontend       |
  |  - Deploys to Amplify    |
  +--------------------------+
        |
        v
  +--------------------------+
  |   AWS Environment        |
  +--------------------------+
```

This repository is a wrapper workspace designed to encapsulate and automate the deployment and CI/CD of the underlying `CIC-AskUSDA-main` application using GitHub Actions and AWS infrastructure.

## Structure

- **CIC-AskUSDA-main/**: The main application codebase, including backend (CDK, Lambda, Crawler) and frontend (Next.js/Amplify) components.
- **bootstrap.sh**: Idempotent setup script for AWS IAM, OIDC, and GitHub repository integration.
- **.github/workflows/**: Contains GitHub Actions workflows for infrastructure and application deployment.
- **Other top-level files**: Documentation and helper scripts for workspace setup and usage.

## GitHub Workflows

This workspace uses two main GitHub Actions workflows:

1. **Infrastructure Deployment (`infra-deploy.yml`)**
   - Deploys AWS infrastructure using CDK.
   - Creates or discovers the Amplify app and branch.
   - Persists the Amplify App ID as a repository variable for use by the app workflow.
   - Authenticates to AWS via OIDC (no static secrets required).

2. **Application Deployment (`app-deploy.yml`)**
   - Deploys backend Lambda code and builds the frontend.
   - Deploys the frontend to AWS Amplify using the App ID from the infra workflow.
   - Fails fast if the Amplify App ID is not available.

Both workflows are triggered by pushes to the repository and are designed for a two-phase deployment pattern (infra first, then app).

## bootstrap.sh

The `bootstrap.sh` script is an idempotent setup utility intended to be run on an EC2 instance or local environment. It performs the following:

- Creates the AWS IAM OIDC provider and role for GitHub Actions.
- Creates the GitHub repository (if it does not exist).
- Sets required repository variables (e.g., OIDC role ARN, Amplify app name).
- Optionally pushes the local codebase to GitHub.

This script ensures that all AWS and GitHub prerequisites are in place for CI/CD to function securely and automatically.

## Purpose of This Wrapper

This top-level workspace provides a reproducible, automated way to deploy and manage the `CIC-AskUSDA-main` application via GitHub. It abstracts away the manual setup of AWS and GitHub integration, enabling seamless infrastructure and application delivery using modern DevOps best practices.

---

For more details, see the documentation in `CIC-AskUSDA-main/docs/` and the comments in the workflow YAML files.