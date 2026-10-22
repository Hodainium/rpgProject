## A unit's look as data (spec animation-sets 3.1): one Animation per named slot. Empty slots fall back to
## `fallback` (usually the demo default set), so a new unit only fills what it changes.
## `hit` and `block` are additive flinches: author them as offsets from the neutral pose (cube: Body position,
## rotation or scale around their rest values), because they are added on top of whatever plays, casts included.
@tool
class_name UnitAnimationSet
extends Resource

const SLOTS: Array[StringName] = [&"idle", &"walk", &"hit", &"block", &"death", &"dead", &"revive", &"victory", &"cast"]
## Slots that play until something else happens; they should loop.
const LOOPING: Array[StringName] = [&"idle", &"walk", &"dead"]
## How deep a fallback chain may go (a set falling back to itself stops here).
const MAX_FALLBACKS: int = 8

@export var idle: Animation
@export var walk: Animation
## Additive flinch when hit.
@export var hit: Animation
## Additive flinch when a hit is blocked (hook: no hit is blocked yet).
@export var block: Animation
@export var death: Animation
## Held after `death` (lying down).
@export var dead: Animation
@export var revive: Animation
@export var victory: Animation
## Generic cast, merged into an ability's animation when that animation doesn't move the model itself.
@export var cast: Animation
## Where empty slots come from.
@export var fallback: UnitAnimationSet
## Empty: tracks on the view's own nodes (`Body:position`). SkeletonProfileHumanoid: tracks under `%GeneralSkeleton`
## (models imported with Retarget → Bone Map → SkeletonProfileHumanoid, "Rename Skeleton" on).
@export var skeleton_profile: SkeletonProfile


## The slot's animation, from this set or the first fallback that has one; null if none does.
func animation_for(slot: StringName) -> Animation:
	var current: UnitAnimationSet = self
	for depth in MAX_FALLBACKS:
		if current == null:
			return null
		var found: Animation = current.get(slot)
		if found != null:
			return found
		current = current.fallback
	return null


## Slots this set fills itself (not through a fallback).
func own_slots() -> Array[StringName]:
	var filled: Array[StringName] = []
	for slot in SLOTS:
		if get(slot) != null:
			filled.append(slot)
	return filled
