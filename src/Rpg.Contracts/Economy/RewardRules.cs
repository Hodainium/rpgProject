namespace Rpg.Contracts.Economy;

public static class RewardSourceKinds
{
    public const string Boss = "boss";  // later: "floor", "run"
}

/// <summary>PUT /api/v1/admin/reward-rules (economy-admin): a new version of the rule for one source (spec economy-rewards 3.1).</summary>
/// <param name="SourceKind"><see cref="RewardSourceKinds"/>.</param>
/// <param name="SourceId">The boss definition id Godot reports in <c>BattleFacts</c>.</param>
/// <param name="Currency">"gems".</param>
/// <param name="Amount">0 retires the rule; otherwise 1..Economy:MaxRewardAmount. A plain whole number (not x100).</param>
public sealed record RewardRuleRequest(string SourceKind, string SourceId, string Currency,
    [property: System.Text.Json.Serialization.JsonRequired] int Amount);  // required: an omitted amount must not become 0 (retire)

/// <summary>One version of a rule; the response of PUT and each item of GET.</summary>
public sealed record RewardRuleResponse(string SourceKind, string SourceId, string Currency, int Amount, int Version,
    DateTimeOffset EffectiveFrom, string CreatedBy);

/// <summary>The latest version per source.</summary>
public sealed record RewardRuleListResponse(IReadOnlyList<RewardRuleResponse> Rules);
