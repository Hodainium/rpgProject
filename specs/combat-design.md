# Combat design notes

Design intent only. **GodotGAS resources in `client-godot/` are the source of truth.** Once something below
exists in Godot (tag registry, AttributeSet, effects, ExecCalcs), the Godot version wins and this file is just
a description of it. Do not generate code from this file mechanically.

Math policy: integers and basis points (`10000 = 100.00%`). RNG: the battle's seeded Godot `RandomNumberGenerator`.
`RollBasisPoints()` below means `rng.randi_range(0, 9999)`.

## Attributes
| Name | Default | Min | Max |
|---|---|---|---|
| HP | 1000 | 0 | MaxHP |
| MaxHP | 1000 | 1 | – |
| ATK | 500 | 0 | – |
| DEF | 300 | 0 | – |
| SPD | 100 | 1 | – |
| CritRateBp | 500 | 0 | 10000 |
| CritDmgBp | 5000 | 0 | – |
| Energy | 0 | 0 | 100 |
| Toughness | 300 | 0 | 300 |

## Gameplay tags
- Abilities: `Ability.Basic.Slash`, `Ability.Skill.Starfall`, `Ability.Ultimate.NovaBurst`
- Status: `Status.Buff.AttackUp`, `Status.Debuff.DefenseDown`, `Status.State.WeaknessBroken`
- Events: `Event.Turn.Start`, `Event.Turn.End`, `Event.Damage.Critical`
- Cues: `Cue.VFX.SlashImpact`, `Cue.VFX.StarfallExplosion`

## ExecCalc_StandardDamage
All divisions are integer divisions, truncating toward zero (`int()`).
```text
BaseDmg         = (Attacker.ATK * SkillMultiplierBp) / 10000
DefMultiplierBp = 10000 - (Target.DEF * 10000) / (Target.DEF + 1000)
RawDmg          = (BaseDmg * DefMultiplierBp) / 10000
if RollBasisPoints() < Attacker.CritRateBp:
    RawDmg = (RawDmg * (10000 + Attacker.CritDmgBp)) / 10000
```

## Not yet designed
Skill multipliers, turn order (action value), Energy gain and Ultimate gating, Toughness damage and break, buff and debuff magnitudes and durations.
