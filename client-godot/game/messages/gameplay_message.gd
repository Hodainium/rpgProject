## Spec gameplay-messages 3.1: the base of every payload broadcast through GameplayMessages (Lyra's message structs).
## A payload is built from game state for one broadcast; listeners read it and never hand it back into the game.
class_name GameplayMessage
extends RefCounted


## One line for the dev log (`messages on`): what the message says, without its channel.
func describe() -> String:
	return ""
