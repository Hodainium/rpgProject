using System.Text.Json;
using Rpg.Contracts.Battle;
using Rpg.Contracts.Runs;

namespace Rpg.GameServerApi.Tests.Infrastructure;

/// <summary>Builds run actions as the client would send them. The server treats snapshots and battles as opaque
/// claims, so these carry only what the wire shape needs.</summary>
public static class RunLog
{
    public static readonly DateTimeOffset PlayedAt = new(2026, 10, 27, 12, 0, 0, TimeSpan.Zero);

    /// <summary>A RunSnapshot stand-in: schemaVersion 1 plus a marker to tell snapshots apart.</summary>
    public static JsonElement Snapshot(int marker) =>
        JsonDocument.Parse($$"""{"schemaVersion":1,"marker":{{marker}},"party":[{"id":"warrior","hp":4200}]}""")
            .RootElement.Clone();

    public static RunActionBatch Batch(params RunActionRequest[] actions) => new(actions);

    public static RunActionRequest Start(int seq = 1) =>
        new(seq, new RunAction(RunActionTypes.StartRun, 0, CoinsAfter: 0), $"h{seq}", PlayedAt, Snapshot(seq));

    public static RunActionRequest Room(int seq, int floor = 0, int cell = 1, string hash = "") =>
        new(seq, new RunAction("enter_room", floor, Cell: cell, CoinsAfter: seq), hash.Length > 0 ? hash : $"h{seq}",
            PlayedAt);

    public static RunActionRequest NextFloor(int seq, int floor = 0) =>
        new(seq, new RunAction(RunActionTypes.NextFloor, floor), $"h{seq}", PlayedAt, Snapshot(seq));

    public static RunActionRequest Battle(string runId, int seq, int floor = 0, int cell = 5, string? battleId = null)
    {
        var id = battleId ?? $"{runId}/f{floor}/c{cell}";
        var conditions = new BattleSnapshot(2, id, "1234567890123", "fixture.encounter.duel",
            [new PartyMemberSnapshot(1, "fixture.character.duelist", 1, Hp: 50000)], ScalingId: "fixture.scaling",
            Depth: floor);
        var log = new ActionLog(2, [new ActionEntry(1, "P1", "Ability.Attack", "E1")], BattleOutcome.Victory,
            new string('a', 64));
        return new RunActionRequest(seq, new RunAction(RunActionTypes.Battle, floor, Cell: cell,
            Battle: new BattleSubmission(id, conditions, log)), $"h{seq}", PlayedAt, Snapshot(seq));
    }

    public static RunEndRequest End(int seq, RunEndStatus status) => new(seq, status, $"run{seq}", Snapshot(seq));
}
