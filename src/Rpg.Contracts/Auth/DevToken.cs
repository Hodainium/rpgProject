namespace Rpg.Contracts.Auth;

/// <summary>POST /api/v1/auth/dev-token (Development only, with <c>Auth:DevTokens</c> on): a bearer token for a player
/// name (1–64 letters, digits, '-', '_' or '.'). The same name is always the same player.</summary>
public sealed record DevTokenRequest(string PlayerName);

/// <summary>Send <c>AccessToken</c> as <c>Authorization: Bearer …</c> until <c>ExpiresAt</c>.</summary>
public sealed record DevTokenResponse(string AccessToken, DateTimeOffset ExpiresAt, string PlayerId);
