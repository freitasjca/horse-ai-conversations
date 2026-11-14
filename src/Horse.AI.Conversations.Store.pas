unit Horse.AI.Conversations.Store;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// =============================================================================
//  horse-ai-conversations -- store contract + in-memory implementation
//  -----------------------------------------------------------------------------
//  IAIConversationStore methods ALL take (ATenantId, APrincipalId,
//  AConversationId). Ownership is part of the signature; a store
//  implementation that accepts a bare conversation id and "trusts the
//  caller" fails the conformance suite.
//
//  Thread-safety contract (see docs/horse-ai-conversations-decision.md
//  §Thread safety):
//    Implementations MUST be safe for concurrent calls from arbitrary
//    threads. The interface makes no thread-affinity guarantees.
//    TMemoryConversationStore uses TCriticalSection from day one, holds
//    the lock only for internal dictionary operations, NEVER across an
//    external callback, and returns copies of TAIMessages -- never a
//    mutable internal buffer.
//
//  Logical delete:
//    DeleteConversation flips Deleted=True on the record. Physical cleanup
//    is the store implementation's choice (never in the in-memory default).
//    A conversation whose Deleted=True is invisible to Get / List but
//    audit records still carry its id.
// =============================================================================

interface

uses
{$IF DEFINED(FPC)}
  SysUtils,
  Classes,
  SyncObjs,
  Generics.Collections,
{$ELSE}
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections,
{$IFEND}
  Horse.AI.Types,                 // TAIMessage, TAIMessages
  Horse.AI.Conversations.Types;

type
  /// Stable ecosystem contract. Every method takes the ownership triple.
  /// Durable adapters (Redis, Postgres, FireDAC) implement this unchanged.
  IAIConversationStore = interface
    ['{8B5A7D1E-3C94-4F02-9E6A-2B4F8D1C7A95}']

    /// Create a new conversation owned by (tenant, principal) with the
    /// given title. Returns the full record (Id is freshly allocated).
    function CreateConversation(const ATenantId, APrincipalId,
                                ATitle: string): TAIConversation;

    /// Fetch a conversation's metadata (without messages). Returns False
    /// when the id is unknown, the triple mismatches, OR the record is
    /// logically deleted.
    function TryGet(const ATenantId, APrincipalId, AConversationId: string;
                   out AConversation: TAIConversation): Boolean;

    /// List the (tenant, principal)'s conversations, newest first.
    /// Deleted records are omitted.
    function List(const ATenantId, APrincipalId: string): TArray<TAIConversationSummary>;

    /// Fetch the message history for a conversation. Returns False on
    /// miss / mismatch / deleted.
    function TryGetMessages(const ATenantId, APrincipalId, AConversationId: string;
                           out AMessages: TAIMessages): Boolean;

    /// Append a message. Bumps UpdatedAt. Raises
    /// EHorseAIConversationNotFound on miss / mismatch / deleted.
    procedure AppendMessage(const ATenantId, APrincipalId, AConversationId: string;
                            const AMessage: TAIMessage);

    /// Logical delete. Returns True when the record was flipped; False
    /// when the id is unknown or the triple mismatches.
    function Delete(const ATenantId, APrincipalId, AConversationId: string): Boolean;
  end;

  /// In-memory implementation. Suitable for development and single-process
  /// deployments only -- NOT durable across process restarts. Production
  /// installs a sibling adapter.
  TMemoryConversationStore = class(TInterfacedObject, IAIConversationStore)
  strict private
    type
      TMemRow = record
        Record_: TAIConversation;
        Messages: TAIMessages;
      end;
    var
      FLock: TCriticalSection;
      FRows: TDictionary<string, TMemRow>;

    function OwnedBy(const ARow: TMemRow;
                    const ATenantId, APrincipalId: string): Boolean;
    function CopyMessages(const AMessages: TAIMessages): TAIMessages;
  public
    constructor Create;
    destructor Destroy; override;

    function CreateConversation(const ATenantId, APrincipalId,
                                ATitle: string): TAIConversation;
    function TryGet(const ATenantId, APrincipalId, AConversationId: string;
                   out AConversation: TAIConversation): Boolean;
    function List(const ATenantId, APrincipalId: string): TArray<TAIConversationSummary>;
    function TryGetMessages(const ATenantId, APrincipalId, AConversationId: string;
                           out AMessages: TAIMessages): Boolean;
    procedure AppendMessage(const ATenantId, APrincipalId, AConversationId: string;
                            const AMessage: TAIMessage);
    function Delete(const ATenantId, APrincipalId, AConversationId: string): Boolean;
  end;

implementation

{ TMemoryConversationStore }

constructor TMemoryConversationStore.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FRows := TDictionary<string, TMemRow>.Create;
end;

destructor TMemoryConversationStore.Destroy;
begin
  FRows.Free;
  FLock.Free;
  inherited Destroy;
end;

function TMemoryConversationStore.OwnedBy(const ARow: TMemRow;
                                          const ATenantId, APrincipalId: string): Boolean;
begin
  // Exact match: two ids that differ only by letter case are two owners.
  Result := (ARow.Record_.TenantId = ATenantId) and
            (ARow.Record_.PrincipalId = APrincipalId);
end;

function TMemoryConversationStore.CopyMessages(const AMessages: TAIMessages): TAIMessages;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(AMessages));
  for I := 0 to High(AMessages) do
    Result[I] := AMessages[I];
end;

function TMemoryConversationStore.CreateConversation(const ATenantId, APrincipalId,
                                                     ATitle: string): TAIConversation;
var
  LRow: TMemRow;
begin
  LRow.Record_.Id := NewConversationId;
  LRow.Record_.TenantId := ATenantId;
  LRow.Record_.PrincipalId := APrincipalId;
  LRow.Record_.Title := ATitle;
  LRow.Record_.CreatedAt := Now;
  LRow.Record_.UpdatedAt := LRow.Record_.CreatedAt;
  LRow.Record_.Deleted := False;
  SetLength(LRow.Messages, 0);

  FLock.Enter;
  try
    FRows.Add(LRow.Record_.Id, LRow);
  finally
    FLock.Leave;
  end;

  Result := LRow.Record_;
end;

function TMemoryConversationStore.TryGet(const ATenantId, APrincipalId,
                                         AConversationId: string;
                                         out AConversation: TAIConversation): Boolean;
var
  LRow: TMemRow;
begin
  Result := False;
  FLock.Enter;
  try
    if not FRows.TryGetValue(AConversationId, LRow) then
      Exit;
    if LRow.Record_.Deleted then
      Exit;
    if not OwnedBy(LRow, ATenantId, APrincipalId) then
      Exit;
    AConversation := LRow.Record_;
    Result := True;
  finally
    FLock.Leave;
  end;
end;

function TMemoryConversationStore.List(const ATenantId, APrincipalId: string): TArray<TAIConversationSummary>;
var
  LRow: TMemRow;
  LCount: Integer;
  LSummary: TAIConversationSummary;
begin
  Result := nil;
  FLock.Enter;
  try
    LCount := 0;
    for LRow in FRows.Values do
    begin
      if LRow.Record_.Deleted then Continue;
      if not OwnedBy(LRow, ATenantId, APrincipalId) then Continue;
      LSummary.Id := LRow.Record_.Id;
      LSummary.Title := LRow.Record_.Title;
      LSummary.CreatedAt := LRow.Record_.CreatedAt;
      LSummary.UpdatedAt := LRow.Record_.UpdatedAt;
      LSummary.MessageCount := Length(LRow.Messages);
      Inc(LCount);
      SetLength(Result, LCount);
      Result[LCount - 1] := LSummary;
    end;
  finally
    FLock.Leave;
  end;
end;

function TMemoryConversationStore.TryGetMessages(const ATenantId, APrincipalId,
                                                 AConversationId: string;
                                                 out AMessages: TAIMessages): Boolean;
var
  LRow: TMemRow;
begin
  Result := False;
  FLock.Enter;
  try
    if not FRows.TryGetValue(AConversationId, LRow) then Exit;
    if LRow.Record_.Deleted then Exit;
    if not OwnedBy(LRow, ATenantId, APrincipalId) then Exit;
    AMessages := CopyMessages(LRow.Messages);  // snapshot, not alias
    Result := True;
  finally
    FLock.Leave;
  end;
end;

procedure TMemoryConversationStore.AppendMessage(const ATenantId, APrincipalId,
                                                 AConversationId: string;
                                                 const AMessage: TAIMessage);
var
  LRow: TMemRow;
  LLen: Integer;
begin
  FLock.Enter;
  try
    if not FRows.TryGetValue(AConversationId, LRow) then
      raise EHorseAIConversationNotFound.CreateFmt('conversation %s not found', [AConversationId]);
    if LRow.Record_.Deleted then
      raise EHorseAIConversationNotFound.CreateFmt('conversation %s deleted', [AConversationId]);
    if not OwnedBy(LRow, ATenantId, APrincipalId) then
      raise EHorseAIConversationForbidden.CreateFmt('conversation %s ownership mismatch', [AConversationId]);

    LLen := Length(LRow.Messages);
    SetLength(LRow.Messages, LLen + 1);
    LRow.Messages[LLen] := AMessage;
    LRow.Record_.UpdatedAt := Now;
    FRows.AddOrSetValue(AConversationId, LRow);
  finally
    FLock.Leave;
  end;
end;

function TMemoryConversationStore.Delete(const ATenantId, APrincipalId,
                                         AConversationId: string): Boolean;
var
  LRow: TMemRow;
begin
  Result := False;
  FLock.Enter;
  try
    if not FRows.TryGetValue(AConversationId, LRow) then Exit;
    if not OwnedBy(LRow, ATenantId, APrincipalId) then Exit;
    if LRow.Record_.Deleted then Exit(True); // idempotent
    LRow.Record_.Deleted := True;
    LRow.Record_.UpdatedAt := Now;
    FRows.AddOrSetValue(AConversationId, LRow);
    Result := True;
  finally
    FLock.Leave;
  end;
end;

end.
