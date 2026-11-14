unit Horse.AI.Conversations.Types;

{$IF DEFINED(FPC)}{$MODE DELPHI}{$H+}{$ENDIF}

// =============================================================================
//  horse-ai-conversations -- data shape
//  -----------------------------------------------------------------------------
//  The logical key is ALWAYS (TenantId, PrincipalId, ConversationId). Every
//  store signature carries the triple; ownership is part of the method
//  signature, never inferred from the id alone.
//
//  Messages ride through from horse-ai (TAIMessages = array of TAIMessage).
//  Nothing in this package parses or mutates them.
//
//  Dual-compile notes:
//    - Plain records plus a small helper to allocate UUIDs. Generics.Collections
//      is used downstream for the store's internal dictionaries.
// =============================================================================

interface

uses
{$IF DEFINED(FPC)}
  SysUtils;
{$ELSE}
  System.SysUtils;
{$IFEND}
  // horse-ai is an upstream dependency; its Types unit declares TAIMessages.
  // Each consumer imports Horse.AI.Types directly; we do not re-export it.

type
  /// Full conversation record, returned by store snapshots.
  TAIConversation = record
    Id: string;                   // UUID v4; opaque to the client
    TenantId: string;             // from authenticated principal
    PrincipalId: string;          // from authenticated principal
    Title: string;                // free text, client-settable
    CreatedAt: TDateTime;         // UTC
    UpdatedAt: TDateTime;         // UTC, bumped on AppendMessage
    Deleted: Boolean;             // logical-delete flag
    // Messages lives on the conversation but is pulled through a separate
    // call to keep listing cheap. See IAIConversationStore.
  end;

  /// Lightweight summary for listing without pulling the full history.
  TAIConversationSummary = record
    Id: string;
    Title: string;
    CreatedAt: TDateTime;
    UpdatedAt: TDateTime;
    MessageCount: Integer;
  end;

  /// Raised when a conversation lookup misses or the record is deleted.
  EHorseAIConversationNotFound = class(Exception);

  /// Raised when the authenticated principal is not the conversation's
  /// owner (checked against the (tenant, principal) pair stored on the
  /// record). The handler should translate this to 403.
  EHorseAIConversationForbidden = class(Exception);

  /// Raised when the authenticated principal is not the stream's owner.
  /// The handler should translate this to 403.
  EHorseAIStreamForbidden = class(Exception);

/// Generate a UUID v4 string ("xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx").
/// Scaffold implementation uses Random for cross-compiler simplicity; a
/// production deployment should swap in a cryptographic RNG (SysUtils.
/// CreateGUIDString on Delphi, OpenSSL RAND_bytes, or /dev/urandom).
function NewConversationId: string;
function NewStreamId: string;

implementation

const
  // 10xx bits for the UUID v4 'y' nibble -- scaffold rotates across
  // 8/9/a/b in production to match RFC 4122. For a scaffold the fixed
  // 'a' is sufficient; ids are opaque to the client.
  HEX_LEADING_Y = 'a';

function RandomHex(ACount: Integer): string;
const
  HEX: array[0..15] of Char = ('0','1','2','3','4','5','6','7',
                               '8','9','a','b','c','d','e','f');
var
  I: Integer;
begin
  SetLength(Result, ACount);
  for I := 1 to ACount do
    Result[I] := HEX[Random(16)];
end;

function NewConversationId: string;
begin
  Result := RandomHex(8) + '-' + RandomHex(4) + '-4' + RandomHex(3) + '-' +
            HEX_LEADING_Y + RandomHex(3) + '-' + RandomHex(12);
end;

function NewStreamId: string;
begin
  Result := 'strm_' + NewConversationId;
end;

initialization
  Randomize;

end.
