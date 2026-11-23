using System.Buffers;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.Extensions.Options;
using Microsoft.Net.Http.Headers;
using Rpg.GameServerApi.Observability;
using Rpg.GameServerApi.RateLimiting;

namespace Rpg.GameServerApi.Uploads;

/// <summary>Spec upload-compression 3: the request body limits and the decompression switch.</summary>
public sealed class UploadOptions
{
    public const string Section = "Uploads";

    /// <summary>The decompressed body limit of the action log and end endpoints (8 MB: 8x the largest batch measured).</summary>
    public long MaxLogBodyBytes { get; set; } = 8 * 1024 * 1024;

    /// <summary>The decompressed body limit of every other endpoint (their bodies are a few hundred bytes).</summary>
    public long MaxBodyBytes { get; set; } = 64 * 1024;

    /// <summary>False refuses every compressed body with 415 (an emergency switch-off); plain bodies are unchanged.</summary>
    public bool Decompress { get; set; } = true;
}

/// <summary>
/// Endpoint metadata: an endpoint whose body is a run log (the action upload and the run end), so it gets
/// <see cref="UploadOptions.MaxLogBodyBytes"/>; <see cref="Route"/> is its <c>route</c> metric label.
/// </summary>
public sealed record LogUploadMetadata(string Route);

/// <summary>
/// Spec upload-compression 2.3: the upload pipeline, after routing (so each endpoint's limit is known) and authentication
/// (so an anonymous request is refused before its body is inflated), before the endpoints. <see cref="UploadGate"/> refuses an encoding the server does not take (415) and a body
/// whose declared length is already past the limit (413), and counts the bytes on the wire; ASP.NET Core's request
/// decompression replaces a <c>br</c>, <c>gzip</c> or <c>deflate</c> body by a decompressing stream; <see cref="UploadBuffer"/>
/// reads the (decompressed) body within the endpoint's limit, stopping at the limit (413) or at a body that does not decode
/// (400), and hands the endpoint the bytes it read. The endpoints bind the same JSON whatever the encoding.
/// </summary>
public static class UploadPipeline
{
    /// <summary>The largest body limit: a body is buffered in one <see cref="MemoryStream"/>.</summary>
    public const long MaxLimit = int.MaxValue / 2;

    /// <summary>The encodings ASP.NET Core's default decompression providers take.</summary>
    private static readonly string[] Supported = ["br", "gzip", "deflate"];

    public static IServiceCollection AddUploads(this IServiceCollection services)
    {
        services.AddOptions<UploadOptions>().BindConfiguration(UploadOptions.Section)
            .Validate(o => o.MaxBodyBytes is > 0 and < MaxLimit && o.MaxLogBodyBytes is > 0 and < MaxLimit,
                $"Uploads limits must be positive and below {MaxLimit} bytes (the body is buffered in memory).")
            .ValidateOnStart();
        services.AddRequestDecompression();
        return services;
    }

    public static void UseUploads(this WebApplication app)
    {
        app.UseMiddleware<UploadGate>();
        app.UseRequestDecompression();
        app.UseMiddleware<UploadBuffer>();
    }

    /// <summary>Marks an endpoint whose body is a run log (<see cref="LogUploadMetadata"/>).</summary>
    public static RouteHandlerBuilder LogUpload(this RouteHandlerBuilder builder, string route) =>
        builder.WithMetadata(new LogUploadMetadata(route));

    /// <summary>The request's encoding: <c>identity</c> (none), one supported token, or null when it is not one we take.</summary>
    internal static string? Encoding(HttpRequest request)
    {
        var values = request.Headers.ContentEncoding;
        if (values.Count == 0)
        {
            return "identity";
        }

        if (values.Count > 1 || values[0] is not { } value || value.Contains(','))
        {
            return null;  // more than one coding: the decompression middleware takes one
        }

        // Matched exactly, as the decompression middleware does (Kestrel already strips the whitespace around a value).
        var token = value;
        if (token.Length == 0 || token.Equals("identity", StringComparison.OrdinalIgnoreCase))
        {
            return "identity";
        }

        return Supported.FirstOrDefault(s => s.Equals(token, StringComparison.OrdinalIgnoreCase));
    }

    /// <summary>
    /// Reads <paramref name="body"/> into memory, or returns null as soon as it passes <paramref name="limit"/> bytes: it reads
    /// at most one byte past the limit, so a decompressing stream stops there and never inflates the rest.
    /// </summary>
    public static async Task<MemoryStream?> ReadBoundedAsync(Stream body, long limit, CancellationToken ct,
        long? expectedLength = null)
    {
        // A plain body's declared length sizes the first buffer (fewer doublings), at most 64 KB before any byte arrives.
        var buffer = new MemoryStream(expectedLength is > 0 ? (int)Math.Min(expectedLength.Value, Math.Min(limit, 64 * 1024)) : 0);
        var chunk = ArrayPool<byte>.Shared.Rent(16 * 1024);
        try
        {
            while (true)
            {
                var room = (int)Math.Min(chunk.Length, limit + 1 - buffer.Length);
                var read = await body.ReadAsync(chunk.AsMemory(0, room), ct);
                if (read == 0)
                {
                    buffer.Position = 0;
                    return buffer;
                }

                buffer.Write(chunk, 0, read);
                if (buffer.Length > limit)
                {
                    await buffer.DisposeAsync();
                    return null;
                }
            }
        }
        catch
        {
            await buffer.DisposeAsync();
            throw;
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(chunk);
        }
    }

    internal static Task RefuseAsync(HttpContext context, RpgMetrics metrics, int status, string reason, string title,
        string detail)
    {
        metrics.UploadRefused(reason);
        return Results.Problem(statusCode: status, title: title, detail: detail).ExecuteAsync(context);
    }
}

/// <summary>What <see cref="UploadGate"/> found, for <see cref="UploadBuffer"/>.</summary>
internal sealed class UploadState(long limit, string route, string encoding, CountingStream wire, bool counted)
{
    public long Limit { get; } = limit;
    public string Route { get; } = route;
    public string Encoding { get; } = encoding;
    public CountingStream Wire { get; } = wire;

    /// <summary>A POST or PUT under <c>/api/v1/</c>: recorded in the upload histograms.</summary>
    public bool Counted { get; } = counted;
}

internal sealed class UploadGate(RequestDelegate next, IOptions<UploadOptions> options, RpgMetrics metrics)
{
    public async Task InvokeAsync(HttpContext context)
    {
        // No endpoint (a 404 to come) reads no body: nothing to check or buffer.
        if (!HasBody(context) || context.GetEndpoint() is null)
        {
            await next(context);
            return;
        }

        var request = context.Request;
        var upload = context.GetEndpoint()?.Metadata.GetMetadata<LogUploadMetadata>();
        var limit = upload is null ? options.Value.MaxBodyBytes : options.Value.MaxLogBodyBytes;
        var encoding = UploadPipeline.Encoding(request);
        if (encoding is null || (encoding != "identity" && !options.Value.Decompress))
        {
            await UploadPipeline.RefuseAsync(context, metrics, StatusCodes.Status415UnsupportedMediaType,
                "unsupported_encoding", "Unsupported content encoding",
                "Send the body as br, gzip or deflate (one coding), or uncompressed.");
            return;
        }

        if (request.ContentLength > limit)
        {
            await UploadPipeline.RefuseAsync(context, metrics, StatusCodes.Status413PayloadTooLarge, "too_large",
                "Request body too large", $"The body may be at most {limit} bytes.");
            return;
        }

        // The endpoint's rate-limit token before anything is inflated or buffered (review fix): a refused request costs no
        // decompression.
        if (context.GetEndpoint()?.Metadata.GetMetadata<RateLimitMetadata>() is { } rateLimit
            && await RateLimitExtensions.TakeAsync(context, rateLimit.Bucket) is { } refused)
        {
            await refused.ExecuteAsync(context);
            return;
        }

        // The raw bytes are limited too (Kestrel enforces this feature), and so are the decompressed ones: the decompression
        // middleware reads this limit when the endpoint names none.
        if (context.Features.Get<IHttpMaxRequestBodySizeFeature>() is { IsReadOnly: false } size)
        {
            size.MaxRequestBodySize = limit;
        }

        var counted = (HttpMethods.IsPost(request.Method) || HttpMethods.IsPut(request.Method))
                      && request.Path.StartsWithSegments("/api/v1");
        var original = request.Body;
        var wire = new CountingStream(original);
        request.Body = wire;
        context.Features.Set(new UploadState(limit, upload?.Route ?? "other",
            encoding is "br" or "gzip" or "identity" ? encoding : "other", wire, counted));
        try
        {
            await next(context);
        }
        finally
        {
            request.Body = original;
        }
    }

    private static bool HasBody(HttpContext context) =>
        context.Features.Get<IHttpRequestBodyDetectionFeature>()?.CanHaveBody
        ?? (context.Request.ContentLength > 0 || context.Request.Headers.ContainsKey(HeaderNames.TransferEncoding));
}

internal sealed class UploadBuffer(RequestDelegate next, RpgMetrics metrics)
{
    public async Task InvokeAsync(HttpContext context)
    {
        if (context.Features.Get<UploadState>() is not { } state)
        {
            await next(context);
            return;
        }

        var request = context.Request;
        MemoryStream? body;
        try
        {
            body = await UploadPipeline.ReadBoundedAsync(request.Body, state.Limit, context.RequestAborted,
                state.Encoding == "identity" ? request.ContentLength : null);
        }
        catch (BadHttpRequestException e) when (e.StatusCode == StatusCodes.Status413PayloadTooLarge)
        {
            body = null;   // Kestrel's or the decompression middleware's own limit
        }
        catch (Exception e) when (context.RequestAborted.IsCancellationRequested
                                  && e is OperationCanceledException or IOException)
        {
            return;   // the client went away mid-upload: nobody to answer
        }
        catch (BadHttpRequestException e)
        {
            // Kestrel's own refusal of the body on the wire (a 408 for a too slow upload, a 400 for one that ends early),
            // plain or compressed: its status. The decoders never throw this type.
            await Results.Problem(statusCode: e.StatusCode, title: "Request body not read", detail: e.Message)
                .ExecuteAsync(context);
            return;
        }
        catch (Exception e) when (e is InvalidDataException or IOException
                                      || (e is InvalidOperationException && state.Encoding != "identity"))
        {
            // A body that ends early, a broken connection, or a compressed body that does not decode (BrotliStream and
            // GZipStream throw these). A truncated Brotli or gzip stream ends early without an error on .NET 10: its cut-off
            // JSON is refused by the endpoint's binding (400) and not counted here.
            await UploadPipeline.RefuseAsync(context, metrics, StatusCodes.Status400BadRequest, "bad_body",
                "Malformed request body", "The request body could not be read or decoded.");
            return;
        }

        if (body is null)
        {
            await UploadPipeline.RefuseAsync(context, metrics, StatusCodes.Status413PayloadTooLarge, "too_large",
                "Request body too large", $"The decompressed body may be at most {state.Limit} bytes.");
            return;
        }

        // Every body read in full, whatever the endpoint then answers or throws (a 409 retry, a domain 400 or a 503 is
        // upload traffic too).
        if (state.Counted)
        {
            metrics.Upload(state.Route, state.Encoding, state.Wire.BytesRead, body.Length);
        }

        var decoded = request.Body;
        var declared = request.ContentLength;
        request.Body = body;
        request.ContentLength = body.Length;
        try
        {
            await next(context);
        }
        finally
        {
            request.Body = decoded;
            request.ContentLength = declared;
            await body.DisposeAsync();
        }
    }

}

/// <summary>A read-only pass-through that counts the bytes read (the bytes on the wire, before decompression).</summary>
internal sealed class CountingStream(Stream inner) : Stream
{
    public long BytesRead { get; private set; }

    public override bool CanRead => true;
    public override bool CanSeek => false;
    public override bool CanWrite => false;
    public override long Length => throw new NotSupportedException();

    public override long Position
    {
        get => throw new NotSupportedException();
        set => throw new NotSupportedException();
    }

    public override int Read(byte[] buffer, int offset, int count) => Counted(inner.Read(buffer, offset, count));

    public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default) =>
        Counted(await inner.ReadAsync(buffer, cancellationToken));

    public override async Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
        Counted(await inner.ReadAsync(buffer.AsMemory(offset, count), cancellationToken));

    public override void Flush() { }
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();

    private int Counted(int read)
    {
        BytesRead += read;
        return read;
    }
}
