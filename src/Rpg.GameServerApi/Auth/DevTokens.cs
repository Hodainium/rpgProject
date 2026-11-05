using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Extensions.Options;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Tokens;
using Rpg.Contracts.Auth;
using Rpg.GameServerApi.Observability;

namespace Rpg.GameServerApi.Auth;

/// <summary>Configuration section <c>Auth</c>. The signing key lives in user-secrets (dev) or the environment.</summary>
public sealed class AuthOptions
{
    public const string Section = "Auth";
    public const string Issuer = "rpg-game-server-api";
    public const string Audience = "rpg-game";

    /// <summary>HMAC-SHA256 key for bearer tokens, at least 32 characters.</summary>
    public string SigningKey { get; set; } = "";

    /// <summary>Development only: <c>POST /api/v1/auth/dev-token</c> issues tokens. 404 everywhere else.</summary>
    public bool DevTokens { get; set; }

    /// <summary>
    /// Development only: player names whose dev token carries the <c>economy-admin</c> role (spec economy-rewards 3.6).
    /// Ignored outside Development; real operator identity is not built.
    /// </summary>
    public string[] DevAdmins { get; set; } = [];

    public TimeSpan TokenLifetime { get; set; } = TimeSpan.FromHours(12);

    public SymmetricSecurityKey Key() => new(Encoding.UTF8.GetBytes(SigningKey));
}

/// <summary>A resolved caller: the stable player id and the name it was derived from.</summary>
public sealed record Player(Guid Id, string Name);

/// <summary>
/// The development token issuer (spec server-authority 3.2, decision 13): a player name becomes a stable player id
/// (the first 16 bytes of SHA-256 over <c>"rpg-dev-player|" + name</c>, as a version-8 uuid) and a signed bearer
/// token whose <c>sub</c> is that id and whose <c>name</c> is the name. Every player endpoint reads only the token.
/// </summary>
public sealed class DevTokenIssuer(IOptions<AuthOptions> options, TimeProvider clock, IHostEnvironment? environment = null)
{
    public const int MaxNameLength = 64;
    public const string NameClaim = "name";
    public const string RoleClaim = "role";
    public const string EconomyAdminRole = "economy-admin";

    public static bool IsValidName(string? name) =>
        name is { Length: > 0 and <= MaxNameLength } && name.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_' or '.');

    public DevTokenResponse Issue(string name)
    {
        var id = IdOf(name);
        var now = clock.GetUtcNow();
        var expires = now + options.Value.TokenLifetime;
        var claims = new Dictionary<string, object>
        {
            [JwtRegisteredClaimNames.Sub] = id.ToString("D"),
            [NameClaim] = name,
        };
        if (environment?.IsDevelopment() == true && options.Value.DevAdmins.Contains(name))
        {
            claims[RoleClaim] = EconomyAdminRole;
        }

        var token = new JsonWebTokenHandler().CreateToken(new SecurityTokenDescriptor
        {
            Issuer = AuthOptions.Issuer,
            Audience = AuthOptions.Audience,
            Claims = claims,
            IssuedAt = now.UtcDateTime,
            NotBefore = now.UtcDateTime,
            Expires = expires.UtcDateTime,
            SigningCredentials = new SigningCredentials(options.Value.Key(), SecurityAlgorithms.HmacSha256),
        });
        return new DevTokenResponse(token, expires, id.ToString("D"));
    }

    /// <summary>A name-based uuid (version 8: the first 16 bytes of SHA-256 over a fixed prefix and the name).</summary>
    public static Guid IdOf(string name)
    {
        Span<byte> hash = stackalloc byte[SHA256.HashSizeInBytes];
        SHA256.HashData(Encoding.UTF8.GetBytes("rpg-dev-player|" + name), hash);
        var bytes = hash[..16];
        bytes[6] = (byte)((bytes[6] & 0x0F) | 0x80);  // version 8
        bytes[8] = (byte)((bytes[8] & 0x3F) | 0x80);  // RFC 9562 variant
        return new Guid(bytes, bigEndian: true);
    }
}

public static class AuthEndpoints
{
    public static void MapAuthEndpoints(this WebApplication app) =>
        app.MapPost("/api/v1/auth/dev-token", (DevTokenRequest? request, DevTokenIssuer issuer,
            IOptions<AuthOptions> options, IHostEnvironment environment, RpgMetrics metrics) =>
        {
            // Off outside Development whatever the configuration says; 404, as if the route did not exist.
            if (!options.Value.DevTokens || !environment.IsDevelopment())
            {
                return Results.Problem(statusCode: StatusCodes.Status404NotFound, title: "Not found");
            }

            if (!DevTokenIssuer.IsValidName(request?.PlayerName))
            {
                return Results.Problem(statusCode: StatusCodes.Status400BadRequest, title: "Bad player name",
                    detail: $"playerName takes 1–{DevTokenIssuer.MaxNameLength} letters, digits, '-', '_' or '.'.");
            }

            metrics.DevTokenIssued();
            return Results.Ok(issuer.Issue(request!.PlayerName));
        });

    /// <summary>The caller of an endpoint that requires authorization (so the token was validated).</summary>
    public static Player Player(this ClaimsPrincipal user) =>
        new(Guid.Parse(user.FindFirstValue(JwtRegisteredClaimNames.Sub)!),
            user.FindFirstValue(DevTokenIssuer.NameClaim) ?? "");

    /// <summary>True when the token carries the economy-admin role (only Development dev tokens can).</summary>
    public static bool IsEconomyAdmin(this ClaimsPrincipal user) =>
        user.FindAll(DevTokenIssuer.RoleClaim).Any(c => c.Value == DevTokenIssuer.EconomyAdminRole);

    /// <summary>The caller's player id, or null for an anonymous request.</summary>
    public static Guid? PlayerIdOrNull(this ClaimsPrincipal user) =>
        user.Identity?.IsAuthenticated == true
        && Guid.TryParse(user.FindFirstValue(JwtRegisteredClaimNames.Sub), out var id)
            ? id
            : null;
}
