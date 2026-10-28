using System.Text.Json;
using System.Text.Json.Serialization;
using Rpg.Contracts.Battle;

namespace Rpg.Contracts.Runs;

/// <summary>POST /api/v1/runs/{runId}/actions (spec server-authority 2.2): 1–50 actions with consecutive seqs, in
/// order. All-or-nothing; seqs already stored with the same body are skipped, so a retried batch is a no-op.</summary>
public sealed record RunActionBatch(IReadOnlyList<RunActionRequest> Actions);

/// <summary>One run_log entry.</summary>
/// <param name="Seq">1-based, consecutive per run (seq 1 is <c>start_run</c>).</param>
/// <param name="StateHash"><c>RunState.run_hash()</c> after the action.</param>
/// <param name="PlayedAt">The client's clock, for analytics and upload lag only.</param>
/// <param name="Snapshot">The RunSnapshot JSON after the action (an object with <c>schemaVersion</c> 1), required on
/// checkpoint actions. Opaque to the server: owned by GDScript. Omitted when null.</param>
public sealed record RunActionRequest(int Seq, RunAction Action, string StateHash, DateTimeOffset PlayedAt,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] JsonElement? Snapshot = null);

/// <summary>
/// What the player did (3.1). Only the fields a type uses are sent; null fields are omitted from the JSON. The item,
/// character, price, coin and offer fields are claims kept for analytics (slice 4b), checked by replay like the rest.
/// </summary>
/// <param name="Type">One of <see cref="RunActionTypes.All"/>. <c>end</c> is Lost only (Won uses the end endpoint).</param>
/// <param name="Floor">The floor the action was played on (next_floor and the rest stop: the floor being left).</param>
/// <param name="ItemId">take / buy / field / give_to / move_item: the item involved (take / buy: or the armor piece).</param>
/// <param name="Kind">take / buy: Equipment for armor (armor inventory), Keys for keys.</param>
/// <param name="CharacterId">take / buy: who received it (never for armor or keys); field: who acted.</param>
/// <param name="EquipmentId">equip / swap_gear: the piece put on.</param>
/// <param name="EquipmentSlot">unequip: the slot tag emptied (<c>Equipment.Slot.&lt;X&gt;</c>).</param>
/// <param name="FromSlot">swap_gear: the member who wore it; move_item: the giver is <c>Slot</c>.</param>
/// <param name="ToSlot">move_item: the receiver.</param>
/// <param name="SwapItemId">move_item: the item sent back the other way, if any.</param>
/// <param name="ChestId">open_chest: the chest (spec keys-and-gear).</param>
/// <param name="Serial">open_chest: the chest's serial.</param>
/// <param name="Unlock">enter_room: "key" or "golden" when a lock opened.</param>
/// <param name="Chapter">next_floor: the chapter picked on a CHOICE slot (playable-demo 3.8).</param>
/// <param name="Price">buy: coins paid.</param>
/// <param name="PriceItemId">buy: the curse item paid with, if any (<c>RoomPlacement.price_item</c>).</param>
/// <param name="CoinsAfter">Every action: the run's coins afterwards.</param>
/// <param name="Offers">enter_room: every pickup on offer in that room.</param>
/// <param name="Battle">battle: what was played.</param>
public sealed record RunAction(
    string Type,
    int Floor,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] int? Cell = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] int? Page = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] int? Choice = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] int? Placement = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] int? Slot = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Ability = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] int? Target = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? ItemId = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] ItemKind? Kind = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? CharacterId = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? EquipmentId = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? EquipmentSlot = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] int? FromSlot = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] int? ToSlot = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? SwapItemId = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? ChestId = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] int? Serial = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Unlock = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Chapter = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] int? Price = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? PriceItemId = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] int? CoinsAfter = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] IReadOnlyList<ItemOffer>? Offers = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] BattleSubmission? Battle = null);

/// <summary>The action <c>Type</c> values the server accepts: a small fixed set, so it is also a metric label.</summary>
public static class RunActionTypes
{
    public const string StartRun = "start_run";
    public const string Battle = "battle";
    public const string NextFloor = "next_floor";
    public const string End = "end";

    public static readonly IReadOnlyList<string> All =
    [
        StartRun, "enter_room", "choose", "take", "buy", "field", "equip", "unequip", "give_to", "open_chest",
        "swap_gear", "move_item", Battle, NextFloor, End,
    ];

    /// <summary>Types that always carry a snapshot. Battle-pending actions do too, which only the client can tell.</summary>
    public static readonly IReadOnlyList<string> Checkpoints = [StartRun, Battle, NextFloor];
}

/// <summary>A battle action's payload: the conditions it was played under (seed included) and its action log.</summary>
/// <param name="BattleId">The client's deterministic id, <c>{runId}/f{floor}/c{cell}{label}</c>.</param>
public sealed record BattleSubmission(string BattleId, BattleSnapshot Conditions, ActionLog ActionLog);

/// <summary>One pickup on offer when a room is entered (analytics: what players are shown and what they pick up).</summary>
public sealed record ItemOffer(int Placement, string ItemId, int Price, OfferSource Source,
    ItemKind Kind = ItemKind.Item);

public enum OfferSource { Treasure, Shop, BossReward, Other }

/// <summary>item-pass: pedestals and shelves offer armor; keys-and-gear: shops sell keys.</summary>
public enum ItemKind { Item, Equipment, Keys }

/// <summary>200: everything up to <c>LastSeq</c> is stored; the client's queue drops it.</summary>
public sealed record RunActionAck(int LastSeq);
