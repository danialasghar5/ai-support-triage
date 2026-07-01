# AI Support Ticket Triage Engine

### *Automated, asynchronous customer support classification, prioritization, and response drafting at scale.*

[![Rails Version](https://img.shields.io/badge/Rails-8.1.x-red.svg)](https://rubyonrails.org)
[![Ruby Version](https://img.shields.io/badge/Ruby-3.4.1-blue.svg)](https://www.ruby-lang.org)
[![Database](https://img.shields.io/badge/Postgres-14%2B-blue)](https://www.postgresql.org)
[![Queue](https://img.shields.io/badge/Sidekiq-8.x-green)](https://sidekiq.org)

---

## 1. The Problem
Modern SaaS businesses face a massive influx of customer support tickets daily. Manual triage is slow, prone to human error, and expensive:
* **High Latency**: Tickets sit in unassigned queues waiting for manual review.
* **Exhausted Staff**: Support reps spend valuable hours reading, summarizing, categorizing, and assigning tickets rather than solving deep issues.
* **Inconsistent Prioritization**: Urgent customer issues (e.g., account lockouts, payment failures) get buried under low-priority feature requests.

---

## 2. The Solution
This system is a **production-grade API microservice** designed to ingest raw, unclassified support tickets, queue them immediately for background processing, and leverage LLMs to classify, summarize, prioritize, and write draft replies—delivering structured triage data back to your primary CRM or helpdesk in seconds.

By offloading the classification and drafting process to a high-throughput background queue, your web threads remain fast, and support agents receive pre-classified tickets with high-quality suggested replies the moment they open their dashboards.

---

## 3. Architecture & Data Flow

```text
                                    +-----------------+
                                    |  SaaS Webhook / |
                                    |   Client App    |
                                    +--------+--------+
                                             |
                                    (POST /api/v1/tickets)
                                             v
                                  +----------+----------+
                                  |                     |
                                  |  Rails Controller   |
                                  |                     |
                                  +----------+----------+
                                             |
                                  (Verify Bearer Token)
                                             |
                                             v
+-------------------+             +----------+----------+             +-----------------+
|                   |  Enqueue ID |                     |  POP / Run  |                 |
|    PostgreSQL     |<------------+    Redis Queue      |<------------+  Sidekiq Worker |
| (UUID Primary Key)|             |  (Solid Backing)    |             |                 |
|                   |             +---------------------+             +--------+--------+
+---------+---------+                                                          |
          ^                                                                    v
          |                                                           +--------+--------+
          |                                                           |   AI Service    |
          +-----------------------------------------------------------+ (OpenAI Triage) |
                               Update Ticket Status &                 +--------+--------+
                              Structured Classifications                       |
                                                                               v
                                                                      +--------+--------+
                                                                      | OpenAI API      |
                                                                      | (gpt-4o-mini)   |
                                                                      +-----------------+
```

### Components
* **Ingestion Layer (`ActionController::API`)**: Validates the payload and immediately writes it to PostgreSQL in a `pending` state, returning `202 Accepted` to the client. Web server connections are freed in under 5ms.
* **Queueing Layer (`Sidekiq + Redis`)**: Acts as the asynchronous backbone, handling incoming job scheduling, concurrency management, and retry handling.
* **Service Layer (`Ai::TriageService`)**: Implements strict structured JSON schema output queries utilizing OpenAI's structured outputs feature. 
* **Persistence Layer (`PostgreSQL`)**: Stores raw payload parameters, execution states, system errors, and final LLM classification structures. Built on `UUID` primary keys for security and seamless external system mapping.

---

## 4. Production-Ready Features
* **Strict Structured JSON Outputs**: Uses OpenAI's `json_schema` response format to guarantee the model's response matches database fields (`category`, `urgency`, `summary`, `suggested_reply`). Prevents JSON parsing errors and markdown extraction failure.
* **Bearer Token Authentication**: Secure endpoints restricted by token headers (`Authorization: Bearer <token>`).
* **Asynchronous Processing**: Prevents thread starvation on the web server by routing slow LLM API calls to background Sidekiq workers.
* **Idempotency Gates**: Workers check ticket state upon execution, skipping analysis for tickets that have already completed.
* **Resilient Retry Policies**: Sidekiq retries are constrained to `3` attempts with exponential backoff to handle rate-limits and temporary network drops, capping LLM billing exposure.
* **Error Trapping & State Tracking**: Job errors are captured and written to the database (`status: failed`, `error_message: "Error text"`), allowing administrative tracking before retries run.
* **High Test Coverage**: Robust test suite covering model validations, service mocks, controller request flows, and job state transitions.

---

## 5. API Reference

### A. Ingest Support Ticket
Ingests a new support ticket and queues it for triage.

* **Endpoint**: `POST /api/v1/tickets`
* **Headers**:
  * `Content-Type: application/json`
  * `Authorization: Bearer <API_AUTH_TOKEN>`

#### Request Body
```json
{
  "ticket": {
    "customer_email": "jane.doe@example.com",
    "subject": "Charged twice on invoice INV-4858",
    "body": "Hi support, I was billed twice for my subscription renewal on July 1st. Can you look into reversing the duplicate $49 charge?",
    "external_id": "ext-crm-9910",
    "metadata": {
      "plan_type": "pro",
      "stripe_customer_id": "cus_Njk18a"
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

### B. Retrieve Ticket Status & Classifications
Polls the processing status and results of a ticket.

* **Endpoint**: `GET /api/v1/tickets/:id`
* **Headers**:
  * `Authorization: Bearer <API_AUTH_TOKEN>`

#### Response (`200 OK` - Processing Completed)
```json
{
  "ticket_id": "a5d09f7a-8f92-4d2c-80a5-f860fb7f8273",
  "external_id": "ext-crm-9910",
  "customer_email": "jane.doe@example.com",
  "status": "completed",
  "category": "billing",
  "urgency": "high",
  "summary": "Customer requests a refund for a duplicate subscription charge of $49 on invoice INV-4858.",
  "suggested_reply": "Dear Jane, thank you for reaching out. We have located the duplicate charge of $49 on invoice INV-4858 and are initiating a refund immediately. The credits should appear back in your account within 5-10 business days.",
  "error_message": null,
  "metadata": {
    "plan_type": "pro",
    "stripe_customer_id": "cus_Njk18a"
  },
  "created_at": "2026-07-01T12:00:00.000Z",
  "updated_at": "2026-07-01T12:00:04.000Z"
}
```

#### Response (`200 OK` - Processing Failed)
```json
{
  "ticket_id": "a5d09f7a-8f92-4d2c-80a5-f860fb7f8273",
  "status": "failed",
  "error_message": "AI Triage failed: Rate limit exceeded on OpenAI API",
  "metadata": {},
  "created_at": "2026-07-01T12:00:00.000Z",
  "updated_at": "2026-07-01T12:00:04.000Z"
}
```

---

## 6. Tech Stack
* **Framework**: Ruby on Rails 8.1 (API-only configuration)
* **Job Engine**: Sidekiq 8.1
* **Memory Cache / Queue Broker**: Redis 7.x
* **Database**: PostgreSQL 14+ (UUID keys, JSONB metadata)
* **LLM Engine**: OpenAI API (`gpt-4o-mini` with Strict Structured Outputs)
* **Test Suite**: Minitest with pure-Ruby dynamic stubbing and mock objects

---

## 7. Setup & Installation

### 1. Clone & Install Dependencies
Ensure you have Ruby 3.4.1 installed.
```bash
git clone https://github.com/your-username/ai-support-triage.git
cd ai-support-triage
bundle install
```

### 2. Configure Environment Variables
Create a `.env` file or export your keys:
```bash
export OPENAI_API_KEY="your-openai-api-key"
export API_AUTH_TOKEN="triage-mvp-token" # Custom token for requests
export REDIS_URL="redis://localhost:6379/1"
```

### 3. Setup Database
```bash
bin/rails db:setup
```

### 4. Run Test Suite
Confirm everything is functional. All tests run in isolation using local stubs (no external API calls):
```bash
bundle exec rails test
```

### 5. Boot Services
Start Redis:
```bash
redis-server
```

Start the Sidekiq Worker:
```bash
bundle exec sidekiq
```

Start the Rails API Server:
```bash
bundle exec rails server -p 3000
```

---

## 8. Future Roadmap
* **Admin dashboard**: A React or Hotwire UI to review, search, and manually update ticket triage categories.
* **Webhook notifications**: Post results back to client-provided callback URLs once triage transitions to `completed` or `failed`.
* **Multi-tenant SaaS support**: Introduce Account and Organization scoping for multi-client SaaS configurations.
* **LLM Provider Router**: Implement fallback routing to Anthropic Claude if OpenAI rate limits or times out.
