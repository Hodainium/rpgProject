namespace Rpg.Contracts.Economy;

/// <summary>How often a challenge can pay again (spec economy-challenges 1.1). The reset is fixed, never per challenge.</summary>
public static class RewardCycles
{
    public const string Once = "once";
    public const string Weekly = "weekly";  // the ISO 8601 week in UTC, Monday 00:00
}

/// <summary>
/// PUT /api/v1/admin/reward-rules (economy-admin): a new version of one challenge's reward (spec economy-challenges 2.1).
/// A challenge pays one amount, once per cycle. A score band is several independent challenges (a star each), not tiers.
/// </summary>
/// <param name="ChallengeId">The one reward key: 1–200 characters, no ':' and no whitespace. A boss's is "boss/" + its id.</param>
/// <param name="Currency">"gems".</param>
/// <param name="Amount">0 retires the challenge; otherwise 1..Economy:MaxRewardAmount. A plain whole number (not x100).</param>
/// <param name="Cycle"><see cref="RewardCycles"/>.</param>
/// <param name="EndsAt">Null = never expires. Otherwise a battle submitted at or after it pays nothing; must be in the future when set.</param>
public sealed record RewardRuleRequest(string ChallengeId, string Currency,
    [property: System.Text.Json.Serialization.JsonRequired] int Amount,  // required: an omitted amount must not become 0 (retire)
    string Cycle = RewardCycles.Once,
    [property: System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    DateTimeOffset? EndsAt = null);

/// <summary>One version of a challenge's reward; the response of PUT and each item of GET.</summary>
/// <param name="Generation">The challenge's global reset generation (0 = never reset for everyone).</param>
public sealed record RewardRuleResponse(string ChallengeId, string Currency, int Amount, string Cycle,
    [property: System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    DateTimeOffset? EndsAt,
    int Generation, int Version, DateTimeOffset EffectiveFrom, string CreatedBy);

/// <summary>The latest version per challenge.</summary>
public sealed record RewardRuleListResponse(IReadOnlyList<RewardRuleResponse> Rules);

/// <summary>POST /api/v1/admin/reward-cycles/reset (economy-admin): the next clear pays again.</summary>
/// <param name="PlayerId">Null = everyone; otherwise only that player.</param>
public sealed record RewardCycleResetRequest(string ChallengeId,
    [property: System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    Guid? PlayerId = null,
    [property: System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    string? Reason = null);

public sealed record RewardCycleResetResponse(string ChallengeId,
    [property: System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    Guid? PlayerId,
    int Generation, DateTimeOffset ResetAt, string ResetBy);
