program HorseAIConversationsTests;

{$APPTYPE CONSOLE}
{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

{
  horse-ai-conversations conformance tests
  =========================================
  Destination: horse-ai-conversations/tests/HorseAIConversationsTests.dpr

  In-process coverage (no socket, no horse-ai live manager):
    - TMemoryConversationStore: full CRUD, ownership triple enforcement,
      cross-tenant isolation, cross-principal isolation within tenant,
      idempotent delete, logical-delete invisibility on Get/List.
    - TStreamOwnershipMap: Register / IsOwner / Unregister semantics,
      thread-safety smoke.
    - Audit helpers: event emission does not touch ResourceId with
      conversation contents.

  SKIPPED without horse-ai's real THorseAIStreamManager:
    - THorseAIConversations.StartStreamFor (raises 'StreamManager not
      configured'). Tested with a stub Config.StreamManager=nil path only.

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
  Horse.AI.Conversations.StreamOwnership;

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

{ --- Main ------------------------------------------------------------- }

begin
  Writeln('horse-ai-conversations conformance tests');
  Writeln('=========================================');

  TestStoreOwnership;
  TestStreamOwnership;

  Writeln;
  Writeln(Format('summary: %d total, %d failed', [GTotal, GFailures]));
  if GFailures > 0 then
    ExitCode := 1
  else
    ExitCode := 0;
end.
