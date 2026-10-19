using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Rpg.Contracts.Serialization;

/// <summary>The single JSON convention shared by server and client. Configuration only, no logic.</summary>
public static class RpgJson
{
    public static readonly JsonSerializerOptions Options = Create();

    /// <summary>
    /// Applies the convention to an options instance the caller owns (e.g. ASP.NET Core's).
    /// Web defaults (camelCase, case-insensitive reads) come from <see cref="JsonSerializerDefaults.Web"/>.
    /// </summary>
    public static void Apply(JsonSerializerOptions options)
    {
        // Enums serialize as strings (e.g. "Rejected"); numeric codes like errorCode are separate int fields.
        options.Converters.Add(new JsonStringEnumConverter());
        options.DefaultIgnoreCondition = JsonIgnoreCondition.Never;
        // Write '+', '<', '&', non-ASCII etc. literally instead of \uXXXX. Safe here: these payloads are API bodies
        // and event-log records, never embedded in HTML. Keeps wire output and golden vectors readable.
        options.Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping;
    }

    private static JsonSerializerOptions Create()
    {
        var options = new JsonSerializerOptions(JsonSerializerDefaults.Web);
        Apply(options);
        options.MakeReadOnly(populateMissingResolver: true);
        return options;
    }
}
