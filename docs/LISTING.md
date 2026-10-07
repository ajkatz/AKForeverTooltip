# Marketplace listing text (copy / paste)

**Name:** AKForeverTooltip
**Category:** Tooltip
**Game version:** World of Warcraft: Forever (1.60.1)
**License:** MIT
**Summary (one line):** The game tooltip follows your mouse and says what Blizzard leaves out: health and power, who they target, how far, your pet's mood, ids - and what a camp object brings to the fire.

## Description

*Part of a small family of addons built for the WoW: Forever game mode, with one mission: minimalistic UI additions that bring out the utility
Blizzard's UI does not give - minimal in nature, no Lua errors, always smooth.*

The game tooltip follows your mouse instead of sitting in the bottom-right corner, and says what Blizzard leaves out.
Every line can be switched off, and every one stays silent rather than guessing when the client will not answer.

### What it does

- **At the mouse.** Every tooltip that would go to the corner - creatures and players in the world, and whatever in the
  UI asks for "the default spot" - follows the mouse instead: right of it (default), left of it, or centred above it,
  with your own offsets. Forever's UI has a cursor mode for this, but offers no switch for it.
- **Class colours.** A player's name in the colour of their class. The tooltip's health bar can take it too
  (`/ftt class bar on`) - off by default, because a unit frame under the mouse repaints that bar green several times a
  second, and a coloured bar flickers there.
- **Health and power.** `700 hp (-300)` where both numbers can be read, `900 / 1,000 hp` where the current value is
  secret beside a readable maximum, `900 hp` where the maximum is secret too. Health is secret on this client for nearly
  every unit, so the last two are what you will mostly see. Mana blue, energy yellow, rage dark red; the colours are
  yours to change.
- **Who they are targeting** - *you* stands out.
- **How far away**, in the bands the client will answer out of combat (10 / 11 / 28 yards). One spell, exactly
  (`/ftt range spell Healing Wave`) keeps working mid-fight, 40-yard heals included.
- **Camp objects.** Forever's campfire furniture - the Fish Bowl, Lodestone, Mana Well, the Camp Chair and the rest,
  the upgrades that stand on them (Spinning Wheel, Anvil, Fishing Rack ...), the campfires and their blueprints - gets
  a line with the buff it brings to everyone sitting by the fire: at your level and at level 60, and the class buff it
  stands in for, with that buff's icon (the two do not stack). On the item in your bags, on the blueprint, and on the
  object standing at the camp. The game's own tooltip says this for a first-tier item only; an upgrade's says "all the
  benefits of a Faction Banner" and no more.
- **Your own pet's mood**, and the spell or item id.

### Commands

| | |
|---|---|
| `/ftt anchor right\|left\|cursor\|default` | right of the mouse, left of it, centred above it, or Blizzard's corner |
| `/ftt offset <x> <y>` | distance from the mouse (default `16 8`) |
| `/ftt class on\|off`, `/ftt class bar on\|off` | class colours; the health bar in the class colour or Blizzard's green |
| `/ftt health on\|off` | the health and power lines |
| `/ftt lines <name> on\|off` | the other lines one by one - `range`, `target`, `pet`, `ids`, `camp` ... (`/ftt lines` lists them) |
| `/ftt range spell <name>, <name>` | the spells whose exact range is shown; `none` drops them |
| `/ftt color <line> <hex>` | the colour of a line (`hp`, `mana` ...), or `default` |
| `/ftt diag` | a report into the settings file for bug reports (then `/reload`) |

`/ftt` on its own lists everything. Settings are account-wide.

### Secret values

Forever hides most unit numbers from addons. This addon never reads, compares or subtracts a secret value - it only
hands it to the widget that may show it - and it never re-owns, clears, shows or hides the game tooltip, which on this
client would leave enemy tooltips empty in a fight. What is shown is what the client will say, and no more.

### Source and bug reports

MIT licensed. Code, issues and the changelog: https://github.com/ajkatz/AKForeverTooltip

## Logo and screenshots

Logo (400 x 400): `..\ForeverBranding\out\AKForeverTooltip\logo-400.png` (master: `logo-1024.png`).
Screenshots to take in game: a player's tooltip at the mouse with the class colour and the health line; a Lodestone's tooltip with the camp lines.
