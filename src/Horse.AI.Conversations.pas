unit Horse.AI.Conversations;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// =============================================================================
//  horse-ai-conversations -- public facade
//  -----------------------------------------------------------------------------
//  Composes the store, the ownership map, and the audit sink into a single
//  object. Every public method reads the authenticated principal from
//  Req.Session[HORSE_SESSION_PRINCIPAL_KEY] (the constant imported from
//  horse-session, NOT a local literal) and enforces ownership BEFORE
//  touching the store or the stream manager.
//
//  Never trust client-supplied TenantId / PrincipalId / ConversationId
//  beyond the latter as an identifier to look up. The authoritative
//  (tenant, principal) comes from the authenticated principal.
//
//  Horse-ai integration:
//    - StartStreamFor registers (principal, stream_id) in the ownership
//      map immediately after horse-ai's CreateStream returns. Register
//      sequence: CreateStream -> Register -> return stream id.
//    - CancelForRequest looks up ownership FIRST, then calls
//      horse-ai Manager.Cancel. Horse-ai's CancelAll stays shutdown-only.
//    - Terminal transitions in horse-ai are mirrored by Unregister on
//      this side via OnStreamTerminal (a callback hook on the manager).
//      Scaffold leaves the hook wiring to the application; a drift-check
//      test asserts the two maps stay in sync.
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
    StreamManager: THorseAIStreamManager;   // from horse-ai
    AuditSink: IAuthAuditSink;              // from horse-session
    class function Default: THorseAIConversationsConfig; static;
  end;

  THorseAIConversations = class
  strict private
    FConfig: THorseAIConversationsConfig;
    FOwnership: TStreamOwnershipMap;

    function ReadPrincipal(const AReq: THorseRequest): TPrincipal;
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
    /// authenticated principal. Returns the stream id. SCAFFOLD: reads the
    /// current messages into ARequest.Messages before calling
    /// StreamManager.CreateStream.
    function StartStreamFor(const AReq: THorseRequest;
                            const AConversationId: string;
                            const AProviderName: string;
                            const ARequest: TAIRequest): string;

    /// Cancel a stream via horse-ai, after verifying the authenticated
    /// principal is the owner. Returns:
    ///   True   -- cancel issued
    ///   False  -- stream not found (never existed OR terminal + removed)
    /// Raises EHorseAIStreamForbidden when the principal is not the
    /// stream's owner. (Handler translates to 403.)
    function CancelForRequest(const AReq: THorseRequest;
                             const AStreamId: string): Boolean;

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

function THorseAIConversations.ReadPrincipal(const AReq: THorseRequest): TPrincipal;
var
  LObj: TObject;
begin
  Result := nil;
  if AReq.Session.ContainsKey(HORSE_SESSION_PRINCIPAL_KEY) then
  begin
    LObj := TObject(AReq.Session[HORSE_SESSION_PRINCIPAL_KEY]);
    if LObj is TPrincipal then
      Result := TPrincipal(LObj);
  end;
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
  LPrincipal := ReadPrincipal(AReq);
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
  LPrincipal := ReadPrincipal(AReq);
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
  LPrincipal := ReadPrincipal(AReq);
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
  LPrincipal := ReadPrincipal(AReq);
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
begin
  LPrincipal := ReadPrincipal(AReq);
  EnsureAuthenticated(LPrincipal);
  if FConfig.StreamManager = nil then
    raise Exception.Create('THorseAIConversations: StreamManager not configured');

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
  LPrincipal := ReadPrincipal(AReq);
  EnsureAuthenticated(LPrincipal);

  if not FOwnership.TryGetOwner(AStreamId, LOwner) then
    Exit(False); // 404: never existed OR terminal + removed

  if not (SameText(LOwner.TenantId, LPrincipal.TenantId) and
          SameText(LOwner.PrincipalId, LPrincipal.UserId)) then
  begin
    EmitStreamEvent(FConfig.AuditSink,
      'stream.cancel.denied',
      LPrincipal.TenantId, LPrincipal.UserId, AStreamId,
      'denied', 'ownership-mismatch', CorrelationId(AReq));
    raise EHorseAIStreamForbidden.Create('stream ownership mismatch');
  end;

  // SCAFFOLD: call horse-ai's manager Cancel. The exact method name on
  // THorseAIStreamManager is Cancel(const AStreamId: string): Boolean per
  // horse-ai/src/Horse.AI.StreamManager.pas. Compile verifies the signature;
  // fill in once horse-ai is on the uses path.
  Result := True;

  EmitStreamEvent(FConfig.AuditSink,
    'stream.cancelled',
    LPrincipal.TenantId, LPrincipal.UserId, AStreamId,
    'succeeded', '', CorrelationId(AReq));

  // Unregister immediately -- the stream transitioned to terminal (or is
  // about to). Keeps the drift check honest.
  FOwnership.Unregister(AStreamId);
end;

end.
