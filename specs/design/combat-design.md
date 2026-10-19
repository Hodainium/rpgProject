# Combat design notes

Design intent only. **GodotGAS resources in `client-godot/` are the source of truth.** Once something below
exists in Godot (tag registry, AttributeSet, effects, ExecCalcs), the Godot version wins and this file is just
a description of it. Do not generate code from this file mechanically.

Number notation: values are written as designers type them, with up to 2 decimals (`150` = 150%, `5.25` = 5.25%,
`80.5` flat). Combat stores every value ×100 as a whole number and uses integer math only; see "Number format" in
`specs/combat-replay-core.md`. RNG: the battle's seeded Godot `RandomNumberGenerator`.
`Roll()` below means a percentage roll with 2-decimal precision (`rng.randi_range(0, 9999)` against the stored value).

## Attributes
| Name | Default | Min | Max |
|---|---|---|---|
| HP | 1000 | 0 | MaxHP |
| MaxHP | 1000 | 1 | – |
| ATK | 500 | 0 | – |
| DEF | 300 | 0 | – |
| SPD | 100 | 1 | – |
| CritRate (%) | 5 | 0 | 100 |
| CritDmg (%) | 50 | 0 | – |
| MP | 100 | 0 | MaxMP |
| MaxMP | 100 | 0 | – |
| Energy (ult charge) | 0 | 0 | 100 |
| Toughness | 300 | 0 | 300 |

## Gameplay tags
- Abilities: `Ability.Basic.Slash`, `Ability.Skill.Starfall`, `Ability.Ultimate.NovaBurst`
- Status: `Status.Buff.AttackUp`, `Status.Debuff.DefenseDown`, `Status.State.WeaknessBroken`
- Events: `Event.Turn.Start`, `Event.Turn.End`, `Event.Damage.Critical`
- Cues: `Cue.VFX.SlashImpact`, `Cue.VFX.StarfallExplosion`

## ExecCalc_StandardDamage
Written in designer terms; the implementation does the same math on the ×100 whole numbers, truncating toward zero.
`SkillMultiplier` (%) or a flat amount comes from the ability's execution-table row (`SCALED` / `FLAT`).
```text
BaseDmg        = Attacker.ATK × SkillMultiplier%          # or the row's flat damage
DefMultiplier% = 100 − (Target.DEF × 100) / (Target.DEF + 1000)
RawDmg         = BaseDmg × DefMultiplier%
if Roll() < Attacker.CritRate%:
    RawDmg = RawDmg × (100 + Attacker.CritDmg)%
```
Example: ATK 500, SkillMultiplier 150, target DEF 300 → BaseDmg 750, DefMultiplier 76.93% (the DEF part,
23.0769%, truncates to 23.07%), RawDmg 576.97; on a crit with CritDmg 50 → 865.45.

## Not yet designed
Per-ability execution tables (multipliers and hit timing), Energy gain and Ultimate gating, Toughness damage and break,
buff and debuff magnitudes and durations. (Turn order, action value and effect timing are specified in
`specs/combat-replay-core.md`.)
