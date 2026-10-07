# AKForeverTooltip

Two tooltip fixes for **World of Warcraft: Forever** (Interface `16001`).

Status: **v0.2.0 (2026-09-25)** - health and power lines, target-of-target, range, pet mood and ids added since the
first report; the tooltip's health bar is no longer class-coloured by default (it flickered under a unit frame).
v0.1.0 (2026-09-20), the first report - 84 tooltips sent to the mouse through `SetAnchorType`, 51 players class-coloured, 0 errors, 0 blocked actions. 5 scenarios against a mock of Blizzard's
tooltip code; 10 of 10 deliberate breakages of the addon are caught by them.

| | |
|---|---|
| **At the mouse** | every tooltip that would go to the bottom right corner (creatures and players in the world, and whatever in the UI asks for "the default spot") follows the mouse instead |
| **Class colours** | a player's name in the colour of their class - and, if you ask (`/ftt class bar on`), the tooltip's health bar too. Creatures keep Blizzard's colours |
| `/ftt anchor right\|left\|cursor\|default` | right of the mouse (default), left of it, centred above it, or Blizzard's corner |
| `/ftt offset <x> <y>` | distance from the mouse for `right` / `left` (default `16 8`) |
| `/ftt class on\|off`, `/ftt class bar on\|off` | class colours; the health bar in the class colour or Blizzard's green (green by default: a recoloured bar flickers under a unit frame, which repaints it green several times a second) |
| **Camp objects** | Forever's campfire furniture - the Fish Bowl, Lodestone, Mana Well and the rest, the upgrades that stand on them (Spinning Wheel, Anvil, Fishing Rack...), the campfires and their blueprints - gets a line with the buff it brings to everyone sitting by the fire, at your level and at level 60, and the class buff it stands in for (the two do not stack): on the item in your bags, on the blueprint, and on the object standing at the camp. The game's own tooltip says this for a first-tier item only; an upgrade's says "all the benefits of a Faction Banner" and no more. `/ftt lines camp off` drops it |
| `/ftt range spell <name>, <name>` | the spells whose exact range is shown, mid-fight included; `none` drops them |
| `/ftt color <line> <hex>` | the colour of a line (`hp`, `mana` ...), or `default` |
| `/ftt diag` | a report into the settings file (then `/reload`) |

Settings are account-wide. There is no Blizzard option for this on Forever: its UI code has a
"world tooltip at the cursor" mode (`Enum.WorldCursorAnchorType.Cursor`), but the client picks it by
itself and the settings panels offer no switch.

## How - and what it deliberately does not do

**At the mouse.** Tooltips without a place of their own go through Blizzard's
`GameTooltip_SetDefaultAnchor(tooltip, parent)`: it owns the tooltip with `ANCHOR_NONE` and pins it to
the corner. A `hooksecurefunc` post-hook then only changes the **anchor type** to one that follows the
cursor - `tooltip:SetAnchorType("ANCHOR_CURSOR_RIGHT", x, y)`.

Not `tooltip:SetOwner(parent, "ANCHOR_CURSOR")`, which is what tooltip addons usually do there.
`SetOwner` clears the tooltip, which runs Blizzard's `OnTooltipCleared` script as addon code and writes
tainted values into the tooltip - and on this client a tainted tooltip cannot show secret lines.
Blizzard's own `GameTooltipDataMixin:SetWorldCursor` says so: *"... can result in the tooltip displaying
no lines if the new world cursor info ... has any secret line data"* - enemies' tooltips in a fight would
come up empty. `SetAnchorType` runs no script at all. For the same reason the addon never calls `Show`,
`Hide`, `ClearLines` or `SetOwner` on the game tooltip and never writes a field on it; the test mock
fails a scenario on each of those.

**Class colours.** `TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, ...)` is
Blizzard's sanctioned hook for addons: it runs the callback behind a taint barrier after a unit tooltip
was built. There the unit under the mouse (that covers unit frames too) is looked up and, for a
**player**, the name line - and, with `class bar on`, the health bar - get the class colour - two widget calls with plain
numbers; no tooltip text is read or written. `UnitClass` is only secret for units that are not
player-controlled, and any unreadable answer simply means no colour. Only the game tooltip itself is
coloured, not other tooltips that happen to show a unit.

Known limit: a world tooltip that Blizzard sends to the corner fades out when you move off the creature -
at the mouse it now does that while following the cursor for a moment. Hiding it at once would mean
calling `Hide` from addon code (see above); tell me if it bothers you and I will look for a clean way.

## Health, and what a secret number is allowed to say

Where both numbers can be read a health line says what is missing, because that is the number you act
on - whether this is worth a heal, and how big a one:

```
700 hp (-300)
```

Where the client keeps a value **secret** it may be handed to a widget but never read, and a deficit
needs a subtraction while brackets need a join - both of which are reading. That looks like the end of
it, but two things might not be:

* `SetFormattedText` does its formatting inside the widget, in C, so a secret never passes through a Lua
  string operation on the way;
* the arithmetic error this client raises says *"... while execution tainted by <addon>"*, which leaves
  open that a readable maximum minus a secret current is allowed in some execution.

Rather than assume either way, the addon **asks** - once per session, on a font string nobody can see,
the first time a secret actually turns up - and then always shows the best of these the client allowed:

```
700 hp (-300)     both numbers readable: the number and what is missing from it
900 / 1,000 hp    current secret, maximum readable: both on the line, the sum left to the reader
900 hp            maximum secret too: the number with its label
900               a stricter client: the bare number, handed straight over
```

There is no deficit and no percentage on a secret line, and there will not be. Subtracting from a secret
is a **blocked action** on this client - the "Interface action failed because of an AddOn" dialog - even
inside `pcall`, even asked once to find out (taint.log, 2026-09-24). The client gives no readable
percentage either. What is shown is what the client will say, and no more.

`/ftt health` says which rung this client is on and how many lines went out by each route.

## Range in a fight

The range-band line (`within 10 / 11 / 28 yd`) comes from `CheckInteractDistance`, which is a **blocked
action** during combat lockdown on this client - the "Interface action failed because of an AddOn"
dialog, caught or not (taint.log, 2026-09-24 23:13). So the band line is simply absent in a fight, and
counted (`rangeSkippedInCombat` in `/ftt diag`). The exact-spell line (`IsSpellInRange`) carries no such
restriction and keeps working mid-fight, which is when it earns its keep.

## Development

```
lua tests/run.lua
```

Settings come back on your next login; the per-character ones are keyed by the character's full name and
realm. Client build 1.60.1.70170 (Oct 1 2026) reads addon settings back again; it also moved a character's
surname into the realm slot of `UnitName`, which split profiles for a day. Profiles saved under either
spelling, and those of a cold login, are folded into one the first time each character logs in (`/ftt diag`
says what was adopted). `tools/Install-SavedStateBridge.ps1` installed the saved-settings bridge the earlier
beta builds needed; it is only kept for `-Remove`.
