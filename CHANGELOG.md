# AKForeverTooltip

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
