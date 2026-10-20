## What a sandbox plays (spec dev-tools 3.5): one room, or one hand-made floor, with a party, a seed, a depth and a
## chapter. Built by the console (`room`, `layout`, `play`) and by the editor's Play buttons (PlayRequest).
class_name SandboxRequest
extends RefCounted

## 1-4 character ids.
var party: Array = []
## Run seed; the streams are the usual floor/<depth>/... under it.
var seed: int = 1
## Floor index (0-based), for scaling and the stream labels.
var depth: int = 0
## "" = the first chapter (by id) whose room_query matches the room, else the first chapter.
var chapter_id: StringName = &""
## Either a room...
var room: RoomDefinition
## ...or a hand-made floor.
var layout: FloorLayout
## Optional overrides of the room's content.
var encounter: EncounterDefinition
var event: EventDefinition
