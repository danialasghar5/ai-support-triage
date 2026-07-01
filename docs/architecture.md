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

## 3. Scale & Production Considerations (Future Proofing)
1. **Authentication**: Simple API key auth (`Bearer token`) per client.
2. **Webhooks**: Dispatch a webhook back to the client system once the ticket state changes to `completed` or `failed`.
3. **Idempotency**: Prevent duplicate processing via `external_id` or unique request tokens.
