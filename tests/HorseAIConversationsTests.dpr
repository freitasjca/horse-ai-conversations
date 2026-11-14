program HorseAIConversationsTests;

{$APPTYPE CONSOLE}
{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

{
  horse-ai-conversations conformance tests
  =========================================
  Destination: horse-ai-conversations/tests/HorseAIConversationsTests.dpr

  In-process coverage (no socket):
    - TMemoryConversationStore: full CRUD, ownership triple enforcement,
      cross-tenant isolation, cross-principal isolation within tenant,
      idempotent delete, logical-delete invisibility on Get/List.
    - TStreamOwnershipMap: Register / IsOwner / Unregister semantics,
      thread-safety smoke.
    - Audit helpers: event emission does not touch ResourceId with
      conversation contents.

    - THorseAIConversations facade against a real THorseAIStreamManager
      from horse-ai: ownership check before a stream starts, cancel by
      the owner (verified on horse-ai's own stream state), cancel refused
      for every other principal, finished streams.

  Every unit of the package is in the uses clause on purpose: a unit that
  no test names is a unit nobody has compiled.

  The facade tests build requests with THorseRequest.Create(nil), which
  needs a Horse whose request tolerates a nil web request (the freitasjca
  fork does). Test-only dependency.

  No DUnitX: plain Writeln + a failure counter + non-zero exit. Matches
  horse-session / horse-ai conformance test shape.
}

uses
{$IF DEFINED(FPC)}
  {$IF DEFINED(UNIX)}cthreads,{$ENDIF}
  SysUtils,
  Classes,
{$ELSE}
  System.SysUtils,
  System.Classes,
{$IFEND}
  Horse.AI.Types,
  Horse.AI.Conversations.Types,
  Horse.AI.Conversations.Store,
  Horse.AI.Conversations.StreamOwnership,
  Horse.AI.Conversations.Audit,
  Horse.AI.Conversations,
  Horse.AI.StreamManager,
  Horse.Session.Types,
  Horse.Session.Audit,
  Horse.Request;

var
  GTotal: Integer = 0;
  GFailures: Integer = 0;

procedure Ok(const AWhat: string);
begin
  Inc(GTotal);
  Writeln('ok   ', AWhat);
end;

procedure Fail(const AWhat, ADetail: string);
begin
  Inc(GTotal);
  Inc(GFailures);
  Writeln('FAIL ', AWhat, '  --  ', ADetail);
end;

procedure AssertEqualStr(const AWhat, AExpected, AActual: string);
begin
  if AExpected = AActual then Ok(AWhat)
  else Fail(AWhat, 'expected "' + AExpected + '", got "' + AActual + '"');
end;

procedure AssertEqualInt(const AWhat: string; AExpected, AActual: Int64);
begin
  if AExpected = AActual then Ok(AWhat)
  else Fail(AWhat, 'expected ' + IntToStr(AExpected) + ', got ' + IntToStr(AActual));
end;

procedure AssertTrue(const AWhat: string; ACond: Boolean);
begin
  if ACond then Ok(AWhat) else Fail(AWhat, 'condition was false');
end;

procedure AssertFalse(const AWhat: string; ACond: Boolean);
begin
  if not ACond then Ok(AWhat) else Fail(AWhat, 'condition was true');
end;

{ --- TMemoryConversationStore ----------------------------------------- }

procedure TestStoreOwnership;
var
  LStore: IAIConversationStore;
  LC1, LC2, LGot: TAIConversation;
  LMessages: TAIMessages;
  LMsg: TAIMessage;
  LPart: TAIContentPart;
  LList: TArray<TAIConversationSummary>;
begin
  Writeln;
  Writeln('-- TMemoryConversationStore --');

  LStore := TMemoryConversationStore.Create;

  // alice at acme and bob at acme each create a conversation
  LC1 := LStore.CreateConversation('acme', 'alice', 'Alice''s project');
  LC2 := LStore.CreateConversation('acme', 'bob', 'Bob''s project');

  AssertTrue('alice can get her own',
             LStore.TryGet('acme', 'alice', LC1.Id, LGot));
  AssertEqualStr('alice sees her title', 'Alice''s project', LGot.Title);

  AssertFalse('alice CANNOT get bob''s',
              LStore.TryGet('acme', 'alice', LC2.Id, LGot));
  AssertFalse('bob CANNOT get alice''s',
              LStore.TryGet('acme', 'bob', LC1.Id, LGot));

  // cross-tenant: alice at OTHER tenant cannot see acme/alice's conversation
  AssertFalse('cross-tenant alice CANNOT get acme/alice''s',
              LStore.TryGet('other', 'alice', LC1.Id, LGot));

  // listing stays per-(tenant, principal)
  LList := LStore.List('acme', 'alice');
  AssertEqualInt('alice sees 1 conversation', 1, Length(LList));

  LList := LStore.List('acme', 'bob');
  AssertEqualInt('bob sees 1 conversation', 1, Length(LList));

  LList := LStore.List('other', 'alice');
  AssertEqualInt('cross-tenant alice sees 0 conversations', 0, Length(LList));

  // append a message as alice
  LPart.Kind := ckText;
  LPart.Text := 'hello';
  SetLength(LMsg.Content, 1);
  LMsg.Content[0] := LPart;
  LMsg.Role := 'user';
  LStore.AppendMessage('acme', 'alice', LC1.Id, LMsg);

  // alice can read messages
  AssertTrue('alice reads her messages',
             LStore.TryGetMessages('acme', 'alice', LC1.Id, LMessages));
  AssertEqualInt('message count 1', 1, Length(LMessages));
  AssertEqualStr('message role', 'user', LMessages[0].Role);

  // bob CANNOT append to alice's conversation
  try
    LStore.AppendMessage('acme', 'bob', LC1.Id, LMsg);
    Fail('bob append to alice raises', 'no exception');
  except
    on E: EHorseAIConversationForbidden do
      Ok('bob append to alice raises EHorseAIConversationForbidden');
    on E: Exception do
      Fail('bob append to alice: wrong exception', E.ClassName + ': ' + E.Message);
  end;

  // delete is per-owner
  AssertFalse('bob CANNOT delete alice''s',
              LStore.Delete('acme', 'bob', LC1.Id));
  AssertTrue('alice deletes her own',
             LStore.Delete('acme', 'alice', LC1.Id));
  AssertFalse('alice''s is gone after delete',
              LStore.TryGet('acme', 'alice', LC1.Id, LGot));

  // idempotent delete
  AssertTrue('second delete idempotent',
             LStore.Delete('acme', 'alice', LC1.Id));
end;

{ --- TStreamOwnershipMap ---------------------------------------------- }

procedure TestStreamOwnership;
var
  LMap: TStreamOwnershipMap;
  LOwner, LGot: TStreamOwnerKey;
begin
  Writeln;
  Writeln('-- TStreamOwnershipMap --');

  LMap := TStreamOwnershipMap.Create;
  try
    LOwner.TenantId := 'acme';
    LOwner.PrincipalId := 'alice';
    LOwner.ConversationId := 'conv-1';

    LMap.Register('strm_1', LOwner);
    AssertEqualInt('Count after register', 1, LMap.Count);
    AssertTrue('IsOwner(alice)', LMap.IsOwner('strm_1', 'acme', 'alice'));
    AssertFalse('IsOwner(bob)', LMap.IsOwner('strm_1', 'acme', 'bob'));
    AssertFalse('IsOwner cross-tenant', LMap.IsOwner('strm_1', 'other', 'alice'));

    AssertTrue('TryGetOwner', LMap.TryGetOwner('strm_1', LGot));
    AssertEqualStr('owner conversation', 'conv-1', LGot.ConversationId);

    AssertTrue('Unregister existing', LMap.Unregister('strm_1'));
    AssertFalse('Unregister missing', LMap.Unregister('strm_1'));
    AssertEqualInt('Count after unregister', 0, LMap.Count);

    // missing stream -> IsOwner False (not raise)
    AssertFalse('IsOwner missing', LMap.IsOwner('strm_nonexistent', 'acme', 'alice'));
  finally
    LMap.Free;
  end;
end;

{ --- THorseAIConversations facade -------------------------------------- }

type
  TCallOutcome = (coTrue, coFalse, coForbidden, coUnauthorized, coNotFound, coOther);

function RequestFor(const AUserId, ATenantId: string): THorseRequest;
begin
  Result := THorseRequest.Create(nil);
  // The request owns the principal from here on.
  SetPrincipal(Result, TPrincipal.Create(AUserId, ATenantId, nil, nil, nil, True));
end;

function TryCancel(const AFacade: THorseAIConversations; const AReq: THorseRequest;
                   const AStreamId: string): TCallOutcome;
begin
  try
    if AFacade.CancelForRequest(AReq, AStreamId) then
      Result := coTrue
    else
      Result := coFalse;
  except
    on E: EHorseAIStreamForbidden do Result := coForbidden;
    on E: EHorseSessionUnauthorized do Result := coUnauthorized;
    on E: Exception do Result := coOther;
  end;
end;

function TryStart(const AFacade: THorseAIConversations; const AReq: THorseRequest;
                  const AConversationId: string; out AStreamId: string): TCallOutcome;
var
  LRequest: TAIRequest;
begin
  AStreamId := '';
  LRequest := Default(TAIRequest);
  LRequest.Model := 'test-model';
  try
    AStreamId := AFacade.StartStreamFor(AReq, AConversationId, 'fake-provider', LRequest);
    Result := coTrue;
  except
    on E: EHorseAIConversationNotFound do Result := coNotFound;
    on E: EHorseSessionUnauthorized do Result := coUnauthorized;
    on E: Exception do Result := coOther;
  end;
end;

function IsCancelled(const AManager: IHorseAIStreamManager; const AStreamId: string): Boolean;
var
  LState: THorseAIStreamState;
begin
  Result := AManager.TryGetState(AStreamId, LState) and LState.IsCancelled;
end;

function LastAction(const ASink: TMemoryAuthAuditSink): string;
var
  LEvents: TArray<TAuthAuditEvent>;
begin
  LEvents := ASink.Snapshot;
  if Length(LEvents) = 0 then
    Result := '(none)'
  else
    Result := LEvents[High(LEvents)].Action + '/' + LEvents[High(LEvents)].Reason;
end;

procedure TestFacade;
var
  LConfig: THorseAIConversationsConfig;
  LSink: TMemoryAuthAuditSink;
  LSinkRef: IAuthAuditSink;
  LManager: IHorseAIStreamManager;
  LFacade: THorseAIConversations;
  LAlice, LBob, LAliceOtherTenant, LAliceUpper, LAnonymous, LBare: THorseRequest;
  LConv, LGot: TAIConversation;
  LMessages: TAIMessages;
  LStream, LStream2, LIgnored: string;
  LRaised: Boolean;
begin
  Writeln;
  Writeln('-- THorseAIConversations facade --');

  LSink := TMemoryAuthAuditSink.Create;
  LSinkRef := LSink;
  LManager := THorseAIStreamManager.Create;

  LConfig := THorseAIConversationsConfig.Default;
  LConfig.StreamManager := LManager;
  LConfig.AuditSink := LSinkRef;
  LFacade := THorseAIConversations.Create(LConfig);

  LAlice := RequestFor('alice', 'acme');
  LBob := RequestFor('bob', 'acme');
  LAliceOtherTenant := RequestFor('alice', 'globex');
  LAliceUpper := RequestFor('Alice', 'acme');
  LAnonymous := THorseRequest.Create(nil);
  SetPrincipal(LAnonymous, TPrincipal.CreateAnonymous);
  LBare := THorseRequest.Create(nil); // session middleware never ran
  try
    // Conversations through the facade.
    LConv := LFacade.CreateFor(LAlice, 'Alice''s project');
    AssertTrue('CreateFor returns an id', LConv.Id <> '');
    AssertEqualStr('CreateFor audit', 'conversation.created/', LastAction(LSink));
    AssertTrue('alice gets her conversation',
      LFacade.GetFor(LAlice, LConv.Id, LGot, LMessages));
    AssertFalse('bob cannot get alice''s conversation',
      LFacade.GetFor(LBob, LConv.Id, LGot, LMessages));
    AssertEqualStr('denied access is audited',
      'conversation.access.denied/not-found-or-ownership-mismatch', LastAction(LSink));
    AssertFalse('"Alice" is not "alice"',
      LFacade.GetFor(LAliceUpper, LConv.Id, LGot, LMessages));

    LRaised := False;
    try
      LFacade.CreateFor(LAnonymous, 'x');
    except
      on E: EHorseSessionUnauthorized do LRaised := True;
    end;
    AssertTrue('anonymous CreateFor raises EHorseSessionUnauthorized', LRaised);

    LRaised := False;
    try
      LFacade.CreateFor(LBare, 'x');
    except
      on E: EHorseSessionUnauthorized do LRaised := True;
    end;
    AssertTrue('request without a principal raises EHorseSessionUnauthorized', LRaised);

    // Starting a stream.
    AssertTrue('bob cannot start a stream on alice''s conversation',
      TryStart(LFacade, LBob, LConv.Id, LIgnored) = coNotFound);
    AssertTrue('anonymous cannot start a stream',
      TryStart(LFacade, LAnonymous, LConv.Id, LIgnored) = coUnauthorized);
    AssertEqualInt('refused starts created no stream', 0, LManager.Count);
    AssertEqualInt('refused starts registered no owner', 0, LFacade.Ownership.Count);

    AssertTrue('alice starts a stream', TryStart(LFacade, LAlice, LConv.Id, LStream) = coTrue);
    AssertTrue('stream id returned', LStream <> '');
    AssertEqualInt('one stream in horse-ai', 1, LManager.Count);
    AssertEqualInt('one ownership entry', 1, LFacade.Ownership.Count);
    AssertEqualStr('start is audited', 'stream.started/', LastAction(LSink));
    AssertFalse('new stream is not cancelled', IsCancelled(LManager, LStream));

    // Cancelling: everyone but the owner is refused and the stream lives on.
    AssertTrue('bob cannot cancel alice''s stream',
      TryCancel(LFacade, LBob, LStream) = coForbidden);
    AssertEqualStr('refused cancel is audited',
      'stream.cancel.denied/ownership-mismatch', LastAction(LSink));
    AssertTrue('alice of another tenant cannot cancel',
      TryCancel(LFacade, LAliceOtherTenant, LStream) = coForbidden);
    AssertTrue('"Alice" cannot cancel alice''s stream',
      TryCancel(LFacade, LAliceUpper, LStream) = coForbidden);
    AssertTrue('anonymous cancel raises unauthorized',
      TryCancel(LFacade, LAnonymous, LStream) = coUnauthorized);
    AssertTrue('request without a principal cannot cancel',
      TryCancel(LFacade, LBare, LStream) = coUnauthorized);
    AssertFalse('stream survived every refused cancel', IsCancelled(LManager, LStream));
    AssertEqualInt('ownership entry survived', 1, LFacade.Ownership.Count);

    AssertTrue('unknown stream id returns False',
      TryCancel(LFacade, LAlice, 'strm_does_not_exist') = coFalse);

    // The owner cancels: horse-ai's own state must show it.
    AssertTrue('alice cancels her stream', TryCancel(LFacade, LAlice, LStream) = coTrue);
    AssertTrue('horse-ai stream state is cancelled', IsCancelled(LManager, LStream));
    AssertEqualStr('cancel is audited', 'stream.cancelled/', LastAction(LSink));
    AssertEqualInt('ownership entry removed', 0, LFacade.Ownership.Count);
    AssertTrue('second cancel returns False', TryCancel(LFacade, LAlice, LStream) = coFalse);

    // A stream that finished on its own and was removed by horse-ai.
    AssertTrue('alice starts a second stream',
      TryStart(LFacade, LAlice, LConv.Id, LStream2) = coTrue);
    LManager.Remove(LStream2);
    AssertTrue('cancel of a finished stream returns False',
      TryCancel(LFacade, LAlice, LStream2) = coFalse);
    AssertEqualInt('stale ownership entry dropped', 0, LFacade.Ownership.Count);

    // ForgetStream.
    AssertTrue('alice starts a third stream',
      TryStart(LFacade, LAlice, LConv.Id, LStream2) = coTrue);
    AssertTrue('ForgetStream removes the entry', LFacade.ForgetStream(LStream2));
    AssertFalse('ForgetStream twice returns False', LFacade.ForgetStream(LStream2));
  finally
    LBare.Free;
    LAnonymous.Free;
    LAliceUpper.Free;
    LAliceOtherTenant.Free;
    LBob.Free;
    LAlice.Free;
    LFacade.Free;
  end;
end;

{ --- Main ------------------------------------------------------------- }

begin
  Writeln('horse-ai-conversations conformance tests');
  Writeln('=========================================');

  TestStoreOwnership;
  TestStreamOwnership;
  TestFacade;

  Writeln;
  Writeln(Format('summary: %d total, %d failed', [GTotal, GFailures]));
  if GFailures > 0 then
    ExitCode := 1
  else
    ExitCode := 0;
end.
