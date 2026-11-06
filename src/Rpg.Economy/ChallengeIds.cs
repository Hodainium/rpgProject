namespace Rpg.Economy;

/// <summary>
/// The one rule that links a boss to its challenge id (spec economy-challenges 1.1). Pure and total; a shared vector file
/// (<c>tests/Rpg.Contracts.Tests/golden/challenge-id-vectors.json</c>) pins it for every language that needs it.
/// </summary>
public static class ChallengeIds
{
    public const string BossPrefix = "boss/";
    public const int MaxIdLength = 200;

    /// <summary>A content id that can sit inside a ledger key: 1–200 characters, no ':' and no whitespace.</summary>
    public static bool IsKeySafe(string? id) =>
        !string.IsNullOrEmpty(id) && id.Length <= MaxIdLength && !id.Any(c => c == ':' || char.IsWhiteSpace(c));

    /// <summary>"boss/" + the boss id; null when the boss id is not key-safe or the result would pass 200 characters.</summary>
    public static string? ForBoss(string? bossId) =>
        IsKeySafe(bossId) && BossPrefix.Length + bossId!.Length <= MaxIdLength ? BossPrefix + bossId : null;

    /// <summary>True for ids in the reserved boss namespace; an authored completion may not use it.</summary>
    public static bool IsBossChallenge(string challengeId) => challengeId.StartsWith(BossPrefix, StringComparison.Ordinal);
}
