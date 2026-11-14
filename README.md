# horse-ai-conversations
AI conversation ownership and persistence for Horse. Binds horse-session principals to horse-ai streams: (tenant_id, principal_id, conversation_id) tuple, ownership-checked cancel, multiple conversations per user, pluggable IAIConversationStore (in-memory default). Reuses horse-session's audit schema unchanged.
