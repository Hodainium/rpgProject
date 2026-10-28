using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Extensions.Options;

namespace Rpg.GameServerApi.Runs;

/// <summary>Configuration section <c>Seeds</c>. The secret lives in user-secrets (dev) or the environment.</summary>
public sealed class SeedOptions
{
    public const string Section = "Seeds";

    /// <summary>HMAC key for floor seeds, at least 32 characters.</summary>
    public string Secret { get; set; } = "";
}

/// <summary>
/// Floor seeds (spec server-authority 3.3): <c>int63(HMAC-SHA256(Seeds:Secret, "floor-seed-v1|{runId}|{floor}"))</c>,
/// the first 8 bytes big-endian with the top bit cleared. An id like a uuid, not a game rule: the client turns it into
/// the floor with its own seeded streams. Issued seeds are also stored, so rotating the secret never changes one.
/// </summary>
public sealed class FloorSeeds(IOptions<SeedOptions> options)
{
    private readonly byte[] _key = Encoding.UTF8.GetBytes(options.Value.Secret);

    public long Derive(Guid runId, int floor)
    {
        var message = Encoding.UTF8.GetBytes($"floor-seed-v1|{runId:D}|{floor}");
        Span<byte> mac = stackalloc byte[HMACSHA256.HashSizeInBytes];
        HMACSHA256.HashData(_key, message, mac);
        return (long)(BinaryPrimitives.ReadUInt64BigEndian(mac) & 0x7FFF_FFFF_FFFF_FFFFUL);
    }
}
