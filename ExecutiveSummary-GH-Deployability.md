# Executive Summary: GitHub Deployability Remediation and CI/CD Augmentations

Date: 2026-05-09
Scope: AskUSDA repository deployment enablement and reliability hardening for GitHub Actions based infrastructure and application delivery.

## Objective
The goal was to make the original codebase reliably deployable through GitHub Actions, eliminate recurring pipeline failures, and improve post-deploy confidence with targeted smoke validation.

## Key Deployment Blockers Identified
1. Workflow execution and chaining reliability issues in GitHub Actions.
2. Infrastructure deployment failures caused by unsupported CDK Docker image asset properties.
3. Inconsistent runtime behavior for API route matching across stage-prefixed paths.
4. Smoke-test false negatives caused by route shape differences and business-rule expected responses.
5. Operational friction in initial account/repository setup for OIDC, variables, and regional defaults.

## Remediations Implemented to Restore Deployability
1. CI workflow architecture was standardized and hardened under root GitHub workflow paths.
2. Infrastructure-as-code fixes were applied in backend CDK to remove unsupported DockerImageAsset options, restoring successful synthesis/deploy behavior.
3. Development-only ECR image tag mutability handling was added in workflow automation, with explicit non-production intent documented in comments.
4. Backend route normalization was added in the admin Lambda to correctly handle stage-prefixed request paths (example: /prod/feedback), reducing API path mismatch failures.
5. Amplify app resolution and deployment flow were stabilized through explicit app-id discovery/fallback handling and branch-aware deployment logic.
6. A manual initial-crawl GitHub workflow was added for first-time or ad hoc knowledge-base population.
7. A nightly delta crawl scheduler was added and gated so it only fires when prior crawled content exists.
8. Crawler launch region alignment was fixed so KBSync ECS launches use the deployed crawler region, resolving `Invalid Region in ARN` failures.
9. Bedrock IAM permissions were patched to include `bedrock:Rerank` for the Amazon rerank model ARN on both the Knowledge Base role and the WebSocket Lambda runtime role, resolving chat-time `AccessDeniedException` failures raised by BedrockAgentRuntime reranking.

## CI/CD Augmentations Added
1. Bootstrap automation:
   - Added an idempotent bootstrap shell script to initialize OIDC role/provider, repository variables, and account-scoped deployment prerequisites.
   - Added support for PAT input and regional defaults, including us-east-1 behavior.

2. Workflow split and orchestration:
   - Implemented separate workflows for infrastructure deploy, application deploy, smoke test, and destroy operations.
   - Preserved independent manual execution while supporting post-deploy chaining behavior.

3. Smoke testing improvements:
   - Moved smoke checks into a dedicated workflow for independent reruns and cleaner failure isolation.
   - Added trigger behavior so workflow-file edits can trigger smoke runs via push path rules.
   - Updated job conditions so push-triggered smoke runs execute instead of being skipped.
   - Improved backend smoke validation semantics to avoid false negatives on expected data-state responses.

4. Observability and diagnostics quality:
   - Added clearer test-result messaging for what each smoke check validates.
   - Added explicit network timeout and curl transport error handling so connectivity failures are distinguishable from application responses.
   - Added crawler-side PDF failure classification and end-of-run failure summaries (including persisted summary fields in job artifacts) to make fetch/transport problems diagnosable.

## Explicit Deviation from Original Code
The following changes intentionally deviate from original crawler behavior to improve production operability and diagnostics:
1. Structured failure telemetry now covers both PDF and DOC downloads, including reason-level and domain-level rollups, sampled URLs, and a persisted `download_failure_summary.json` artifact.
2. Retry behavior now short-circuits for known non-retryable transport classes (for example malformed URL or DNS-resolution failures), and repeated HTTP 403 responses can trigger domain-level early-skip behavior to reduce noisy retries.
3. Lightweight scraper metrics now distinguish true page failures from non-page skips (for example non-HTML content-type or non-200 response), so operational dashboards do not overstate crawler failure rates.

5. Knowledge refresh controls:
   - Added operator-tunable crawl controls for nightly enablement and scheduled time.
   - Added a gate Lambda so the nightly delta crawl can skip empty runs instead of triggering needless ingestion.
   - Added optional Initial Crawl ECS polling controls so operators can have the workflow block until crawl tasks complete and surface task-level failures.

## Net Result
The repository is now deployable through GitHub Actions with significantly improved determinism:
- Infrastructure deployment path is functional after CDK compatibility fixes.
- Application deployment path is functional with stable Amplify resolution/deploy logic.
- Smoke tests can run independently, chain post-deploy, and trigger on direct smoke-workflow edits.
- Smoke outcomes now better differentiate transport failures, routing issues, and expected application-level validation responses.

## Strategic Value Delivered
1. Reduced manual intervention and troubleshooting time through automated bootstrap and standardized workflows.
2. Lowered deployment risk by removing failing IaC patterns and improving pipeline guardrails.
3. Increased confidence in releases via clearer, more reliable post-deploy verification.
4. Improved maintainability by documenting environment assumptions and non-production-only behavior directly in workflows.

## Remaining Considerations
1. If desired, smoke tests can be further split into separate frontend-only and backend-public endpoint jobs for even clearer diagnostics.
2. Protected endpoint checks can optionally validate expected 401/403 behavior to continuously assert Cognito enforcement.
3. A small set of integration fixtures could be added later to test feedback updates against known seeded conversations when deeper functional verification is needed.

## Recent Stabilization Changes (May 2026)
These items document deviations from the original code in the most recent commits and why each was necessary.

1. Broadened Knowledge Base role Bedrock rerank permissions in backend stack (`ccc5f10`).
   - What changed: `KnowledgeBaseRole` permission for Bedrock reranking was broadened to allow `bedrock:Rerank`/`bedrock:InvokeModel` with `resources: ['*']`.
   - Why necessary: BedrockAgentRuntime rerank calls produced runtime `AccessDeniedException` with model identifier/resource resolution behavior that did not consistently match a narrow ARN policy.

2. Removed temporary diagnostic workflows and scripts (`13d0e86`).
   - What changed: Deleted temporary `tmp-*` GitHub workflows and helper scripts used during incident diagnostics.
   - Why necessary: Temporary assets were intentionally short-lived and created operational noise after root-cause isolation; cleanup reduced maintenance risk and confusion in Actions.

3. Reworked smoke workflow identity and trigger behavior (`f9666d0`, `bff9c15`, `c5776c0`, `eebf029`).
   - What changed: Smoke workflow was renamed/recreated as `.github/workflows/askusda-smoke.yml`, simplified to dispatch/push behavior, and aligned to the known-good `initial-crawl` template baseline (`checkout`, `setup-python`, explicit AWS env wiring, typed input).
   - Why necessary: GitHub Actions was registering smoke by path-like metadata and showing unreliable dispatch behavior; recreating and simplifying the workflow improved registration consistency and repeatability.

4. Added Bedrock generation model identifier fallback logic in websocket chat handler (`f2af8b2`).
   - What changed: The websocket handler now tries an ordered set of model identifiers (env-configured first, then known profile/id variants) and falls back only on invalid-model validation errors.
   - Why necessary: Chat requests were failing with BedrockRuntime 400 `Invalid request. The provided model identifier is invalid.` in environments where a single hardcoded identifier form was not accepted.

5. Added Knowledge Base retrieval fallback when rerank model identifier is invalid (`284ab44`).
   - What changed: KB retrieval now retries without reranking when BedrockAgentRuntime returns model-identifier validation errors for rerank configuration.
   - Why necessary: BedrockAgentRuntime rerank identifier validation failures were causing full chat request failure; this fallback preserves response availability while still using KB retrieval.

6. Added admin login forgot-password/reset-password flow in frontend auth (`May 2026`).
   - What changed: Added Cognito `ForgotPassword` and `ConfirmForgotPassword` support in admin auth context and corresponding `/admin` UI states for requesting verification codes and completing resets.
   - Why necessary: Original admin login UX did not provide a self-service password recovery path, causing operational friction and support overhead for locked-out users.
