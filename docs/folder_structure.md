# Rails 8 Project Folder Structure

This document outlines the relevant file and folder organization for the AI Support Ticket Triage MVP. It highlights standard Rails conventions along with our custom service pattern.

```text
ai-support-triage/
├── app/
│   ├── controllers/
│   │   └── api/
│   │       └── v1/
│   │           └── tickets_controller.rb     # Ingests ticket payloads, triggers Sidekiq
│   │
│   ├── jobs/
│   │   └── ticket_triage_job.rb             # Background job; runs LLM triage and updates state
│   │
│   ├── models/
│   │   └── ticket.rb                        # DB record for tickets, handles status & results
│   │
│   └── services/                            # Core business logic isolated from controllers/models
│       └── ai/
│           └── triage_service.rb            # Integrates with LLM API (OpenAI/Claude)
│
├── config/
│   ├── initializers/
│   │   └── sidekiq.rb                       # Configures Sidekiq & Redis client
│   │
│   ├── routes.rb                            # Defines /api/v1/tickets endpoint
│   └── sidekiq.yml                          # Sidekiq queue and concurrency configuration
│
└── db/
    └── migrate/
        └── 20260701xxxxxx_create_tickets.rb # Database schema migration (using UUIDs)
```

## Key Architectural Rationale

1. **`app/services/`**: We introduce a dedicated `services` directory. This isolates API call logic, JSON schema mapping, and error handling for OpenAI/Claude from the ActiveRecord model and the background job.
2. **`app/controllers/api/v1/`**: Keeping api controllers namespaced under `api/v1/` ensures that future integrations or v2 APIs won't break existing client setups.
3. **`app/jobs/`**: Inherits from standard ActiveJob (or Sidekiq direct worker format) to handle async processing.
