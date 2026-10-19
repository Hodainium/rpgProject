using System.Reflection;

namespace Rpg.GameServerApi.Observability;

public sealed class BuildInfo
{
    public const string ServiceName = "rpg-game-server-api";

    /// <summary>Assembly informational version, e.g. "0.1.0+f81f7ac..." (the SDK appends the git commit).</summary>
    public string Version { get; } =
        typeof(BuildInfo).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
        ?? "unknown";
}
