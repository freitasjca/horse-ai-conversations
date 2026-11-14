# horse-ai-conversations

AI conversation ownership and persistence for the [Horse](https://github.com/HashLoad/horse) web framework. Binds `horse-session` principals to `horse-ai` streams.

Status: **v0.1.0-alpha.1** — scaffold. See `docs/horse-ai-conversations-decision.md` in the workspace for the full ADR.

## What it does

- Owns the logical key `(tenant_id, principal_id, conversation_id)`. Every store operation takes the triple — ownership is **part of the signature**, not inferred from ids.
- Persists `TAIMessages` behind `IAIConversationStore`. `TMemoryConversationStore` is the default; durable adapters (Redis, Postgres, FireDAC) ship as sibling packages.
- Maps `(principal, stream_id)` so DELETE `/streams/:id` can **check ownership** before calling horse-ai's `Manager.Cancel`. horse-ai's `CancelAll` stays shutdown-only.
- Reuses horse-ai's existing SSE transport (`Horse.AI.StreamTransport`) — no parallel wire implementation.
- Multiple conversations per principal from v1. No `user_id → one active conversation` anywhere.
- Audit events through horse-session's `IAuthAuditSink` + `TAuthAuditEvent` **unchanged** — this package reserves the `conversation.` and `stream.` Action prefixes in the shared vocabulary.

## Not in v1

- Durable store adapters (Redis, Postgres, FireDAC) — ship as siblings.
- Per-principal concurrent-stream caps.
- Forcible upstream HTTP abort on DELETE (inherits horse-ai's v1 cancel-latency limitation).
- Conversation summarisation / context-window management.
- Rate limiting per principal / per tenant.

## Install

```sh
boss install github.com/freitasjca/horse-ai-conversations
```

## Quick start

```pascal
uses
  System.SysUtils,
  Horse,
  Horse.Session.Middleware,
  Horse.Session.Types,
  Horse.AI.Types,
  Horse.AI.StreamManager,
  Horse.AI.Conversations,
  Horse.AI.Conversations.Types;

var
  LConfig: THorseAIConversationsConfig;
  LConversations: THorseAIConversations;
begin
  // 1. horse-session establishes identity on every request
  THorse.Use(THorseSession.New({ your session config }));

  // 2. One facade for the application
  LConfig := THorseAIConversationsConfig.Default;      // in-memory store
  LConfig.StreamManager := THorseAIStreamManager.Default;
  LConversations := THorseAIConversations.Create(LConfig);

  // 3. Route handlers call the facade; it checks ownership on every call
  THorse.Delete('/streams/:id',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      try
        if LConversations.CancelForRequest(Req, Req.Params['id']) then
          Res.Status(204)
        else
          Res.Status(404);
      except
        on E: EHorseSessionUnauthorized do Res.Status(401);
        on E: EHorseAIStreamForbidden do Res.Status(403);
      end;
    end);

  THorse.Listen(9000);
end.
```

The facade is not a middleware: create one instance and call it from your handlers. It reads the caller with `PrincipalOf(Req)` from `horse-session` and never trusts a tenant or user id sent by the client. Ids are compared exactly, so `Alice` and `alice` are two different owners.

| Method | Refuses with |
|--------|--------------|
| `CreateFor`, `GetFor`, `AppendFor`, `DeleteFor` | `EHorseSessionUnauthorized` when not authenticated; another principal's conversation is reported as not found |
| `StartStreamFor` | `EHorseSessionUnauthorized`; `EHorseAIConversationNotFound` when the conversation is not the caller's (no stream is created) |
| `CancelForRequest` | `EHorseSessionUnauthorized`; `EHorseAIStreamForbidden` when the stream belongs to someone else (the stream keeps running); returns `False` when the stream is unknown or already finished |

When a stream ends on its own, call `ForgetStream(streamId)` so its ownership entry is dropped.

## Ownership-check sequence

```
DELETE /streams/{id}
      |
  horse-session middleware  -> principal attached to the request
      |
  your handler calls CancelForRequest(Req, stream_id)
      |
  if not authenticated       -> EHorseSessionUnauthorized  (401)
  if stream_id not in map    -> False                      (404)
  if owner != principal      -> EHorseAIStreamForbidden    (403)
      |
  Call horse-ai Manager.Cancel(stream_id)
      |
  Audit sink: stream.cancelled(principal, stream_id, outcome)
      |
  204 No Content
```

Stream IDs are **never reused**. A cancelled stream is removed from this package's ownership map at once; a stream that ends on its own is removed when you call `ForgetStream`, or when a later cancel finds it gone. A second DELETE of the same id answers 404, not 403.

## Audit vocabulary this package reserves

Both prefixes are registered in horse-session's shared `TAuthAuditEvent.Action` vocabulary. See `Horse.Session.Audit` for the full list.

| Action | Resource |
|---|---|
| `conversation.created` | conversation |
| `conversation.accessed` | conversation |
| `conversation.access.denied` | conversation |
| `conversation.deleted` | conversation |
| `stream.started` | stream |
| `stream.cancelled` | stream |
| `stream.cancel.denied` | stream |

Audit records **never** contain prompts, model output, conversation messages, or any AI-generated content. `ResourceId` carries the conversation/stream id — opaque.

## See also

- `docs/horse-ai-conversations-decision.md` — ADR for the full rationale.
- `docs/horse-session-decision.md` — identity source + shared audit schema.
- `docs/horse-ai-decision.md` — the AI provider abstraction this package wraps.
- `horse-ai/docs/multi-user-sessions.md` — the horse-ai-side explanation of what *was* left to the app, now partly absorbed into this package.
