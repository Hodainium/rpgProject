using Microsoft.Extensions.Options;
using Rpg.GameServerApi.Auth;
using Rpg.GameServerApi.Runs;
using Rpg.GameServerApi.Tests.Infrastructure;

namespace Rpg.GameServerApi.Tests;

/// <summary>Spec server-authority 3.3: floor seeds are HMAC ids, stable per (run, floor) and secret-derived.</summary>
public class FloorSeedTests
{
    private static FloorSeeds With(string secret) => new(Options.Create(new SeedOptions { Secret = secret }));

    [Fact]
    public void FloorSeed_Hmac_StableAndDistinct()
    {
        var runA = Guid.Parse("019a2b3c-4d5e-7f60-8a7b-8c9d0e1f2a3b");
        var runB = Guid.Parse("019a2b3c-4d5e-7f60-8a7b-8c9d0e1f2a3c");
        var one = With(ApiFactory.TestSeedSecret);
        var another = With(ApiFactory.TestSeedSecret);  // a second instance with the same secret

        var seeds = Enumerable.Range(0, 10).Select(floor => one.Derive(runA, floor)).ToList();

        Assert.Equal(seeds, Enumerable.Range(0, 10).Select(floor => another.Derive(runA, floor)));
        Assert.Equal(seeds.Count, seeds.Distinct().Count());
        Assert.All(seeds, seed => Assert.True(seed >= 0));
        Assert.NotEqual(one.Derive(runA, 0), one.Derive(runB, 0));
        Assert.NotEqual(one.Derive(runA, 0), With(ApiFactory.TestSeedSecret + "x").Derive(runA, 0));
    }

    [Fact]
    public void FloorSeed_MatchesTheSpecFormula()
    {
        // int63(HMAC-SHA256(secret, "floor-seed-v1|{runId}|{floor}")): first 8 bytes big-endian, top bit cleared.
        var runId = Guid.Parse("019a2b3c-4d5e-7f60-8a7b-8c9d0e1f2a3b");
        var mac = System.Security.Cryptography.HMACSHA256.HashData(
            System.Text.Encoding.UTF8.GetBytes(ApiFactory.TestSeedSecret),
            System.Text.Encoding.UTF8.GetBytes($"floor-seed-v1|{runId:D}|4"));
        var expected = (long)(System.Buffers.Binary.BinaryPrimitives.ReadUInt64BigEndian(mac) & long.MaxValue);

        Assert.Equal(expected, With(ApiFactory.TestSeedSecret).Derive(runId, 4));
    }

    [Fact]
    public void DevPlayer_IdIsStablePerName()
    {
        Assert.Equal(DevTokenIssuer.IdOf("alice"), DevTokenIssuer.IdOf("alice"));
        Assert.NotEqual(DevTokenIssuer.IdOf("alice"), DevTokenIssuer.IdOf("bob"));
        Assert.Equal(8, DevTokenIssuer.IdOf("alice").Version);
    }
}
