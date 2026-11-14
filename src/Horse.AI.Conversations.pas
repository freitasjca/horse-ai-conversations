unit Horse.AI.Conversations;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// =============================================================================
//  horse-ai-conversations -- public facade
//  -----------------------------------------------------------------------------
//  Composes the store, the ownership map, and the audit sink into a single
//  object. Every public method reads the authenticated principal with
//  PrincipalOf(Req) from horse-session (Horse.Session.Types) and enforces
//  ownership BEFORE touching the store or the stream manager. The request
//  owns that principal; this unit never frees it.
//
//  Never trust client-supplied TenantId / PrincipalId / ConversationId
//  beyond the latter as an identifier to look up. The authoritative
//  (tenant, principal) comes from the authenticated principal.
//
//  Horse-ai integration:
//    - StartStreamFor first checks that the conversation belongs to the
//      principal, then: CreateStream -> Register ownership -> return id.
//    - CancelForRequest looks up ownership FIRST, then calls the manager's
//      Cancel. Horse-ai's CancelAll stays shutdown-only.
//    - When a stream ends on its own, horse-ai removes it from the manager
//      but nothing tells this unit. Call ForgetStream(stream id) from the
//      transport when that happens, or the ownership entry stays until a
//      cancel attempt finds the stream gone and drops it.
//
//  FPC NOTE: methods take a THorseRequest and operate imperatively; the
//  facade itself is NOT a middleware callback. Mount the horse-session
//  middleware and then compose the facade into your route handlers.
// =============================================================================

interface

uses
{$IF DEFINED(FPC)}
  SysUtils,
  Classes,
{$ELSE}
  System.SysUtils,
  System.Classes,
{$IFEND}
  Horse.Request,
  Horse.AI.Types,
  Horse.AI.StreamManager,
  Horse.Session.Types,
  Horse.Session.Audit,
  Horse.AI.Conversations.Types,
  Horse.AI.Conversations.Store,
  Horse.AI.Conversations.StreamOwnership,
  Horse.AI.Conversations.Audit;

type
  THorseAIConversationsConfig = record
    Store: IAIConversationStore;
    /// From horse-ai. Held as the interface: the manager is reference
    /// counted, and a class-typed field would not keep it alive.
    StreamManager: IHorseAIStreamManager;
    AuditSink: IAuthAuditSink;              // from horse-session
    class function Default: THorseAIConversationsConfig; static;
  end;

  THorseAIConversations = class
  strict private
    FConfig: THorseAIConversationsConfig;
    FOwnership: TStreamOwnershipMap;

    function CorrelationId(const AReq: THorseRequest): string;
    procedure EnsureAuthenticated(const APrincipal: TPrincipal);
  public
    constructor Create(const AConfig: THorseAIConversationsConfig);
    destructor Destroy; override;

    /// Create a new conversation owned by the authenticated principal.
    /// Raises EHorseSessionUnauthorized when the request is anonymous.
    function CreateFor(const AReq: THorseRequest;
                      const ATitle: string): TAIConversation;

    /// Fetch conversation metadata + current messages for the
    /// authenticated principal. Raises EHorseAIConversationNotFound on
    /// miss / mismatch / deleted.
    function GetFor(const AReq: THorseRequest;
                   const AConversationId: string;
                   out AConversation: TAIConversation;
                   out AMessages: TAIMessages): Boolean;

    /// Append a message. See IAIConversationStore.AppendMessage.
    procedure AppendFor(const AReq: THorseRequest;
                        const AConversationId: string;
                        const AMessage: TAIMessage);

    /// Logical delete. Returns True iff the record was flipped (first
    /// time) or was already deleted (idempotent).
    function DeleteFor(const AReq: THorseRequest;
                      const AConversationId: string): Boolean;

    /// Create a stream via horse-ai and register ownership against the
    /// authenticated principal. Returns the stream id. The conversation
    /// must belong to the principal: otherwise this raises
    /// EHorseAIConversationNotFound and no stream is created. ARequest is
    /// passed to horse-ai as given; build its Messages yourself (GetFor
    /// returns the stored ones).
    function StartStreamFor(const AReq: THorseRequest;
                            const AConversationId: string;
                            const AProviderName: string;
                            const ARequest: TAIRequest): string;

    /// Cancel a stream via horse-ai, after verifying the authenticated
    /// principal is the owner. Returns:
    ///   True   -- cancel issued
    ///   False  -- stream not found (never existed, already cancelled
    ///             here, or finished and removed by horse-ai)
    /// Raises EHorseAIStreamForbidden when the principal is not the
    /// stream's owner. (Handler translates to 403.) The stream of another
    /// principal is never touched.
    function CancelForRequest(const AReq: THorseRequest;
                             const AStreamId: string): Boolean;

    /// Drops the ownership entry of a stream that ended on its own.
    /// Returns True when an entry existed.
    function ForgetStream(const AStreamId: string): Boolean;

    property Ownership: TStreamOwnershipMap read FOwnership;
  end;

implementation

{ THorseAIConversationsConfig }

class function THorseAIConversationsConfig.Default: THorseAIConversationsConfig;
begin
  Result.Store := TMemoryConversationStore.Create;
  Result.StreamManager := nil; // caller MUST supply a real manager
  Result.AuditSink := TNullAuthAuditSink.Create;
end;

{ THorseAIConversations }

constructor THorseAIConversations.Create(const AConfig: THorseAIConversationsConfig);
begin
  inherited Create;
  FConfig := AConfig;
  FOwnership := TStreamOwnershipMap.Create;
end;

destructor THorseAIConversations.Destroy;
begin
  FOwnership.Free;
  inherited Destroy;
end;

function THorseAIConversations.CorrelationId(const AReq: THorseRequest): string;
begin
  Result := AReq.Headers['X-Request-ID'];
end;

procedure THorseAIConversations.EnsureAuthenticated(const APrincipal: TPrincipal);
begin
  if (APrincipal = nil) or not APrincipal.IsAuthenticated then
    raise EHorseSessionUnauthorized.Create('authentication required');
end;

function THorseAIConversations.CreateFor(const AReq: THorseRequest;
                                         const ATitle: string): TAIConversation;
var
  LPrincipal: TPrincipal;
begin
  LPrincipal := PrincipalOf(AReq);
  EnsureAuthenticated(LPrincipal);
  Result := FConfig.Store.CreateConversation(LPrincipal.TenantId,
                                             LPrincipal.UserId, ATitle);
  EmitConversationEvent(FConfig.AuditSink,
    'conversation.created',
    LPrincipal.TenantId, LPrincipal.UserId, Result.Id,
    'succeeded', '', CorrelationId(AReq));
end;

function THorseAIConversations.GetFor(const AReq: THorseRequest;
                                      const AConversationId: string;
                                      out AConversation: TAIConversation;
                                      out AMessages: TAIMessages): Boolean;
var
  LPrincipal: TPrincipal;
begin
  LPrincipal := PrincipalOf(AReq);
  EnsureAuthenticated(LPrincipal);
  Result := FConfig.Store.TryGet(LPrincipal.TenantId, LPrincipal.UserId,
                                 AConversationId, AConversation);
  if Result then
  begin
    FConfig.Store.TryGetMessages(LPrincipal.TenantId, LPrincipal.UserId,
                                 AConversationId, AMessages);
    EmitConversationEvent(FConfig.AuditSink,
      'conversation.accessed',
      LPrincipal.TenantId, LPrincipal.UserId, AConversationId,
      'granted', '', CorrelationId(AReq));
  end
  else
    EmitConversationEvent(FConfig.AuditSink,
      'conversation.access.denied',
      LPrincipal.TenantId, LPrincipal.UserId, AConversationId,
      'denied', 'not-found-or-ownership-mismatch', CorrelationId(AReq));
end;

procedure THorseAIConversations.AppendFor(const AReq: THorseRequest;
                                          const AConversationId: string;
                                          const AMessage: TAIMessage);
var
  LPrincipal: TPrincipal;
begin
  LPrincipal := PrincipalOf(AReq);
  EnsureAuthenticated(LPrincipal);
  FConfig.Store.AppendMessage(LPrincipal.TenantId, LPrincipal.UserId,
                              AConversationId, AMessage);
  // No dedicated 'conversation.message.appended' event in v1 -- high
  // volume, limited security value. Future audit middleware can plug
  // here if needed.
end;

function THorseAIConversations.DeleteFor(const AReq: THorseRequest;
                                         const AConversationId: string): Boolean;
var
  LPrincipal: TPrincipal;
begin
  LPrincipal := PrincipalOf(AReq);
  EnsureAuthenticated(LPrincipal);
  Result := FConfig.Store.Delete(LPrincipal.TenantId, LPrincipal.UserId,
                                 AConversationId);
  EmitConversationEvent(FConfig.AuditSink,
    'conversation.deleted',
    LPrincipal.TenantId, LPrincipal.UserId, AConversationId,
    'succeeded', '', CorrelationId(AReq));
end;

function THorseAIConversations.StartStreamFor(const AReq: THorseRequest;
                                              const AConversationId: string;
                                              const AProviderName: string;
                                              const ARequest: TAIRequest): string;
var
  LPrincipal: TPrincipal;
  LOwner: TStreamOwnerKey;
  LConversation: TAIConversation;
begin
  LPrincipal := PrincipalOf(AReq);
  EnsureAuthenticated(LPrincipal);
  if FConfig.StreamManager = nil then
    raise Exception.Create('THorseAIConversations: StreamManager not configured');

  // The conversation must be the caller's own before anything is started.
  if not FConfig.Store.TryGet(LPrincipal.TenantId, LPrincipal.UserId,
                              AConversationId, LConversation) then
  begin
    EmitConversationEvent(FConfig.AuditSink,
      'conversation.access.denied',
      LPrincipal.TenantId, LPrincipal.UserId, AConversationId,
      'denied', 'not-found-or-ownership-mismatch', CorrelationId(AReq));
    raise EHorseAIConversationNotFound.Create('conversation not found');
  end;

  Result := FConfig.StreamManager.CreateStream(AProviderName, ARequest);

  LOwner.TenantId := LPrincipal.TenantId;
  LOwner.PrincipalId := LPrincipal.UserId;
  LOwner.ConversationId := AConversationId;
  FOwnership.Register(Result, LOwner);

  EmitStreamEvent(FConfig.AuditSink,
    'stream.started',
    LPrincipal.TenantId, LPrincipal.UserId, Result,
    'succeeded', '', CorrelationId(AReq));
end;

function THorseAIConversations.CancelForRequest(const AReq: THorseRequest;
                                                const AStreamId: string): Boolean;
var
  LPrincipal: TPrincipal;
  LOwner: TStreamOwnerKey;
begin
  LPrincipal := PrincipalOf(AReq);
  EnsureAuthenticated(LPrincipal);
  if FConfig.StreamManager = nil then
    raise Exception.Create('THorseAIConversations: StreamManager not configured');

  if not FOwnership.TryGetOwner(AStreamId, LOwner) then
    Exit(False); // 404: never existed OR already cancelled / forgotten

  // Exact match: two ids that differ only by letter case are two owners.
  if not ((LOwner.TenantId = LPrincipal.TenantId) and
          (LOwner.PrincipalId = LPrincipal.UserId)) then
  begin
    EmitStreamEvent(FConfig.AuditSink,
      'stream.cancel.denied',
      LPrincipal.TenantId, LPrincipal.UserId, AStreamId,
      'denied', 'ownership-mismatch', CorrelationId(AReq));
    raise EHorseAIStreamForbidden.Create('stream ownership mismatch');
  end;

  // The caller owns the stream. Cancel flips the stream's cancel flag;
  // horse-ai's transport notices it and ends the stream. False means the
  // manager no longer has it (it finished and was removed).
  Result := FConfig.StreamManager.Cancel(AStreamId);

  // Either way the entry is done with: cancelled now, or already gone.
  FOwnership.Unregister(AStreamId);

  if Result then
    EmitStreamEvent(FConfig.AuditSink,
      'stream.cancelled',
      LPrincipal.TenantId, LPrincipal.UserId, AStreamId,
      'succeeded', '', CorrelationId(AReq));
end;

function THorseAIConversations.ForgetStream(const AStreamId: string): Boolean;
begin
  Result := FOwnership.Unregister(AStreamId);
end;

end.
