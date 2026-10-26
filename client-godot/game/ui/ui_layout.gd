## Spec ui-framework 3.1 (Lyra: the primary game layout): the root of the UI. Holds one UILayerStack per layer, bottom
## to top in child order (Game, GameMenu, Menu, Modal); may hold UIExtensionPoints of its own.
class_name UILayout
extends Control


## The stacks, bottom to top.
func stacks() -> Array[UILayerStack]:
	var found: Array[UILayerStack] = []
	for child in get_children():
		if child is UILayerStack:
			found.append(child)
	return found
