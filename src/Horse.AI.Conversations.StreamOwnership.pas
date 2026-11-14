unit Horse.AI.Conversations.StreamOwnership;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// =============================================================================
//  horse-ai-conversations -- stream ownership map
//  -----------------------------------------------------------------------------
//  Separate map, keyed by StreamId, that remembers which (tenant, principal)
//  started each stream. When the user hits DELETE /streams/:id,
//  THorseAIConversations.CancelForRequest reads the principal from Req,
//  checks ownership against this map, and only then calls horse-ai's
//  Manager.Cancel. horse-ai's CancelAll stays shutdown-only.
//
//  Discipline required: every CreateStream has a matching Register call;
//  every MarkTerminal + Remove has a matching Unregister. The scaffold's
//  THorseAIConversations facade does this bookkeeping; a test asserts the
//  map stays in sync with horse-ai's own stream manager.
//
//  v2 moves this into horse-ai as a per-stream OwnerKey field on
//  THorseAIStreamState; this unit then shrinks to a thin reader.
// =============================================================================

interface

uses
{$IF DEFINED(FPC)}
  SysUtils,
  Classes,
  SyncObjs,
  Generics.Collections;
{$ELSE}
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections;
{$IFEND}

type
  TStreamOwnerKey = record
    TenantId: string;
    PrincipalId: string;
    ConversationId: string;
  end;

  TStreamOwnershipMap = class
  strict private
    FLock: TCriticalSection;
    FOwners: TDictionary<string, TStreamOwnerKey>; // StreamId -> owner
  public
    constructor Create;
    destructor Destroy; override;

    procedure Register(const AStreamId: string; const AOwner: TStreamOwnerKey);
    function TryGetOwner(const AStreamId: string; out AOwner: TStreamOwnerKey): Boolean;
    function IsOwner(const AStreamId, ATenantId, APrincipalId: string): Boolean;
    function Unregister(const AStreamId: string): Boolean;
    function Count: Integer;
    procedure Clear;

    /// Diagnostic snapshot -- intended for the test suite's drift check:
    /// every entry here must correspond to a live stream in horse-ai's
    /// THorseAIStreamManager (and vice versa).
    function Snapshot: TArray<string>;
  end;

implementation

{ TStreamOwnershipMap }

constructor TStreamOwnershipMap.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FOwners := TDictionary<string, TStreamOwnerKey>.Create;
end;

destructor TStreamOwnershipMap.Destroy;
begin
  FOwners.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TStreamOwnershipMap.Register(const AStreamId: string;
                                       const AOwner: TStreamOwnerKey);
begin
  FLock.Enter;
  try
    FOwners.AddOrSetValue(AStreamId, AOwner);
  finally
    FLock.Leave;
  end;
end;

function TStreamOwnershipMap.TryGetOwner(const AStreamId: string;
                                         out AOwner: TStreamOwnerKey): Boolean;
begin
  FLock.Enter;
  try
    Result := FOwners.TryGetValue(AStreamId, AOwner);
  finally
    FLock.Leave;
  end;
end;

function TStreamOwnershipMap.IsOwner(const AStreamId, ATenantId,
                                     APrincipalId: string): Boolean;
var
  LOwner: TStreamOwnerKey;
begin
  Result := False;
  if not TryGetOwner(AStreamId, LOwner) then Exit;
  // Exact match: two ids that differ only by letter case are two owners.
  Result := (LOwner.TenantId = ATenantId) and
            (LOwner.PrincipalId = APrincipalId);
end;

function TStreamOwnershipMap.Unregister(const AStreamId: string): Boolean;
begin
  FLock.Enter;
  try
    Result := FOwners.ContainsKey(AStreamId);
    FOwners.Remove(AStreamId);
  finally
    FLock.Leave;
  end;
end;

function TStreamOwnershipMap.Count: Integer;
begin
  FLock.Enter;
  try
    Result := FOwners.Count;
  finally
    FLock.Leave;
  end;
end;

procedure TStreamOwnershipMap.Clear;
begin
  FLock.Enter;
  try
    FOwners.Clear;
  finally
    FLock.Leave;
  end;
end;

function TStreamOwnershipMap.Snapshot: TArray<string>;
var
  LKey: string;
  I: Integer;
begin
  Result := nil;
  FLock.Enter;
  try
    SetLength(Result, FOwners.Count);
    I := 0;
    for LKey in FOwners.Keys do
    begin
      Result[I] := LKey;
      Inc(I);
    end;
  finally
    FLock.Leave;
  end;
end;

end.
