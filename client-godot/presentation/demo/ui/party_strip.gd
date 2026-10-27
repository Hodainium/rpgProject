## Spec ff7-ui 2.7 (HUD panel, UI.Slot.Hud.Bottom.Left on the map): the party window outside battle. The same rows as
## in battle (member_row), without the ULT button.
extends UIScreen


func bind(context: UIContext) -> void:
	for signal_name in [&"party_changed", &"floor_entered", &"room_entered", &"room_cleared", &"battle_finished",
			&"event_page_shown"]:
		context.on_run(self, signal_name, func(_a = null): refresh.call_deferred())


func refresh() -> void:
	if ctx != null:
		%Rows.set_items(DemoPartyRows.items(ctx.run))
