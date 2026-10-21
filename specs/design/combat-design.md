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
| weakness_dmg (%) | see draft | 0 | – |
| toughness_dmg (%) | 0 | 0 | – |
| broken_dmg (%) | 0 | 0 | – |

Names are snake_case, as the GodotGAS dashboard writes them; it generates the `x ≤ max_x` clamps itself (2026-10-19).
The last three (spec item-pass) are the weakness damage a unit takes, and an attacker's bonus toughness damage and
bonus damage against Broken targets; defaults live in `godot_gas/attributes_draft.cfg`, per-enemy values in its stats.

## Gameplay tags
- Abilities: `Ability.Basic.Slash`, `Ability.Skill.Starfall`, `Ability.Ultimate.NovaBurst`
- Status: `Status.Buff.AttackUp`, `Status.Debuff.DefenseDown`, `Status.Debuff.Exposed`, `Status.Debuff.Burn`;
  broken is `State.Broken` (a battle rule tag)
- Weakness: `Weakness.Physical`, `Weakness.Ice`, `Weakness.Fire` (one per `Damage.Type.<X>`)
- Hit tags on a hit's spec: `Hit.Critical`, `Hit.Weakness`, `Hit.Break`, `Hit.FollowUp`; the battle sends each as
  `Event.Damage.Dealt.<X>` / `Event.Damage.Taken.<X>`
- Events: `Event.Turn.Start`, `Event.Turn.End`, `Event.Attack.FollowUp`, `Event.Unit.Killed`, `Event.Battle.OneMore`
- Cues: `Cue.VFX.SlashImpact`, `Cue.VFX.StarfallExplosion`

## ExecCalc_StandardDamage
Written in designer terms; the implementation does the same math on the ×100 whole numbers, truncating toward zero.
`SkillMultiplier` (%) or a flat amount comes from the ability's execution-table row (`SCALED` / `FLAT`).
```text
BaseDmg        = Attacker.atk × SkillMultiplier%          # or the row's flat damage
DefMultiplier% = 100 − (Target.def × 100) / (Target.def + 1000)
RawDmg         = BaseDmg × DefMultiplier%
if row has Damage.Type.<X> and Target has Weakness.<X>:          # spec item-pass
    RawDmg = RawDmg × Target.weakness_dmg%;  hit tag Hit.Weakness
    if Target not Broken and Target.max_toughness > 0:
        Target.toughness −= row toughness × (100 + Attacker.toughness_dmg)%
if Target is Broken:
    RawDmg = RawDmg × (100 + Attacker.broken_dmg)%
if Roll() < Attacker.crit_rate%:                                  # one roll per hit, as before
    RawDmg = RawDmg × (100 + Attacker.crit_dmg)%;  hit tag Hit.Critical
```
Example: ATK 500, SkillMultiplier 150, target DEF 300 → BaseDmg 750, DefMultiplier 76.93% (the DEF part,
23.0769%, truncates to 23.07%), RawDmg 576.97; on a crit with CritDmg 50 → 865.45.

## Ult charge (energy)
Each ability a character uses in battle fires `Event.Ability.Used`; a triggered listener ability adds `energy` (demo:
+25, so an ult every 4 actions). An ult's cost is 100 `energy`: GAS won't activate it on a partial bar and the cost
empties it. Charge carries between battles. Not yet: per-ability charge amounts, charge from taking hits, out-of-turn ults.

## Toughness and break (HSR) with One More (Persona)
Designed and built in `specs/item-pass.md`. A weakness hit depletes toughness by the row's toughness damage; at 0 the
target (if it survives) is Broken: `State.Broken`, its action is delayed 25%, and it recovers to full toughness at
its next turn start. While Broken it takes weakness damage but no toughness damage. The unit whose action broke it
gets a One More: an immediate extra action of any kind. A follow-up attack (an `Ability.Type.FollowUp` passive) never
fires from another follow-up's hit. Per-enemy weakness, toughness and `weakness_dmg` are in each enemy's `.tres`.

## Not yet designed
Per-ability execution tables (multipliers and hit timing), buff and debuff magnitudes and durations, break damage and
per-type break effects, resistances. (Turn order, action value and effect timing are specified in
`specs/combat-replay-core.md`.)
