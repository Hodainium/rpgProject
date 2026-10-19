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
| hp | 1000 | 0 | max_hp |
| max_hp | 1000 | 1 | – |
| atk | 500 | 0 | – |
| def | 300 | 0 | – |
| spd | 100 | 1 | – |
| crit_rate (%) | 5 | 0 | 100 |
| crit_dmg (%) | 50 | 0 | – |
| mp | 100 | 0 | max_mp |
| max_mp | 100 | 0 | – |
| energy (ult charge) | 0 | 0 | max_energy |
| max_energy | 100 | 0 | – |
| toughness | 300 | 0 | max_toughness |
| max_toughness | 300 | 0 | – |

Names are snake_case, as the GodotGAS dashboard writes them; it generates the `x ≤ max_x` clamps itself (2026-10-19).

## Gameplay tags
- Abilities: `Ability.Basic.Slash`, `Ability.Skill.Starfall`, `Ability.Ultimate.NovaBurst`
- Status: `Status.Buff.AttackUp`, `Status.Debuff.DefenseDown`, `Status.State.WeaknessBroken`
- Events: `Event.Turn.Start`, `Event.Turn.End`, `Event.Damage.Critical`
- Cues: `Cue.VFX.SlashImpact`, `Cue.VFX.StarfallExplosion`

## ExecCalc_StandardDamage
Written in designer terms; the implementation does the same math on the ×100 whole numbers, truncating toward zero.
`SkillMultiplier` (%) or a flat amount comes from the ability's execution-table row (`SCALED` / `FLAT`).
```text
BaseDmg        = Attacker.atk × SkillMultiplier%          # or the row's flat damage
DefMultiplier% = 100 − (Target.def × 100) / (Target.def + 1000)
RawDmg         = BaseDmg × DefMultiplier%
if Roll() < Attacker.crit_rate%:
    RawDmg = RawDmg × (100 + Attacker.crit_dmg)%
```
Example: ATK 500, SkillMultiplier 150, target DEF 300 → BaseDmg 750, DefMultiplier 76.93% (the DEF part,
23.0769%, truncates to 23.07%), RawDmg 576.97; on a crit with CritDmg 50 → 865.45.

## Not yet designed
Per-ability execution tables (multipliers and hit timing), Energy gain and Ultimate gating, Toughness damage and break,
buff and debuff magnitudes and durations. (Turn order, action value and effect timing are specified in
`specs/combat-replay-core.md`.)
