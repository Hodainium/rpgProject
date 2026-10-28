namespace Rpg.Contracts.Api.V1;

/// <summary>Request header names that are part of the wire contract.</summary>
public static class ApiHeaders
{
    /// <summary>
    /// Part A's development identity (spec server-authority 3.2): a player name; the server derives a stable player id
    /// from it and creates the player on first use. Read only when the server runs as Development; Part B removes it.
    /// </summary>
    public const string DevPlayer = "X-Dev-Player";
}
