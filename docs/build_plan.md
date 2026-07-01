# MVP Build Plan (7-Day Roadmap)

This document defines the incremental build plan for the AI Support Ticket Triage MVP. Each step builds on the previous, focusing on production-readiness, automated testing, and simplicity.

---

## **Day 1: Database Schema & Ticket Model**
* **Goal**: Define the core persistence layer.
* **Tasks**:
  * Enable the pg `pgcrypto` extension for UUIDs.
  * Generate the `Ticket` model migration with fields for raw payload, state tracking, and classification results.
  * Implement validations (email format, body presence) and status/state validations.
  * Write model unit tests.

## **Day 2: Sidekiq + Redis Setup**
* **Goal**: Establish the asynchronous job processing backend.
* **Tasks**:
  * Add `sidekiq` to the `Gemfile` and bundle.
  * Configure ActiveJob to use the `:sidekiq` queue adapter.
  * Create `config/initializers/sidekiq.rb` (redis connection pool settings for dev/prod).
  * Add `config/sidekiq.yml` to define queues (`default`, `mailers`).
  * Verify Sidekiq can boot and connect to Redis.

## **Day 3: Ingestion API (Routes & Controller)**
* **Goal**: Build the public-facing API ingestion endpoint.
* **Tasks**:
  * Set up `config/routes.rb` namespace `api/v1`.
  * Build `Api::V1::TicketsController#create` endpoint.
  * Implement strong parameters for incoming payload (customer_email, subject, body, metadata).
  * Write request tests checking validation states (`422 Unprocessable Entity` vs. `202 Accepted` with UUID).

## **Day 4: AI Triage Service Object**
* **Goal**: Implement clean, schema-validated communication with OpenAI/Claude.
* **Tasks**:
  * Add the official SDK (e.g. `openai` gem or Faraday for direct HTTP client controls).
  * Create service object `App::Services::Ai::TriageService`.
  * Draft system instructions and configure Structured Outputs (JSON schema) to match model fields (category, urgency, summary, suggested_reply).
  * Write service tests with mocked HTTP requests (Webmock or VCR).

## **Day 5: Sidekiq Triage Job**
* **Goal**: Connect ingestion, background queues, and the AI service.
* **Tasks**:
  * Create `TicketTriageJob` background job.
  * Implement job flow: transition status to `processing`, invoke `Ai::TriageService`, update ticket attributes, transition status to `completed`.
  * Implement job error handling (rescuing LLM timeouts/exceptions, updating status to `failed` with error message, letting Sidekiq handle retry).

## **Day 6: Resilience & Edge Cases**
* **Goal**: Ensure the system handles production anomalies.
* **Tasks**:
  * Configure Sidekiq retry limits (e.g., maximum 3 retries for LLM calls).
  * Add simple token-based API authentication (`Bearer` token check in Controller).
  * Gracefully handle null bodies/unexpected input at the API boundary.

## **Day 7: E2E Integration & Verification**
* **Goal**: Conduct final end-to-end local testing.
* **Tasks**:
  * Run the server and Sidekiq concurrently.
  * Execute validation runs using `curl` payloads.
  * Monitor Redis / Sidekiq logs.
  * Document walkthrough and verification results.
