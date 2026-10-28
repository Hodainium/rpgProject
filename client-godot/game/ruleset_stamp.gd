## The ruleset version written into an exported pack by tools/export.sh (spec server-authority 3.5). Never committed:
## an exported build reads it through RulesetVersion.stamped(); the editor and headless runs compute it live.
class_name RulesetStamp
extends Resource

@export var version: String = ""
