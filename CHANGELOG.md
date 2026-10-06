# AKForeverTooltip

## 0.2.2

- **Camp objects say what they bring.** Forever's campfire furniture - the Fish Bowl, Lodestone, Faction
  Banner, Mana Well and the rest, the upgrades that stand on them (Spinning Wheel, Anvil, Fishing
  Rack...), the campfires and the blueprints - gets a line: the buff it gives everyone who sits by the
  fire **at your level** (read from the client's own words for your character) and at level 60, and the
  class buff it does not stack with, shown by its icon - one thought a line. An upgrade's own
  tooltip only says "all the benefits of a Faction Banner"; the line says what those are. The line is on
  the item in your bags, on the blueprint that teaches it, and on the object standing at the camp.
  `/ftt lines camp off` drops it. The 38 items are known by their ids, the objects by their names;
  `/ftt diag` lists any camp object the addon did not recognise.
- `/ftt diag` keeps the whole tooltip of the last objects hovered and lists the buffs on you, so that what
  the client writes on a campfire (how many objects stand at it?) can be read from the report.
- **A seat gets a tooltip.** The client shows no tooltip at all on a chair, so a camp chair had nothing to
  carry its camp lines. While the game tooltip is hidden and the world cursor points at a camp object, a
  small tooltip of our own now shows its name and the camp lines, and goes when the cursor leaves. It
  reacts to the cursor changing shape; nothing runs between one change and the next. Names the cursor
  saw and did not know are kept in `/ftt diag`. *New in this release and not yet checked in the game: whether the cursor changes shape over a seat at all.*

## 0.2.1

- **Settings follow the character again.** Client build 1.60.1.70170 (Oct 1 2026) moved a character's
  surname into the realm slot of `UnitName`, so every character started a fresh, empty profile. The profile
  is now keyed by the full name and the realm (`Purrdee Bubson - ClassicBetaPvE`, the spelling the older
  builds saved under) and bound at PLAYER_LOGIN, when the client knows the name for sure, so a cold login no
  longer lands in an `Unknown` profile. Profiles saved under the other spellings are folded into it the
  first time each character logs in: the long-standing profile keeps its values, the others fill its gaps,
  and `/ftt diag` says what was adopted.
- The same client build reads saved settings back again, so the saved-settings bridge
  (`tools/Install-SavedStateBridge.ps1`) is no longer needed and `-Remove` takes it out.

## 0.2.0 - first public release

For **World of Warcraft: Forever** (1.60.1, Interface 16001).

The game tooltip follows your mouse instead of sitting in the corner, and says what Blizzard leaves out.
Every line can be switched off, and every one stays silent rather than guessing when the client will not
answer.

- **At the mouse**: right, left or centred above the cursor (`/ftt anchor`), with offsets. Done by
  changing only the anchor type after Blizzard has placed the tooltip - never by re-owning, clearing,
  showing or hiding it, which on this client would leave enemy tooltips empty in a fight.
- **Players' names in their class colour.** The tooltip's health bar can take it too (`/ftt class bar
  on`), off by default: Blizzard repaints that bar green on every refresh, and a unit frame under the
  mouse refreshes several times a second, so a coloured bar flickers there.
- **Health and power** (`/ftt health`): `700 hp (-300)` where both numbers can be read; `900 / 1,000 hp`
  where the current value is secret beside a readable maximum; `900 hp` where the maximum is secret too.
  Health is secret on this client for nearly every unit, so the last two are what you will mostly see;
  the colour tracks the damage only where a fraction can be read, and is grey otherwise. Mana blue,
  energy yellow, rage dark red.
- **Who they are targeting** - *you* stands out.
- **How far away**, in the bands the client will answer (10 / 11 / 28 yards) out of combat; in a fight
  that call is blocked by the client, so the line is absent there. **One spell, exactly** (`/ftt spell`)
  keeps working mid-fight, 40-yard heals included.
- **Your own pet's mood**, and the **spell or item id**.
- Secret values are never read, compared or subtracted - only handed to the widget that may show them.
- `/ftt` lists the commands; `/ftt diag` writes a report for bug reports.
