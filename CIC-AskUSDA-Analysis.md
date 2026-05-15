# CIC AskUSDA RAG Chatbot Analysis

## General Assessment
AskUSDA is a modern AWS-based RAG chatbot platform with a clear split between frontend, backend, crawler, and admin flows. The codebase is broadly well-structured and production-oriented. The most work was in porting the application into a GitHub deployment, aligning GitHub Actions with the actual runtime architecture, and hardening the chat path so it returns usable LLM output consistently.


## Observations By Area

### Code Summary
- The crawler code is modular and readable, with clear crawl phases and solid async Python structure.
- Lambda code is similarly well organized and uses AWS SDK v3 and environment-based configuration cleanly.
- The CDK stacks are well structured and follow good separation of concerns.
- The React frontend is modern and maintainable, though more tests would strengthen confidence.
- The original application and infrastructure is intertwined using AWS-native CloudFormation as the deployment mechanism.
- Overall code quality is strong, with the main gap being deeper test coverage rather than architecture.
- The documentation set is internally useful, and there are overlapping explanations of various architecture and operations
- Note: LLM evaluation was **not** performed during this integration phase.

### Conversion Summary
- The repository’s main blockers were workflow chaining, CDK compatibility, stage-prefixed API path handling, and smoke-test false negatives.
- Those blockers were addressed by splitting workflows, stabilizing Amplify resolution, adding nightly crawl controls, fixing crawler region alignment, and broadening Bedrock rerank permissions.
- The summary also captures the evolution of the smoke workflow and the later Bedrock fallback logic in the websocket handler.
- The key conclusion is that GitHub Actions became the primary deployment orchestration layer, with deterministic infra/app deploys and better post-deploy validation.
- Deployment is now a first-class concern, with GitHub Actions and AWS automation replacing a more manual setup path.

### Tuning Options
- The application exposes meaningful operational knobs for Lambda memory, timeout, crawler CPU and memory, crawl scope, and nightly delta crawl scheduling.
- The LLM behavior is tuned in the backend stack and websocket handler through model selection, retrieval quality, guardrails, and prompt structure.
- The nightly crawl gate prevents unnecessary refreshes when no crawl artifacts exist, which reduces noise and wasted runs.
- This file is essentially the control panel for the system: infrastructure, crawler behavior, and AI quality are all adjustable without redesigning the app.


## Conclusion
AskUSDA is a well-architected AWS RAG application that combines a Next.js frontend, WebSocket chat, Bedrock-powered retrieval and generation, DynamoDB persistence, ECS crawling, and Cognito-protected admin tooling. 
The main work done during the review was not to redesign the product, but to make it deployable, observable, and testable through GitHub Actions while preserving the application’s architecture and tuning flexibility. 
The final state is a coherent, reportable platform with a clear operational story: deploy infra, deploy the app, ingest knowledge, then validate the live chat path with functional tests that exercise the real WebSocket LLM flow.