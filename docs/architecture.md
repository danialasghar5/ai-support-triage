# System Architecture: AI Support Ticket Triage MVP

This document outlines the architectural design for the AI Support Ticket Triage System. The goal is a production-grade, highly reliable, and extensible MVP.

---

## 1. High-Level Flow (Request/Response & Async Processing)

```mermaid
sequenceDiagram
    autonumber
    actor Client as SaaS Client (Webhook/API)
    participant API as Rails API (POST /api/v1/tickets)
    database DB as PostgreSQL
    participant Redis as Redis
    participant Worker as Sidekiq Worker
    participant LLM as AI Service (OpenAI / Claude)

    Client->>API: Send Support Ticket (JSON)
    ActiveNote API: Validate fields (email, body)
    API->>DB: Insert Ticket (Status: pending)
    API->>Redis: Enqueue TicketTriageJob(ticket_id)
    API-->>Client: 202 Accepted { ticket_id: UUID, status: "pending" }
    
    Note over Worker, Redis: Sidekiq picks up job from queue
    Worker->>DB: Update status to "processing"
    
    Worker->>LLM: Send ticket context & system instructions
    LLM-->>Worker: Return structured JSON (category, urgency, summary, draft reply)
    
    Worker->>DB: Update Ticket with classifications & status: "completed"
    Note over Worker, DB: If failed, mark status: "failed" and record error_message
```

---

## 2. Component Breakdown

### A. Rails API Layer (Controller)
* **Endpoint**: `POST /api/v1/tickets`
* **Format**: JSON
* **Responsibility**: Ingest tickets quickly. Minimize processing time on the web server thread. Offload heavy lifting to Sidekiq immediately.
* **Return status**: `202 Accepted` to allow clients (like webhooks) to disconnect without waiting for LLM completion.

### B. Persistence Layer (PostgreSQL)
* **Primary Key**: UUID (highly recommended for production SaaS to avoid sequential ID exposure and merge conflicts).
* **Schema (`tickets`):**
  * `id`: `uuid` (Primary Key)
  * `external_id`: `string` (indexed, for lookup from client platform)
  * `customer_email`: `string` (required)
  * `subject`: `string` (nullable)
  * `body`: `text` (required)
  * `status`: `string` (enum: `pending`, `processing`, `completed`, `failed`)
  * `category`: `string` (nullable)
  * `urgency`: `string` (nullable: `low`, `medium`, `high`, `urgent`)
  * `summary`: `text` (nullable)
  * `suggested_reply`: `text` (nullable)
  * `metadata`: `jsonb` (for arbitrary key-value pairs from client systems)
  * `error_message`: `text` (for debugging API/LLM failures)
  * `timestamps`

### C. Background Job Layer (Sidekiq + Redis)
* **Technology**: Sidekiq using Redis.
* **Why**: High-throughput, low latency, standard Rails pattern. Replaces default Rails 8 `solid_queue` for this production path to ensure highly scalable background workers.
* **Retry Strategy**: Sidekiq default exponential backoff, configured with a limit (e.g., 3 retries) to avoid racking up LLM billing during transient API failures.
* **Error Handling**: Captures network timeouts and rate limits, saving details into `error_message` while letting Sidekiq handle the retry.

### D. Service Layer (AI Client Integration)
* **Design Pattern**: Service Object (`TicketTriageService` or `Ai::TriageService`).
* **Responsibility**: Encapsulates all prompt engineering, system instructions, and LLM communication.
* **LLM Strategy**: Use Structured Outputs (e.g., JSON Mode or tool calling) to guarantee the LLM returns parsing-safe JSON matching our database attributes.
* **Resilience**: Configured timeouts (e.g., Faraday or HTTP clients set to 15s max) to prevent hanging threads.

---

## 3. Reliability Patterns (Implemented)

* **Authentication**: A single shared `Bearer` token, supplied via `API_AUTH_TOKEN`. The server **fails closed** (returns `503`) when the variable is unset, and compares tokens in constant time. Per-client keys are a future enhancement.
* **Idempotent Ingestion**: A unique index on `external_id` guarantees one ticket per external identifier. Re-delivering the same payload returns the original record instead of creating a duplicate.
* **Concurrency-Safe Processing**: The triage job claims a ticket via a row-level lock (`SELECT … FOR UPDATE`), transitioning `pending`/`failed → processing` atomically. The lock is released before the LLM call, so a second worker that arrives while the first is mid-flight sees `processing` and backs off — at most one LLM call per ticket.

## 4. Scale & Production Considerations (Future Proofing)

1. **Per-client authentication**: Issue and rotate a distinct API key per client rather than one shared token.
2. **Webhooks**: Dispatch a webhook back to the client system once the ticket state changes to `completed` or `failed`.
3. **Stuck-worker recovery**: A ticket left in `processing` by a crashed worker is currently not auto-reclaimed; a lease/heartbeat with a reclaim window would close this gap.
