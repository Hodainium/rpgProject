namespace Rpg.Contracts.Api.V1;

/// <summary>GET /api/v1/info. Lets clients confirm which server build they are talking to.</summary>
/// <param name="Service">Always "rpg-game-server-api".</param>
/// <param name="BuildVersion">Assembly informational version, e.g. "0.1.0+f81f7ac".</param>
/// <param name="ServerTimeUtc">Server clock at response time, UTC.</param>
public sealed record ServerInfoResponse(
    string Service,
    string BuildVersion,
    DateTimeOffset ServerTimeUtc);
