using System.Text.Json;
using Rpg.Contracts.Api.V1;
using Rpg.Contracts.Serialization;

namespace Rpg.Contracts.Tests;

public class SerializationTests
{
    private static readonly ServerInfoResponse GoldenServerInfo = new(
        "rpg-game-server-api",
        "0.1.0+f81f7ac",
        new DateTimeOffset(2026, 10, 14, 12, 0, 0, TimeSpan.Zero));

    private static string ReadGolden(string name) =>
        File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "golden", name));

    [Fact]
    public void ServerInfo_MatchesGoldenVector_ByteForByte()
    {
        var json = JsonSerializer.Serialize(GoldenServerInfo, RpgJson.Options);

        Assert.Equal(ReadGolden("server-info.json"), json);
    }

    [Fact]
    public void ServerInfo_GoldenVector_RoundTrips()
    {
        var parsed = JsonSerializer.Deserialize<ServerInfoResponse>(ReadGolden("server-info.json"), RpgJson.Options);

        Assert.Equal(GoldenServerInfo, parsed);
    }

    private enum SampleStatus { Accepted, Rejected }

    private sealed record SampleVerdict(SampleStatus Status, int ErrorCode);

    [Fact]
    public void Enums_SerializeAsStrings_NumericCodesStayNumbers()
    {
        var json = JsonSerializer.Serialize(new SampleVerdict(SampleStatus.Rejected, 2002), RpgJson.Options);

        Assert.Equal("""{"status":"Rejected","errorCode":2002}""", json);
    }
}
