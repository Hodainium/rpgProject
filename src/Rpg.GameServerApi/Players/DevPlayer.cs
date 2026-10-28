using System.Security.Cryptography;
using System.Text;
using Rpg.Contracts.Api.V1;

namespace Rpg.GameServerApi.Players;

/// <summary>A resolved caller: the stable player id and the name it was derived from.</summary>
public sealed record Player(Guid Id, string Name);

/// <summary>
/// Part A identity (spec server-authority 3.2): the <c>X-Dev-Player</c> header names the player; the id is derived
/// from the name (the same name is always the same player) and the players row is created on the first run start.
/// Only when the environment is Development; anywhere else the header is ignored and every player endpoint is 401.
/// Part B replaces this with bearer tokens.
/// </summary>
public static class DevPlayer
{
    public const int MaxNameLength = 64;

    /// <summary>The caller, or the 401/400 to return instead.</summary>
    public static (Player? Player, IResult? Error) Resolve(HttpContext context)
    {
        var environment = context.RequestServices.GetRequiredService<IHostEnvironment>();
        var header = context.Request.Headers[ApiHeaders.DevPlayer].ToString();
        if (!environment.IsDevelopment() || header.Length == 0)
        {
            return (null, Results.Problem(statusCode: StatusCodes.Status401Unauthorized, title: "Unauthorized",
                detail: "No player identity."));
        }

        if (header.Length > MaxNameLength || !header.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_' or '.'))
        {
            return (null, Results.Problem(statusCode: StatusCodes.Status400BadRequest, title: "Bad player name",
                detail: $"{ApiHeaders.DevPlayer} takes 1–{MaxNameLength} letters, digits, '-', '_' or '.'."));
        }

        return (new Player(IdOf(header), header), null);
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
