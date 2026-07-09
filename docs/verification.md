# End-to-End Verification Guide

This guide details how to verify the AI Support Ticket Triage System locally using `curl`.

---

## 1. Prerequisites

### A. Environment Variables
Make sure you have your OpenAI API key exported, along with the API Auth token if you want to override the default:
```bash
export OPENAI_API_KEY="your-actual-openai-api-key"
export API_AUTH_TOKEN="triage-mvp-token" # Required: the API fails closed (503) if unset
```

### B. Start Background Services
Ensure Redis is running:
```bash
redis-cli ping # Should return PONG
```

In a new terminal window, boot the Sidekiq worker process:
```bash
bundle exec sidekiq
```

In another terminal window, boot the Rails local development server:
```bash
bundle exec rails server -p 3000
```

---

## 2. Testing Steps

### Step 1: Create a Ticket (Ingestion API)
Send a POST request to the tickets endpoint with a billing support example payload:

```bash
curl -i -X POST http://localhost:3000/api/v1/tickets \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer triage-mvp-token" \
  -d '{
    "ticket": {
      "customer_email": "jane.doe@example.com",
      "subject": "Charged twice on invoice INV-4858",
      "body": "Hi support, I was billed twice for my Subscription renewal on July 1st. Can you look into reversing the duplicate $49 charge?",
      "external_id": "ext-webhook-001",
      "metadata": {
        "stripe_customer_id": "cus_Njk18a",
        "plan_type": "pro"
      }
    }
  }'
```

#### Expected Ingestion Response (`202 Accepted`):
```json
{
  "ticket_id": "a5d09f7a-8f92-4d2c-80a5-f860fb7f8273",
  "status": "pending",
  "message": "Ticket created and queued for triage."
}
```

---

### Step 2: Poll status & classifications (Lookup API)
Make a GET request using the `ticket_id` returned from Step 1:

```bash
curl -i http://localhost:3000/api/v1/tickets/a5d09f7a-8f92-4d2c-80a5-f860fb7f8273 \
  -H "Authorization: Bearer triage-mvp-token"
```

#### Expected Completed Response (`200 OK`):
```json
{
  "ticket_id": "a5d09f7a-8f92-4d2c-80a5-f860fb7f8273",
  "external_id": "ext-webhook-001",
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
  "created_at": "2026-07-01T17:50:00.000Z",
  "updated_at": "2026-07-01T17:50:04.000Z"
}
```

---

## 3. Verify Error Handling

To test how the system acts under invalid conditions:

### A. Missing Authentication Header
```bash
curl -i -X POST http://localhost:3000/api/v1/tickets \
  -H "Content-Type: application/json" \
  -d '{"ticket":{"customer_email":"test@example.com","body":"help"}}'
```
* **Expected Response**: `401 Unauthorized` `{ "error": "Unauthorized" }`

### B. Validation Failures (Missing Body/Email)
```bash
curl -i -X POST http://localhost:3000/api/v1/tickets \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer triage-mvp-token" \
  -d '{"ticket":{"customer_email":"bad-email","body":""}}'
```
* **Expected Response**: `422 Unprocessable Entity` containing validation array `["Customer email is invalid", "Body can't be blank"]`
