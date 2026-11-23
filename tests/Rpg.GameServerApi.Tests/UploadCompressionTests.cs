using System.IO.Compression;
using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using Rpg.Client;
using Rpg.Contracts.Runs;
using Rpg.Contracts.Serialization;
using Rpg.GameServerApi.Tests.Infrastructure;
using Rpg.GameServerApi.Uploads;
using static Rpg.GameServerApi.Tests.RunTests;

namespace Rpg.GameServerApi.Tests;

/// <summary>
/// Spec upload-compression 4 and 6: request decompression and the per-endpoint body limits over the real stack (U1–U6, U9,
/// U10, D1) and the upload metrics. Every other API test runs with the client's default (compression on), which is U8.
/// </summary>
[Collection(StackCollection.Name)]
public class UploadCompressionTests(StackFixture stack)
{
    private static readonly RunStartRequest Start =
        new(ApiFactory.TestRuleset, "descent", ["warrior", "cleric", "ranger"], Session: null);

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    [Fact]
    public async Task Actions_RetriedBatch_BrotliThenPlain_IsANoOp()
    {
        // U1: the endpoint compares the decoded body, so a plain retry of a compressed batch is the same no-op as today.
        await using var factory = await ApiFactory.RunsAsync(stack);
        var client = await ClientAsync(factory, "alice");
        client.Compression = new UploadCompression(CompressAbove: 0);
        var run = await client.StartFencedRunAsync(Start, Ct);
        var batch = RunLog.Batch(RunLog.Start(), RunLog.Room(2), RunLog.Battle(run.RunId, 3));
        var plain = new GameServerClient(factory.CreateClient(), client.AccessToken, new UploadCompression(Enabled: false));

        var once = await client.SendActionsAsync(run.RunId, batch, Ct);
        var retried = await plain.SendActionsAsync(run.RunId, batch, Ct);
        var again = await client.SendActionsAsync(run.RunId, batch, Ct);

        Assert.Equal(3, once.LastSeq);
        Assert.Equal(once, retried);
        Assert.Equal(once, again);
        Assert.Equal(3L, await ScalarAsync(factory, $"SELECT count(*) FROM run_actions WHERE run_id = '{run.RunId}'"));
        var metrics = await PollMetricsAsync(factory, text => text.Contains("rpg_upload_wire_bytes"));
        Assert.Equal("2", Labeled(metrics, "rpg_upload_wire_bytes_count", "route=\"actions\"", "encoding=\"br\""));
        Assert.Equal("1", Labeled(metrics, "rpg_upload_wire_bytes_count", "route=\"actions\"", "encoding=\"identity\""));
    }

    [Fact]
    public async Task Upload_ZipBomb_Is413_AndReadsNoMoreThanTheLimit()
    {
        // U2 / D1: 16 MB of zeros as Brotli (a few KB) on the actions endpoint, past its 8 MB limit; 1 MB on a small one.
        await using var factory = await ApiFactory.RunsAsync(stack);
        var client = await ClientAsync(factory, "alice");
        var run = await client.StartFencedRunAsync(Start, Ct);
        var bomb = Brotli(new byte[16 * 1024 * 1024]);
        Assert.True(bomb.Length < 64 * 1024, $"the bomb is {bomb.Length} bytes");

        using var big = await PostAsync(factory, client, $"api/v1/runs/{run.RunId}/actions", bomb, "br");
        using var small = await PostAsync(factory, client, "api/v1/presence", Brotli(new byte[1024 * 1024]), "br");

        Assert.Equal(HttpStatusCode.RequestEntityTooLarge, big.StatusCode);
        Assert.Equal(HttpStatusCode.RequestEntityTooLarge, small.StatusCode);
        Assert.Equal("application/problem+json", big.Content.Headers.ContentType?.MediaType);
        Assert.Equal(0L, await ScalarAsync(factory, $"SELECT count(*) FROM run_actions WHERE run_id = '{run.RunId}'"));
        var metrics = await PollMetricsAsync(factory, text => text.Contains("rpg_upload_refused_total"));
        Assert.Equal("2", Labeled(metrics, "rpg_upload_refused_total", "reason=\"too_large\""));

        // The bounded read stops one byte past the limit: the decompressor never inflates the rest.
        var limit = 1024 * 1024;
        await using var inflated = new CountingReader(
            new BrotliStream(new MemoryStream(bomb), CompressionMode.Decompress));
        Assert.Null(await UploadPipeline.ReadBoundedAsync(inflated, limit, Ct));
        Assert.Equal(limit + 1, inflated.BytesRead);
    }

    [Fact]
    public async Task Upload_Anonymous_Is401_BeforeAnythingIsInflated()
    {
        // Review fix: authentication runs before the upload pipeline, so a bomb without a token is a plain 401.
        await using var factory = await ApiFactory.RunsAsync(stack);
        var anonymous = new GameServerClient(factory.CreateClient());

        using var response = await PostAsync(factory, anonymous, $"api/v1/runs/{Guid.NewGuid()}/actions",
            Brotli(new byte[16 * 1024 * 1024]), "br");

        Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
        var metrics = await PollMetricsAsync(factory, text => text.Contains("rpg_build_info"));
        Assert.Null(Labeled(metrics, "rpg_upload_refused_total", "reason=\"too_large\""));
    }

    [Fact]
    public async Task Upload_RateLimitedBeforeTheBodyIsInflated()
    {
        // Review fix: the upload gate takes the actions token before decompressing, so over the limit a bomb is a 429, not
        // 8 MB inflated and then a 413; one token per request (the endpoint filter does not take a second).
        await using var factory = await ApiFactory.RunsAsync(stack, settings: new Dictionary<string, string?>
        {
            ["RateLimit:Buckets:actions:Capacity"] = "2",   // the account session (also actions) and one upload
            ["RateLimit:Buckets:actions:RefillPerSecond"] = "0.01",
        });
        // A player of its own: the buckets live in the Redis every test shares.
        var client = await ClientAsync(factory, "limited-" + Guid.NewGuid().ToString("N")[..8]);
        var run = await client.StartFencedRunAsync(Start, Ct);

        var ack = await client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Start()), Ct);
        using var bomb = await PostAsync(factory, client, $"api/v1/runs/{run.RunId}/actions",
            Brotli(new byte[16 * 1024 * 1024]), "br");

        Assert.Equal(1, ack.LastSeq);
        Assert.Equal(HttpStatusCode.TooManyRequests, bomb.StatusCode);
        Assert.NotNull(bomb.Headers.RetryAfter);
        var metrics = await PollMetricsAsync(factory, text => text.Contains("rpg_rate_limited_total"));
        Assert.Equal("1", Labeled(metrics, "rpg_rate_limited_total", "bucket=\"actions\""));
        Assert.Null(Labeled(metrics, "rpg_upload_refused_total", "reason=\"too_large\""));
    }

    [Fact]
    public async Task Upload_CorruptBrotli_Is400()
    {
        // U3: bytes that are not Brotli and a truncated Brotli body, both 400, nothing stored. The decoder refuses the first
        // (bad_body); BrotliStream ends a truncated stream early without an error, so the endpoint's JSON binding refuses
        // the cut-off JSON (a prefix of a JSON object is never a whole one).
        await using var factory = await ApiFactory.RunsAsync(stack);
        var client = await ClientAsync(factory, "alice");
        var run = await client.StartFencedRunAsync(Start, Ct);
        var route = $"api/v1/runs/{run.RunId}/actions";
        var junk = new byte[512];
        new Random(1).NextBytes(junk);   // seed 1: the decoder throws (some random bytes happen to be valid Brotli)
        var whole = Brotli(Json(RunLog.Batch(RunLog.Start(), RunLog.Room(2))));

        using var corrupt = await PostAsync(factory, client, route, junk, "br");
        using var truncated = await PostAsync(factory, client, route, whole[..(whole.Length / 2)], "br");

        Assert.Equal(HttpStatusCode.BadRequest, corrupt.StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, truncated.StatusCode);
        Assert.Equal(0L, await ScalarAsync(factory, $"SELECT count(*) FROM run_actions WHERE run_id = '{run.RunId}'"));
        var metrics = await PollMetricsAsync(factory, text => text.Contains("rpg_upload_refused_total"));
        Assert.Equal("1", Labeled(metrics, "rpg_upload_refused_total", "reason=\"bad_body\""));
    }

    [Theory]
    [InlineData("zstd")]
    [InlineData("x-foo")]
    [InlineData("gzip, br")]
    public async Task Upload_UnknownEncoding_Is415(string encoding)
    {
        // U4: an encoding the server does not take, or more than one, is refused before the endpoint; nothing stored.
        await using var factory = await ApiFactory.RunsAsync(stack);
        var client = await ClientAsync(factory, "alice");
        var run = await client.StartFencedRunAsync(Start, Ct);

        using var response = await PostAsync(factory, client, $"api/v1/runs/{run.RunId}/actions",
            Brotli(Json(RunLog.Batch(RunLog.Start()))), encoding);

        Assert.Equal(HttpStatusCode.UnsupportedMediaType, response.StatusCode);
        Assert.Equal(0L, await ScalarAsync(factory, $"SELECT count(*) FROM run_actions WHERE run_id = '{run.RunId}'"));
        var metrics = await PollMetricsAsync(factory, text => text.Contains("rpg_upload_refused_total"));
        Assert.Equal("1", Labeled(metrics, "rpg_upload_refused_total", "reason=\"unsupported_encoding\""));
    }

    [Fact]
    public async Task Upload_Identity_StillAccepted()
    {
        // U5: an old client (no compression) works as today, on the small and the log endpoints.
        await using var factory = await ApiFactory.RunsAsync(stack);
        var client = await ClientAsync(factory, "alice");
        client.Compression = new UploadCompression(Enabled: false);
        var run = await client.StartFencedRunAsync(Start, Ct);

        using var raw = await PostAsync(factory, client, $"api/v1/runs/{run.RunId}/actions",
            Json(RunLog.Batch(RunLog.Start(), RunLog.Room(2))), encoding: null);
        var ack = await client.SendActionsAsync(run.RunId, RunLog.Batch(RunLog.Room(3)), Ct);

        Assert.Equal(HttpStatusCode.OK, raw.StatusCode);
        Assert.Equal(3, ack.LastSeq);
    }

    [Fact]
    public async Task Upload_Gzip_StillAccepted()
    {
        // U9: another client's gzip body is decompressed like Brotli.
        await using var factory = await ApiFactory.RunsAsync(stack);
        var client = await ClientAsync(factory, "alice");
        var run = await client.StartFencedRunAsync(Start, Ct);

        using var response = await PostAsync(factory, client, $"api/v1/runs/{run.RunId}/actions",
            Gzip(Json(RunLog.Batch(RunLog.Start(), RunLog.Room(2)))), "gzip");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal(2, (await client.GetRunAsync(run.RunId, Ct)).LastSeq);
        var metrics = await PollMetricsAsync(factory, text => text.Contains("rpg_upload_wire_bytes"));
        Assert.Equal("1", Labeled(metrics, "rpg_upload_wire_bytes_count", "route=\"actions\"", "encoding=\"gzip\""));
    }

    [Fact]
    public async Task Upload_DecompressOff_RefusesCompressed()
    {
        // U6: the emergency switch-off: compressed bodies 415, plain ones as today.
        await using var factory = await ApiFactory.RunsAsync(stack,
            settings: new Dictionary<string, string?> { ["Uploads:Decompress"] = "false" });
        var client = await ClientAsync(factory, "alice");
        client.Compression = new UploadCompression(Enabled: false);
        var run = await client.StartFencedRunAsync(Start, Ct);
        var body = Json(RunLog.Batch(RunLog.Start()));

        using var compressed = await PostAsync(factory, client, $"api/v1/runs/{run.RunId}/actions", Brotli(body), "br");
        using var plain = await PostAsync(factory, client, $"api/v1/runs/{run.RunId}/actions", body, encoding: null);

        Assert.Equal(HttpStatusCode.UnsupportedMediaType, compressed.StatusCode);
        Assert.Equal(HttpStatusCode.OK, plain.StatusCode);
    }

    [Fact]
    public async Task Upload_PlainOverTheSmallLimit_Is413()
    {
        // U10: a plain body over 64 KB on a small endpoint is refused (Kestrel took 30 MB before); the log endpoints take a
        // large batch, compressed or plain, up to their own 8 MB.
        await using var factory = await ApiFactory.RunsAsync(stack);
        var client = await ClientAsync(factory, "alice");
        var run = await client.StartFencedRunAsync(Start, Ct);
        var padded = Encoding.UTF8.GetBytes($$"""{"activity":"Map","pad":"{{new string('x', 100 * 1024)}}"}""");

        using var small = await PostAsync(factory, client, "api/v1/presence", padded, encoding: null);
        var big = RunLog.Batch(RunLog.Start() with { Snapshot = Padded(1, 300 * 1024) }, RunLog.Room(2));
        var compressed = await client.SendActionsAsync(run.RunId, big, Ct);
        using var plain = await PostAsync(factory, client, $"api/v1/runs/{run.RunId}/actions", Json(big), encoding: null);
        using var tooBig = await PostAsync(factory, client, $"api/v1/runs/{run.RunId}/actions",
            new byte[8 * 1024 * 1024 + 1], encoding: null);

        Assert.Equal(HttpStatusCode.RequestEntityTooLarge, small.StatusCode);
        Assert.Equal(2, compressed.LastSeq);
        Assert.Equal(HttpStatusCode.OK, plain.StatusCode);   // the same batch again: the plain retry is a no-op
        Assert.Equal(HttpStatusCode.RequestEntityTooLarge, tooBig.StatusCode);
        var metrics = await PollMetricsAsync(factory, text => text.Contains("rpg_upload_body_bytes"));
        Assert.Equal("1", Labeled(metrics, "rpg_upload_body_bytes_count", "route=\"actions\"", "encoding=\"br\""));
        Assert.True(double.Parse(Labeled(metrics, "rpg_upload_body_bytes_sum", "route=\"actions\"", "encoding=\"br\"")!,
                        System.Globalization.CultureInfo.InvariantCulture)
                    > 10 * double.Parse(Labeled(metrics, "rpg_upload_wire_bytes_sum", "route=\"actions\"",
                        "encoding=\"br\"")!, System.Globalization.CultureInfo.InvariantCulture));
        Assert.Equal("2", Labeled(metrics, "rpg_upload_refused_total", "reason=\"too_large\""));
    }

    // ---- helpers ------------------------------------------------------------------------------------------------------

    internal static byte[] Json<T>(T value) => JsonSerializer.SerializeToUtf8Bytes(value, RpgJson.Options);

    internal static JsonElement Padded(int marker, int bytes) =>
        JsonDocument.Parse($$"""{"schemaVersion":1,"marker":{{marker}},"pad":"{{new string('p', bytes)}}"}""")
            .RootElement.Clone();

    internal static byte[] Brotli(byte[] body)
    {
        using var packed = new MemoryStream();
        using (var brotli = new BrotliStream(packed, CompressionLevel.Optimal, leaveOpen: true))
        {
            brotli.Write(body);
        }

        return packed.ToArray();
    }

    private static byte[] Gzip(byte[] body)
    {
        using var packed = new MemoryStream();
        using (var gzip = new GZipStream(packed, CompressionLevel.Optimal, leaveOpen: true))
        {
            gzip.Write(body);
        }

        return packed.ToArray();
    }

    private static async Task<HttpResponseMessage> PostAsync(ApiFactory factory, GameServerClient client, string route,
        byte[] body, string? encoding)
    {
        var http = factory.CreateClient();
        using var request = new HttpRequestMessage(HttpMethod.Post, route) { Content = new ByteArrayContent(body) };
        request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/json") { CharSet = "utf-8" };
        if (encoding is not null)
        {
            request.Content.Headers.TryAddWithoutValidation("Content-Encoding", encoding);
        }

        if (client.AccessToken is { Length: > 0 } token)
        {
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        }
        return await http.SendAsync(request, Ct);
    }

    private static string? Labeled(string metrics, string name, params string[] labels) =>
        metrics.Split('\n')
            .Where(line => line.StartsWith(name + "{", StringComparison.Ordinal) && labels.All(line.Contains))
            .Select(line => line[(line.LastIndexOf('}') + 1)..].Trim().Split(' ')[0])
            .FirstOrDefault();

    /// <summary>Counts the bytes read through it.</summary>
    private sealed class CountingReader(Stream inner) : Stream
    {
        public long BytesRead { get; private set; }
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }

        public override int Read(byte[] buffer, int offset, int count)
        {
            var read = inner.Read(buffer, offset, count);
            BytesRead += read;
            return read;
        }

        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            var read = await inner.ReadAsync(buffer, cancellationToken);
            BytesRead += read;
            return read;
        }

        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                inner.Dispose();
            }

            base.Dispose(disposing);
        }
    }
}

/// <summary>
/// Spec upload-compression 6, the <c>Rpg.Client</c> half (U7), over a recording handler: no server, no Docker.
/// </summary>
public class GameServerClientCompressionTests
{
    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    private static readonly RunActionBatch Big = RunLog.Batch(
        RunLog.Start() with { Snapshot = UploadCompressionTests.Padded(1, 4096) }, RunLog.Room(2));

    [Fact]
    public async Task Client_LargeBodies_GoAsBrotli_AndDecodeToTheSameJson()
    {
        var compressed = new Recorder();
        var plain = new Recorder();
        await Client(compressed, new UploadCompression(), "token-1").SendActionsAsync("run", Big, Ct);
        await Client(plain, new UploadCompression(Enabled: false), "token-1").SendActionsAsync("run", Big, Ct);

        Assert.Equal(["br"], compressed.Encoding);
        Assert.Empty(plain.Encoding);
        Assert.True(compressed.Body.Length * 4 < plain.Body.Length, $"{compressed.Body.Length} vs {plain.Body.Length}");
        Assert.Equal(compressed.Body.Length, compressed.ContentLength);
        Assert.Equal(plain.Body.Length, plain.ContentLength);   // buffered either way: never chunked
        using var inflated = new MemoryStream();
        await using (var brotli = new BrotliStream(new MemoryStream(compressed.Body), CompressionMode.Decompress))
        {
            await brotli.CopyToAsync(inflated, Ct);
        }

        Assert.Equal(plain.Body, inflated.ToArray());
        Assert.Equal(UploadCompressionTests.Json(Big), plain.Body);
        Assert.Equal("application/json; charset=utf-8", compressed.ContentType);
        Assert.Equal(plain.ContentType, compressed.ContentType);
        Assert.Equal("Bearer token-1", compressed.Authorization);
    }

    [Fact]
    public async Task Client_SmallBodies_GoPlain()
    {
        // U7: a body under CompressAbove gains nothing and goes as it is.
        var recorder = new Recorder();
        await Client(recorder, new UploadCompression(), null)
            .SendActionsAsync("run", RunLog.Batch(RunLog.Room(2)), Ct);

        Assert.Empty(recorder.Encoding);
        Assert.True(recorder.Body.Length < 1024);
        Assert.Equal(UploadCompressionTests.Json(RunLog.Batch(RunLog.Room(2))), recorder.Body);
        Assert.Null(recorder.Authorization);
    }

    [Fact]
    public async Task Client_CompressionSwitchedOffLater_SendsPlain()
    {
        // ServerBridge.SetCompression(false) flips the property on the live client.
        var recorder = new Recorder();
        var client = Client(recorder, null, null);
        client.Compression = client.Compression with { Enabled = false };
        await client.SendActionsAsync("run", Big, Ct);

        Assert.Empty(recorder.Encoding);
        Assert.Equal(UploadCompressionTests.Json(Big), recorder.Body);
    }

    private static GameServerClient Client(Recorder recorder, UploadCompression? compression, string? token) =>
        new(new HttpClient(recorder) { BaseAddress = new Uri("http://server/") }, token, compression);

    private sealed class Recorder : HttpMessageHandler
    {
        public byte[] Body { get; private set; } = [];
        public List<string> Encoding { get; } = [];
        public long? ContentLength { get; private set; }
        public string? ContentType { get; private set; }
        public string? Authorization { get; private set; }

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            Body = await request.Content!.ReadAsByteArrayAsync(cancellationToken);
            Encoding.AddRange(request.Content.Headers.ContentEncoding);
            ContentLength = request.Content.Headers.ContentLength;
            ContentType = request.Content.Headers.ContentType?.ToString();
            Authorization = request.Headers.Authorization?.ToString();
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new ByteArrayContent("""{"lastSeq":2}"""u8.ToArray())
                {
                    Headers = { ContentType = new MediaTypeHeaderValue("application/json") },
                },
            };
        }
    }
}
