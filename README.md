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
* **Concurrency-Safe Processing**: Workers claim a ticket via a database row lock (`SELECT … FOR UPDATE`) before calling the LLM, so two concurrent workers can never trigger two triage calls for the same ticket. The lock is held only for the fast state transition, never across the LLM call.
* **Crash Recovery (Reaper)**: A worker that claims a ticket and then crashes would strand it in `processing` (open-source Sidekiq has no reliable-fetch, so the in-flight job is lost). `ReclaimStaleTicketsJob` resets tickets stuck in `processing` past a claim timeout (default 5 min, `TRIAGE_CLAIM_TIMEOUT_SECONDS`) back to `pending` and **re-enqueues** triage. It is a visibility timeout, so the at-most-once claim — not the timeout — is what keeps a resurrected ticket from being triaged twice. Schedule it with `bin/rails tickets:reclaim_stale`.
* **Bounded, Classified Retries**: `sidekiq_options retry: 3` with exponential backoff. Transient failures (rate limit, 5xx, timeout) retry; permanent ones (4xx, auth, refusal, malformed output) fail fast. Caps API spend on failures that cannot succeed.
* **State & Error Auditing**: Traps exceptions and writes the message to `error_message` with a `failed` status for administrative visibility.
* **Structured Logging**: Each LLM call and job outcome emits a logfmt line (`event`, `ticket_id`, `model`, `outcome`, `duration_ms`, `error_class`) — greppable observability with no APM dependency. Ticket content is never logged, and PII-bearing request params (`body`, `subject`, `metadata`, …) are filtered from Rails logs.
* **Output Validation**: Persisted `urgency` is validated against a fixed vocabulary (the same constant that drives the LLM's JSON schema, so the contract can't drift); `category` is length-bounded.
* **Real Contract & Concurrency Tests**: The OpenAI integration is tested at the HTTP boundary with WebMock — asserting the outgoing request shape and driving error classification through the real Faraday middleware — while a two-thread test proves the row lock admits exactly one LLM call per ticket under contention.

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
* **Test Suite**: Minitest + WebMock (53 unit/integration/contract/concurrency tests, 100% green)

---

## 6. Setup & Installation

### 1. Configure Environment
Create a `.env` file or export your credentials:
```bash
export OPENAI_API_KEY="your-openai-api-key"
export API_AUTH_TOKEN="choose-a-strong-token" # Required: the API fails closed (503) if unset
export REDIS_URL="redis://localhost:6379/1"
```

### 2. Setup Database & Dependencies
```bash
bundle install
bin/rails db:setup
```

### 3. Run Test Suite
Runs fully offline — outbound HTTP is disabled and the OpenAI API is stubbed at the HTTP boundary with WebMock:
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

### 5. Schedule the Reaper
Run `ReclaimStaleTicketsJob` periodically (e.g. every minute) to recover tickets abandoned in `processing` by a crashed worker. It has no scheduler dependency — wire it to whatever you already run (system cron, `sidekiq-cron`, etc.):
```bash
# e.g. crontab: * * * * * cd /app && bin/rails tickets:reclaim_stale
bin/rails tickets:reclaim_stale
```

---

## 7. Testing & Proven Reliability

The suite is layered (model, API integration, service HTTP contract, job, concurrency) and runs offline. It **proves**, not just exercises:

* **Idempotent ingestion** — a duplicate `external_id` creates no second row and no second job.
* **Exactly one LLM call under concurrent workers** — a two-thread test contends for one ticket; it is validated to *fail* if the row lock is removed, so it isn't a tautology.
* **The database adjudicates the ingestion race** — two threads inserting the same `external_id` yield exactly one row (the other raises `RecordNotUnique`), and the controller's rescue returns the existing ticket with `200`.
* **Crash recovery** — a ticket stranded in `processing` past the timeout is reset to `pending` and re-enqueued; a healthy in-flight ticket is left alone.
* **Error classification through the real Faraday middleware** (WebMock) — 429/5xx/timeout retry; 4xx/auth/refusal/malformed fail fast.
* **Incomplete or malformed LLM output is rejected**, never persisted.

Deliberately out of scope: Sidekiq's live Dead-Set/attempt-counting (asserted at config + contract level, not via a Redis integration test) and LLM output *accuracy*. See [architecture §5](docs/architecture.md).

---

## 8. Limitations & Trade-offs

Stated plainly (full detail in [architecture §6](docs/architecture.md)):

* Crash recovery is a coarse visibility timeout: a worker killed mid-flight leaves its ticket in `processing` until `ReclaimStaleTicketsJob` reclaims it after `CLAIM_TIMEOUT` (default 5 min). The completion write is not yet fenced by `claimed_at`, so a merely-hung worker that revives post-reclaim could still write its result — a fencing token is future work.
* Permanent failures are recorded on the ticket (`failed` + `error_message`) and **not** placed in Sidekiq's Dead Set — the ticket row is the failure source of truth.
* Auth is a single shared token (fail-closed), not per-client.
* `category` is open (length-bounded only); `urgency` is validated against a fixed set.
* The system guarantees a **schema-valid, complete** response is persisted — not that the classification is *accurate*.

---

## 9. Future Roadmap
* **Webhook dispatch**: Deliver processed ticket states back to configured client callback URLs immediately after classification.
* **Fenced crash recovery**: A `claimed_at` fencing token on the completion write plus a lease/heartbeat to shorten the reclaim window (the reclaim reaper itself already ships).
* **Per-client authentication**: Distinct, rotatable API keys per client.
* **LLM Provider fallback**: Automatic failover to an alternate provider (e.g., Anthropic Claude) on sustained OpenAI errors.
