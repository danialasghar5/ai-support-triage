# AI Support Ticket Triage Engine

An asynchronous customer support classification, prioritization, and response drafting microservice built with Rails 8, Sidekiq, and OpenAI.

[![Rails Version](https://img.shields.io/badge/Rails-8.1-red.svg)](https://rubyonrails.org)
[![Ruby Version](https://img.shields.io/badge/Ruby-3.4.1-blue.svg)](https://www.ruby-lang.org)
[![Database](https://img.shields.io/badge/Postgres-14%2B-blue)](https://www.postgresql.org)
[![Queue](https://img.shields.io/badge/Sidekiq-8.x-green)](https://sidekiq.org)

---

## 1. Executive Summary

### The Problem
SaaS support teams are overwhelmed by raw ticket volume. Manual categorization and routing are slow, error-prone, and expensive. This causes delayed replies to urgent issues (e.g., billing errors or system downtime).

### The Solution
A production-grade, API-only microservice that ingests unclassified support tickets, queues them in Redis, and asynchronously triages them using LLMs. The engine outputs structured classification, urgency rating, summary, and a suggested draft response.

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
* **Ingestion Layer (`ActionController::API`)**: Validates input and writes raw tickets to Postgres with a `pending` status. Immediately responds with `202 Accepted` (< 5ms response time).
* **Worker Queue (`Sidekiq + Redis`)**: Isolates slow LLM API calls from web threads.
* **AI Service Layer (`Ai::TriageService`)**: Implements strict structured output templates via OpenAI's API.
* **Database (`PostgreSQL`)**: Uses UUID primary keys for secure, non-sequential identifiers. Stores raw payloads, metadata, state tracking, and final classifications.

---

## 3. Engineering Decisions & Reliability Patterns

* **Strict Structured JSON Outputs**: Leverages OpenAI's `json_schema` response format to guarantee LLM payloads match our DB schema. Eliminates parsing failures.
* **Asynchronous Isolation**: Offloads external LLM API latencies (1-10s) from critical Puma web threads.
* **Idempotency Gate**: Workers skip classification if the target ticket status is already `completed`.
* **Bounded Retries**: Configured `sidekiq_options retry: 3` with exponential backoff. Prevents runaway API billing.
* **State & Error Auditing**: Traps exceptions and writes the stack trace/message to `error_message` with a `failed` status for administrative visibility.
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
* **Test Suite**: Minitest (15 unit/integration tests, 100% green)

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
* **Multi-tenant isolation**: Support multi-client database scoping (Account/Organization levels).
