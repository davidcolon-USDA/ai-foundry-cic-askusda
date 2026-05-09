# Tuning and Configuration Reference

This table summarizes the main tunable parameters for the AskUSDA system, where to set them, and their purpose.

| Area                | Parameter/Setting      | Where to Set/Change                | Purpose/Notes |
|---------------------|-----------------------|-------------------------------------|--------------|
| **Infrastructure**  | Lambda memorySize     | backend/lib/backend-stack.ts        | Adjust Lambda RAM (MB) |
|                     | Lambda timeout        | backend/lib/backend-stack.ts        | Max Lambda execution time |
|                     | ECS memoryLimitMiB    | backend/lib/crawler-stack.ts        | Crawler container RAM (MB) |
|                     | ECS cpu               | backend/lib/crawler-stack.ts        | Crawler container CPU units |
|                     | Environment variables | backend/lib/backend-stack.ts, crawler-stack.ts | Passed to Lambda/ECS |
| **Crawler**         | SEED_URL              | Env var or urls.yaml                | Starting URL for crawl |
|                     | S3_BUCKET             | Env var or urls.yaml                | Output bucket |
|                     | JOB_ID                | Env var or urls.yaml                | Crawl job ID |
|                     | MAX_PAGES             | Env var or urls.yaml                | Max pages to crawl |
|                     | MAX_DEPTH             | Env var or urls.yaml                | Link-hop depth |
|                     | SCOPE_TYPE            | Env var or urls.yaml                | URL filtering (path, host, etc.) |
|                     | PDF_SCOPE             | Env var or urls.yaml                | PDF download scope |
|                     | DOC_SCOPE             | Env var or urls.yaml                | Doc download scope |
|                     | USE_BROWSER           | Env var or urls.yaml                | Browser mode (auto/on/off) |
|                     | MAX_CONCURRENT        | Env var or urls.yaml                | Parallel requests |
|                     | nightlyDeltaCrawlEnabled | Repo variable / CDK context       | Enable or disable the nightly delta crawl scheduler |
|                     | nightlyDeltaCrawlTime  | Repo variable / CDK context        | Nightly crawl time in HH:MM, America/Chicago (default 01:00) |
| **Backend Lambda**  | Table names, IDs      | backend/lib/backend-stack.ts        | Passed as env vars |
|                     | Model IDs, region     | backend/lib/backend-stack.ts        | Passed as env vars |
| **Crawler Jobs**    | Crawl jobs            | backend/crawler/urls.yaml           | Batch crawl definitions |
| **Workflows**       | initial-crawl.yml      | .github/workflows/initial-crawl.yml | Manual first-time/ad hoc crawl trigger |
|                     | wait_for_completion    | initial-crawl workflow input         | Wait for ECS crawl tasks and fail workflow on task errors |
|                     | poll_interval_seconds  | initial-crawl workflow input         | Poll interval for ECS task status checks |
|                     | poll_timeout_minutes   | initial-crawl workflow input         | Max time to wait for crawl task completion before timeout failure |
|                     | nightly delta crawl    | backend/lib/backend-stack.ts, repo variables | Scheduled delta crawl that skips when no crawled data exists |

## How It Is Tuned

- **LLM selection**: The chat model is set in `backend/lib/backend-stack.ts` and currently points to Nova Pro v1:0 for streaming generation.
- **Retrieval quality**: The WebSocket handler sets the number of retrieved results and reranking behavior in `backend/lambda/websocket-handler/index.js`.
- **Guardrail policy**: Content filtering is defined in `backend/lib/backend-stack.ts` and enabled in the WebSocket handler through `GUARDRAIL_ID` and `GUARDRAIL_VERSION` environment variables.
- **Prompt behavior**: The system prompt in `backend/lambda/websocket-handler/index.js` controls answer style, citation expectations, scope boundaries, and fallback messaging.
- **Crawler refresh**: First-time crawls use `.github/workflows/initial-crawl.yml`; nightly delta crawls are controlled by repo variables and the scheduler configuration in `backend/lib/backend-stack.ts`.
- **Nightly crawl gate**: The nightly trigger only forwards the crawl when prior crawl artifacts already exist under the crawler output prefix.

## Detailed Parameter Descriptions

### config.py (Crawler Configuration)
- **SEED_URL**: The starting URL for the crawler. Example: "https://www.usda.gov/snap".
- **S3_BUCKET**: The S3 bucket where crawled data is stored. Must match the Bedrock Knowledge Base data source.
- **JOB_ID**: A unique identifier for the crawl job. Auto-generated if not provided.
- **MAX_PAGES**: Maximum number of pages to scrape. Default: 500.
- **MAX_DEPTH**: Maximum link-hop depth. Default: 2.
- **SCOPE_TYPE**: URL filtering type (e.g., path, host, subdomains, all, none). Default: all.
- **PDF_SCOPE/DOC_SCOPE**: Scope for downloading PDFs and Office documents. Default: same as SCOPE_TYPE.
- **USE_BROWSER**: Browser mode for crawling (auto, on, off). Default: auto.
- **MAX_CONCURRENT**: Maximum concurrent requests. Default: 20.

### backend-stack.ts (Infrastructure Configuration)
- **Lambda memorySize**: Configures the memory allocated to Lambda functions. Example: 1024 MB for KBSyncHandler.
- **Lambda timeout**: Maximum execution time for Lambda functions. Example: 15 minutes for KBSyncHandler.
- **Environment Variables**: Passed to Lambda functions, such as KNOWLEDGE_BASE_ID, DATA_SOURCE_ID_V1, and CRAWLER_BUCKET.
- **Nightly crawl controls**: Set `nightlyDeltaCrawlEnabled` and `nightlyDeltaCrawlTime` through repo variables or CDK context to control the nightly delta scheduler.

### crawler-stack.ts (ECS Task Configuration)
- **memoryLimitMiB**: Memory allocated to the ECS Fargate task. Example: 4096 MB.
- **cpu**: CPU units allocated to the ECS Fargate task. Example: 2048.
- **Environment Variables**: Passed to the ECS container, such as USE_S3 and S3_BUCKET.

### Workflow Controls
- **Initial crawl workflow**: Use `.github/workflows/initial-crawl.yml` to run the first crawl or an operator-led recrawl from `urls.yaml`.
- **Initial crawl completion tracking**: Set `wait_for_completion=true` to keep the workflow open until all launched ECS crawl tasks stop.
- **Initial crawl polling cadence**: Set `poll_interval_seconds` to tune how often ECS task status is checked.
- **Initial crawl timeout**: Set `poll_timeout_minutes` to cap runtime and fail the workflow if tasks do not complete in time.
- **Nightly delta crawl**: Uses EventBridge Scheduler with a default run time of 1:00 AM America/Chicago and a boolean enable flag.
- **Delta gate behavior**: The nightly run only proceeds when crawl artifacts already exist under the crawler output prefix.

Refer to the respective files for additional inline comments and examples.

**How to Tune (Revised for EC2 with AWS CLI):**
- For infrastructure (memory, CPU, timeouts):
  1. SSH into the EC2 instance.
  2. Navigate to the project directory.
  3. Edit the CDK stack files (e.g., `backend-stack.ts`, `crawler-stack.ts`).
  4. Deploy changes using the AWS CLI:
     ```bash
     cdk deploy --all
     ```

- For crawler jobs:
  1. Edit `urls.yaml` to define new crawl jobs.
  2. Run the crawler locally or trigger it via ECS.

- For Lambda/backend configuration:
  1. Update environment variables in the CDK stack files.
  2. Redeploy the stack using the AWS CLI.

The EC2 instance with the proper IAM role and AWS CLI pre-configured simplifies deployment and tuning by eliminating the need for manual credential setup.
