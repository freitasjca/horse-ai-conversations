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
  Horse,
  Horse.Session,
  Horse.Session.Types,
  Horse.AI,
  Horse.AI.Conversations,
  Horse.AI.Conversations.Types,
  Horse.AI.Conversations.Store;

var
  LConvConfig: THorseAIConversationsConfig;
  LStore: IAIConversationStore;
begin
  // 1. horse-session establishes identity
  THorse.Use(THorseSession.New({ your session config }));

  // 2. horse-ai-conversations binds streams + conversations to principals
  LStore := TMemoryConversationStore.Create;
  LConvConfig := THorseAIConversationsConfig.Default;
  LConvConfig.Store := LStore;
  LConvConfig.StreamManager := { your horse-ai THorseAIStreamManager };
  THorse.Use(THorseAIConversations.New(LConvConfig));

  // 3. Route handlers use the facade to enforce ownership on every call
  THorse.Post('/conversations/:id/messages',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      // THorseAIConversations reads the principal from Req.Session[...]
      // and emits 401/403 on the way to the store.
    end);

  THorse.Listen(9000);
end.
```

## Ownership-check sequence

```
DELETE /streams/{id}
      |
  horse-session middleware  -> Req.Session[HORSE_SESSION_PRINCIPAL_KEY]
      |
  TStreamOwnershipGuard middleware (preValidation)
      |
  if not authenticated       -> 401
  if owner != principal      -> 403
  if stream_id not in map    -> 404  (terminal + removed OR never existed)
      |
  Call horse-ai Manager.Cancel(stream_id)
      |
  Audit sink: stream.cancelled(principal, stream_id, outcome)
      |
  204 No Content
```

Stream IDs are **never reused**. A `strm_<uuid>` whose state transitioned to terminal is removed from both horse-ai's manager and this package's ownership map. A second DELETE of the same id answers 404, not 403.

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
