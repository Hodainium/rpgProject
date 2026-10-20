## Entry scene of the editor's Play buttons (spec dev-tools 2.4): the normal game (GameMain with its screens), then the
## request PlayRequest.write() left in user://. No request (F6 on this scene) → the menu.
extends Node

const GAME := preload("res://game/game_main.tscn")


func _ready() -> void:
	var request := PlayRequest.take()
	var game: GameMain = GAME.instantiate()
	add_child(game)
	if request.is_empty():
		return
	var play := PlayRequest.settings()
	if game.content_root != play["content_root"]:
		game.content_root = play["content_root"]
		game.load_content()
	var error := PlayRequest.start(game, request["kind"], request["target"], play)
	if error != "":
		game.show_message("Play %s %s: %s" % [request["kind"], request["target"], error])
