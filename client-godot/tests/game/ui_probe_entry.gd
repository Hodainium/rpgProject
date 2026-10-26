## Test probe for spec ui-framework: a UIList entry that shows its item and remembers the context it got.
extends Label

var got_context: UIContext


func set_item(item: Variant, ctx: UIContext) -> void:
	text = str(item)
	got_context = ctx
