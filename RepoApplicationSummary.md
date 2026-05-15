## Architecture Review & Best Practices Rating

**Soundness:**
The AskUSDA architecture is robust and aligns well with current best practices for RAG chatbot systems:

- **Data Pipeline:** Uses a dedicated web crawler to index authoritative sources (USDA.gov, farmers.gov), ensuring high-quality, up-to-date knowledge.
- **Vector Store:** Employs Amazon S3 Vectors for scalable, managed embedding storage, which is a recommended approach for production RAG systems.
- **Retrieval & Generation:** Integrates Amazon Bedrock for both retrieval (Titan Embed v2) and generation (Nova Pro), leveraging state-of-the-art models and streaming responses for a responsive user experience.
- **Serverless & Scalable:** Fully serverless backend (Lambda, API Gateway, DynamoDB) ensures scalability, cost-efficiency, and ease of maintenance.
- **Security:** Implements least-privilege IAM, Cognito JWT authentication for admin routes, and public access only where appropriate.
- **Feedback Loop:** Collects user feedback and escalation requests, supporting continuous improvement and human-in-the-loop escalation.
- **Frontend:** Modern Next.js frontend with real-time WebSocket chat and admin dashboard.

**Areas for Improvement:**
- Consider adding more advanced retrieval techniques (e.g., hybrid search, reranking, or semantic filtering) for even higher answer accuracy.
- Implement automated monitoring and alerting for data freshness and pipeline health.
- Ensure robust evaluation and red-teaming of the Bedrock Guardrail for content safety.

**Rating:**
**9/10** — The architecture is highly sound, modern, and production-ready, with only minor opportunities for further enhancement based on the latest RAG research and operational best practices.
# AskUSDA Application Summary

## Overview
AskUSDA is an AI-powered chatbot designed to help the public, farmers, and ranchers quickly find accurate information about USDA programs and services.

## Purpose and Features
- Provides a hover-over chatbot on a USDA-themed web page, allowing users to ask questions without leaving the site.
- Answers are generated using official content from usda.gov and farmers.gov, with source citations for verification.
- Users can rate answers (thumbs up/down) to provide feedback and help improve the system.
- If the chatbot cannot answer, users can submit a support request (name, email, question) for human follow-up.

## How It Works
- The frontend is a Next.js app hosted on AWS Amplify, with a floating chat widget and an admin dashboard at `/admin`.
- Users interact with the chatbot via WebSockets, receiving streaming responses with markdown formatting and citations.
- The backend is fully serverless, using AWS Lambda, API Gateway (WebSocket for chat, HTTP for admin), DynamoDB for storing conversation history and escalation requests, and Amazon Bedrock for AI (retrieval-augmented generation and content filtering).
- A web crawler (ECS Fargate) indexes USDA.gov and farmers.gov content, which is embedded and stored in an S3 vector store for the AI to use.
- Admins can view metrics, feedback, and escalation requests in a protected dashboard.

 - The Retrieval-Augmented Generation (RAG) system is powered by data scraped from USDA.gov and farmers.gov. A web crawler (ECS Fargate) indexes this content, which is then embedded and stored in an S3 vector store for the AI to use. This ensures answers are based on up-to-date, authoritative USDA sources and include source citations.

## Security
- Admin routes are protected with AWS Cognito JWT authentication.
- Public users can submit feedback and escalation requests without authentication.

## Intended Users
- General public, farmers, ranchers seeking USDA information.
- USDA staff/admins managing chatbot feedback and escalations.

## Summary
AskUSDA is a modern, AI-driven chatbot platform for USDA information, with robust backend infrastructure, real-time chat, feedback, and escalation handling, all built on AWS serverless technologies.

## LLM, RAG, and Guardrail

The chat experience is powered by a retrieval-augmented generation pipeline rather than a standalone prompt-only model. The WebSocket handler first applies Bedrock Guardrail checks to the user message, then retrieves relevant USDA context from the Bedrock Knowledge Base, and finally streams a Nova Pro response back to the client with citations.

- **Generation model**: Amazon Nova Pro v1:0 via the cross-region inference profile used by the WebSocket handler.
- **Embedding model**: Amazon Titan Embed Text v2:0 for the knowledge base.
- **Reranking**: Amazon Rerank v1:0 to improve retrieved context quality.
- **Guardrail**: Defined in the backend CDK stack and enabled in the WebSocket handler via environment variables.
- **Outcome**: The assistant stays grounded in USDA sources, uses citations, and falls back to safe messaging when the guardrail intervenes.

## CI/CD Pipeline

The AskUSDA application employs a robust CI/CD pipeline to automate deployment and ensure consistent delivery of updates. The pipeline is centered around AWS CodeBuild and Amplify, with the following key steps:

1. **CodeBuild Service Role:** A dedicated IAM role is created to manage the deployment process, with scoped permissions for CloudFormation, Lambda, DynamoDB, and other AWS services.

2. **Backend Deployment:**
   - The backend is deployed using AWS CDK, which provisions the serverless infrastructure (Lambda, API Gateway, DynamoDB, etc.).
   - CDK bootstrap and deploy commands are executed within the CodeBuild environment.

3. **Frontend Deployment:**
   - The Next.js frontend is built and packaged within CodeBuild.
   - The built application is deployed to AWS Amplify for static hosting.

4. **GitHub Integration:**
   - The pipeline integrates with GitHub as the source repository.
   - CodeBuild uses a Personal Access Token (PAT) for authentication to clone the repository and fetch updates.
   - GitHub Actions now also covers the deploy path, initial crawl workflow, smoke workflow, and nightly delta crawl scheduler.

5. **Crawler Refresh Controls:**
   - First-time crawl runs are triggered manually through the `initial-crawl.yml` workflow.
   - Nightly delta refreshes are scheduled through EventBridge Scheduler and can be enabled or disabled through repo variables.
   - The nightly run is gated so it only proceeds when crawl artifacts already exist.

6. **Monitoring and Logs:**
   - Build logs are streamed to CloudWatch Logs for real-time monitoring.
   - Deployment statuses and outputs are tracked in the AWS Management Console.

This CI/CD pipeline ensures that both the backend and frontend are deployed seamlessly, with minimal manual intervention, enabling rapid iteration and reliable updates.
