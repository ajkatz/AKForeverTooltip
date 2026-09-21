# ForeverTooltip

Two tooltip fixes for **World of Warcraft: Forever** (Interface `16001`).

Status: **v0.1.0 (2026-09-20) - works in the game**: first report - 84 tooltips sent to the mouse through `SetAnchorType`, 51 players class-coloured, 0 errors, 0 blocked actions. 5 scenarios against a mock of Blizzard's
tooltip code; 10 of 10 deliberate breakages of the addon are caught by them.

| | |
|---|---|
| **At the mouse** | every tooltip that would go to the bottom right corner (creatures and players in the world, and whatever in the UI asks for "the default spot") follows the mouse instead |
| **Class colours** | a player's name - and the tooltip's health bar - in the colour of their class. Creatures keep Blizzard's colours |
| `/ftt anchor right\|left\|cursor\|default` | right of the mouse (default), left of it, centred above it, or Blizzard's corner |
| `/ftt offset <x> <y>` | distance from the mouse for `right` / `left` (default `16 8`) |
| `/ftt class on\|off`, `/ftt class bar on\|off` | class colours; health bar in the class colour or Blizzard's green |
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
**player**, the name line and the health bar get the class colour - two widget calls with plain
numbers; no tooltip text is read or written. `UnitClass` is only secret for units that are not
player-controlled, and any unreadable answer simply means no colour. Only the game tooltip itself is
coloured, not other tooltips that happen to show a unit.

Known limit: a world tooltip that Blizzard sends to the corner fades out when you move off the creature -
at the mouse it now does that while following the cursor for a moment. Hiding it at once would mean
calling `Hide` from addon code (see above); tell me if it bothers you and I will look for a clean way.

## Development

```
lua tests/run.lua
```

`tools/Install-SavedStateBridge.ps1` installs the saved-settings bridge (the 1.60.1 beta client writes
SavedVariables but never reads them back).
