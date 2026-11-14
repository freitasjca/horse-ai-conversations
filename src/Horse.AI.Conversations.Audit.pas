unit Horse.AI.Conversations.Audit;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// =============================================================================
//  horse-ai-conversations -- audit helpers (consume horse-session's sink)
//  -----------------------------------------------------------------------------
//  This unit does NOT declare an audit interface or record. It uses
//  horse-session's TAuthAuditEvent + IAuthAuditSink UNCHANGED and reserves
//  two Action prefixes in the ecosystem vocabulary (declared in
//  Horse.Session.Audit's unit header):
//
//    conversation.{created, accessed, access.denied, deleted}
//    stream.{started, cancelled, cancel.denied}
//
//  Records carry conversation/stream id in ResourceId, NEVER messages or
//  prompts (ADR §Known limitations v1).
// =============================================================================

interface

uses
{$IF DEFINED(FPC)}
  SysUtils,
{$ELSE}
  System.SysUtils,
{$IFEND}
  // horse-session is a hard dependency of this package; its Audit unit
  // owns the record and the interface.
  Horse.Session.Audit;

/// Emit a conversation-level event. Translates to a shared TAuthAuditEvent
/// with ResourceType='conversation'.
procedure EmitConversationEvent(const ASink: IAuthAuditSink;
                                const AAction, ATenantId, APrincipalId,
                                AConversationId, AOutcome, AReason,
                                ACorrelationId: string);

/// Emit a stream-level event. Translates to a shared TAuthAuditEvent with
/// ResourceType='stream'.
procedure EmitStreamEvent(const ASink: IAuthAuditSink;
                          const AAction, ATenantId, APrincipalId,
                          AStreamId, AOutcome, AReason,
                          ACorrelationId: string);

implementation

procedure EmitConversationEvent(const ASink: IAuthAuditSink;
                                const AAction, ATenantId, APrincipalId,
                                AConversationId, AOutcome, AReason,
                                ACorrelationId: string);
var
  LEvent: TAuthAuditEvent;
begin
  if ASink = nil then Exit;
  LEvent := MakeAuthEvent(AAction, ATenantId, APrincipalId,
                          'conversation', AConversationId,
                          AOutcome, AReason, ACorrelationId);
  // An exception from the sink propagates to the caller: an audit sink
  // that must never break a request has to swallow its own errors.
  ASink.RecordEvent(LEvent);
end;

procedure EmitStreamEvent(const ASink: IAuthAuditSink;
                          const AAction, ATenantId, APrincipalId,
                          AStreamId, AOutcome, AReason,
                          ACorrelationId: string);
var
  LEvent: TAuthAuditEvent;
begin
  if ASink = nil then Exit;
  LEvent := MakeAuthEvent(AAction, ATenantId, APrincipalId,
                          'stream', AStreamId,
                          AOutcome, AReason, ACorrelationId);
  ASink.RecordEvent(LEvent);
end;

end.
