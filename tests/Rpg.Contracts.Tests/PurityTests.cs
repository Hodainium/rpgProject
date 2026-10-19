using Rpg.Client;
using Rpg.Contracts.Api.V1;

namespace Rpg.Contracts.Tests;

/// <summary>
/// Guards the dependency rules in CLAUDE.md: Rpg.Contracts holds wire shapes only, and Rpg.Client depends on
/// nothing but Rpg.Contracts (no Godot, no server, no game logic packages).
/// </summary>
public class PurityTests
{
    [Fact]
    public void Contracts_ReferencesOnlySystemAssemblies()
    {
        var references = typeof(ServerInfoResponse).Assembly.GetReferencedAssemblies().Select(a => a.Name!);

        Assert.All(references, name => Assert.StartsWith("System", name));
    }

    [Fact]
    public void Client_ReferencesOnlySystemAssembliesAndContracts()
    {
        var references = typeof(GameServerClient).Assembly.GetReferencedAssemblies().Select(a => a.Name!);

        Assert.All(references, name => Assert.True(
            name.StartsWith("System", StringComparison.Ordinal) || name == "Rpg.Contracts",
            $"Rpg.Client must not reference {name}."));
    }
}
