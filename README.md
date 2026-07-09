# AI Support Ticket Triage Engine

Headless backend service for AI-based support ticket classification and response generation

[![Rails Version](https://img.shields.io/badge/Rails-8.1-red.svg)](https://rubyonrails.org)
[![Ruby Version](https://img.shields.io/badge/Ruby-3.4.1-blue.svg)](https://www.ruby-lang.org)
[![Database](https://img.shields.io/badge/Postgres-14%2B-blue)](https://www.postgresql.org)
[![Queue](https://img.shields.io/badge/Sidekiq-8.x-green)](https://sidekiq.org)

---

## 1. Executive Summary

### The Problem
Customer support teams are overwhelmed by ticket volume. Manual categorization and routing are slow, error-prone, and expensive. This increases the manual support workload and delays responses to critical technical or billing issues.

### The Solution
An API-only backend service designed to automate ticket triage. By offloading classification, prioritization, and response drafting to background processing, the system lowers the support workload and guarantees fast, structured updates.

---

## 2. Architecture & Data Flow

```text
  [ Client Application / Webhook ]
                 │
       (POST /api/v1/tickets) -> Bearer Auth
                 ▼
     [ Rails Ingestion Controller ]
                 │
       (Writes 'pending' state & enqueues ID)
                 ├──> [ PostgreSQL (UUID Primary Key) ]
                 ▼
          [ Redis Queue ]
                 │
         (Pulls Job)
                 ▼
       [ Sidekiq Background Worker ]
                 │
         (Calls Service)
                 ▼
         [ Ai::TriageService ] ──(gpt-4o-mini via Structured JSON Schema)──┐
                 │                                                         │
                 │ (Persists category, urgency, summary, response)         │
                 └────────────────────────> [ PostgreSQL ] <───────────────┘
```

### Components
* **Ingestion Layer (`ActionController::API`)**: Validates input and writes raw tickets to Postgres in a `pending` state, immediately returning `202 Accepted` without waiting on the LLM.
* **Worker Queue (`Sidekiq + Redis`)**: Isolates slow LLM API calls from web threads.
* **AI Service Layer (`Ai::TriageService`)**: Implements strict structured output templates via OpenAI's API.
* **Database (`PostgreSQL`)**: Uses UUID primary keys for secure, non-sequential identifiers. Stores raw payloads, metadata, state tracking, and final classifications.

---

## 3. Engineering Decisions & Reliability Patterns

* **Strict Structured JSON Outputs**: Leverages OpenAI's `json_schema` response format so LLM payloads conform to our DB schema.
* **Asynchronous Isolation**: Offloads external LLM API latencies (1-10s) from critical Puma web threads.
* **Idempotent Ingestion**: A unique index on `external_id` means re-delivering the same ticket returns the original record instead of creating a duplicate (and a duplicate LLM call).
* **Concurrency-Safe Processing**: Workers claim a ticket via a database row lock (`SELECT … FOR UPDATE`) before calling the LLM, so two concurrent workers can never trigger two triage calls for the same ticket.
* **Bounded Retries**: Configured `sidekiq_options retry: 3` with exponential backoff. Caps API spend on transient failures.
* **State & Error Auditing**: Traps exceptions and writes the message to `error_message` with a `failed` status for administrative visibility.
* **Clean Mock Layer**: Uses pure-Ruby metaprogramming stubs in tests to verify OpenAI client behavior with zero network overhead.

---

## 4. API Reference

### A. Ingest Support Ticket
* **Endpoint**: `POST /api/v1/tickets`
* **Headers**:
  * `Content-Type: application/json`
  * `Authorization: Bearer <API_AUTH_TOKEN>`

#### Request Body
```json
{
  "ticket": {
    "customer_email": "customer@example.com",
    "subject": "Double charged for subscription",
    "body": "I noticed two charges of $49 on my statement for July 1st. Please refund the duplicate.",
    "external_id": "ext-12345",
    "metadata": {
      "plan": "pro"
    }
  }
}
```

#### Response (`202 Accepted`)
```json
{
  "ticket_id": "a5d09f7a-8f92-4d2c-80a5-f860fb7f8273",
  "status": "pending",
  "message": "Ticket created and queued for triage."
}
```

---

### B. Retrieve Ticket Classification
* **Endpoint**: `GET /api/v1/tickets/:id`
* **Headers**:
  * `Authorization: Bearer <API_AUTH_TOKEN>`

#### Response (`200 OK` - Processing Completed)
```json
{
  "ticket_id": "a5d09f7a-8f92-4d2c-80a5-f860fb7f8273",
  "external_id": "ext-12345",
  "customer_email": "customer@example.com",
  "status": "completed",
  "category": "billing",
  "urgency": "high",
  "summary": "Customer requests a refund for a duplicate subscription charge of $49.",
  "suggested_reply": "Dear customer, thank you for reaching out. We have located the duplicate charge of $49 and are initiating a refund immediately. It should appear back in your account within 5-10 business days.",
  "error_message": null,
  "metadata": { "plan": "pro" },
  "created_at": "2026-07-01T12:00:00.000Z",
  "updated_at": "2026-07-01T12:00:03.000Z"
}
```

---

## 5. Technology Stack
* **Framework**: Ruby on Rails 8.1 (API-only configuration)
* **Job Engine**: Sidekiq 8.1 (backed by Redis 7.x)
* **Database**: PostgreSQL 14+ (UUID keys, JSONB metadata)
* **LLM Engine**: OpenAI API (`gpt-4o-mini`)
* **Test Suite**: Minitest (20 unit/integration tests, 100% green)

---

## 6. Setup & Installation

### 1. Configure Environment
Create a `.env` file or export your credentials:
```bash
export OPENAI_API_KEY="your-openai-api-key"
export API_AUTH_TOKEN="triage-mvp-token" # Token validation key
export REDIS_URL="redis://localhost:6379/1"
```

### 2. Setup Database & Dependencies
```bash
bundle install
bin/rails db:setup
```

### 3. Run Test Suite
Executes isolated tests utilizing local mock stubs (no external API calls):
```bash
bundle exec rails test
```

### 4. Boot Services
Start your Redis instance, then run the background worker and the API server:
```bash
# Terminal 1
bundle exec sidekiq

# Terminal 2
bundle exec rails server -p 3000
```

---

## 7. Future Roadmap
* **Webhook dispatch**: Deliver processed ticket states back to configured client callback URLs immediately after classification.
* **LLM Provider fallback**: Implement automatic failover routing to Anthropic Claude if OpenAI rate limits or times out.
