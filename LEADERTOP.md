# LEADERTOP (apps): the Protocol leaderboard

**Status:** design settled with the owner, 2026-10-29. Apple implements it (§12); ur.io, Android, Windows and Linux follow.

**What this doc covers:** how the apps present the SN25-aligned leaderboard. Apple is the reference implementation; ur.io, Android, Windows and Linux follow it with the same strings and rules.

**What it doesn't cover:** the ranking, the data and the API. Those are in [server/LEADERTOP.md](https://github.com/urnetwork/server/blob/main/LEADERTOP.md), and the Q numbers below are its design questions.

**Mockup:** the "Protocol leaderboard" design canvas, https://claude.ai/artifact/5yk5iLFfT1HAnCke8q8krx (private to the owner until shared; §11).

## 1. Purpose

The Protocol tab tells a provider whether claiming a Top 200 miner UID on SN25 is worth it: if they claimed now, would the validator rank them in its top 200?

- **Who it's for:** mainly networks that haven't claimed a UID yet.
- **Claimed networks** show their UID and the validator's ranking as extra detail.
- **People just outside** the top 200 can watch their progress toward the line.
- **Anyone projected inside** the top 200 is sent to claim on the Earnings page. Every claim prompt warns that a claimed fleet ranked 201 or lower earns nothing.

## 2. Tabs (Q14)

The leaderboard gets a third tab, and the new one comes first:

| Order | Tab | Source | Notes |
|---|---|---|---|
| 1, default | **Protocol** | `GET /sn/top`, `GET /sn/top/me` | new |
| 2 | **Points** | `POST /stats/points-leaderboard` | unchanged |
| 3 | **Data** | `POST /stats/leaderboard` | unchanged; frozen since the 2026-10-06 cutoff |

**On Apple:**
- `LeaderboardTab` gains `protocol` as its first case, and `selectedTab` defaults to it (`app/network/Main/Leaderboard/LeaderboardView.swift:13-37`).
- The segmented picker reads "Protocol", "Points", "Data".
- Tapping a tab, including the selected one, scrolls its list to the top (`mmm/DESIGNSTYLE.md`, "Long ranked lists").

## 3. Layout

The tab follows the Points tab's structure and the split rules in `mmm/DESIGNSTYLE.md` ("Layout follows the window", "Split layouts"):

- **Compact width (phones):** top to bottom: the status banner, the own-status card, the explainer, then the ranked list.
- **Regular width (iPad, Mac, wide windows):** the ranked list in the first pane, and the banner, own-status card and explainer in the second, as the Points tab does with its own-stats card.

Placeholders, never pop-in: while loading, the card and rows show placeholders with the real layout's sizes.

## 4. Status banner (Q16)

A one-line banner on top of the tab, driven by `snapshot.binding_open` and `binding_note`:

- **While binding is closed on mainnet:** "Claiming isn't open yet. You can see where you'd rank now." This uses the neutral style, not the error style.
- **When binding opens:** the banner is removed.
- **If the snapshot is stale** (computed more than 3 tempos ago): "Rankings last updated {time}."

## 5. Own-status card (`GET /sn/top/me`)

Shown when signed in, in the same place as the Points tab's own-stats card.

**Contents:**
- **Header:** the network's emoji tag and name (or "Anonymous"), and the "Show my network name" switch. That switch is shared with Points; it's `points_leaderboard_public` (Q12).
- **Position:** "#173 projected" and "of N ranked networks".
- **Margin to the 200 line,** with an arrow for the trend since the last tempo:
  - inside: "12% above the Top 200 line";
  - outside: "8% below the Top 200 line".
- **Label chip** (Q13, Q17):

  | Chip | When it shows |
  |---|---|
  | **Estimate** | before the board's measured precision reaches 90% |
  | **Likely** | inside by at least 20% and measurable, once precision reaches 90% |
  | **Borderline** | within 20% of the line |
  | **Unlikely** | more than 20% below the line |
  | **Not measurable** | the validator can't score the network yet |

- **Progress chart** (Q11): the network's daily projected rank over 90 days, with the 200 line drawn across, from `/sn/top/me`. It's a simple line with the y-axis inverted so up means better; tapping shows the day's rank.
- **Why this score:** distinct IP prefixes provided from, how many are shared and with how many others, and the "if you claimed alone today" score (Q4). Counts only, never IPs.

**Claim prompt** (Q5, Q13, Q16), shown only when the network is measurable and projected inside the top 200:

| Binding | What shows |
|---|---|
| Open | A primary button, "Claim on Earnings", that opens Earnings scrolled to its Top 200 tile. It's the screen's one primary button (`DESIGNSTYLE.md`, "One primary button per screen"). |
| Closed | A note instead of the button: "You're projected in the top 200. Claiming opens soon on the Earnings page." Nothing invites registering early. |
| Borderline | Adds "You're close to the line, and rankings change every tempo." |

Every prompt carries the warning: "A claimed fleet that ranks 201 or lower earns nothing."

**Not measurable:** the card says why ("Your devices aren't measured by the validator yet", or "Your devices share an IP with another network") and what helps. It shows no claim prompt.

## 6. Ranked list (`GET /sn/top`)

**Range:** the top 400 (Q5), paged 50 at a time. The draggable position indicator spans positions 1–400 (`DESIGNSTYLE.md`, "Long ranked lists").

**Row, left to right:**
- the position;
- the emoji tag and name, or "Anonymous". An anonymous claimed network shows "UID n" instead (Q12).
- the projected score, with a small trend arrow;
- a claimed badge, "UID 81", when the network has claimed;
- the label chip on the caller's own row only, so the list stays readable.

**The 200 line:** a divider between positions 200 and 201, reading "Top 200 line · score 41.2". Rows above it get a faint accent tint.

**Unmeasurable rows:** dimmed, with a small icon. VoiceOver reads "not measurable yet".

**The caller's row:** highlighted wherever it falls in the list. If it ranks below 400, the own-status card still shows its position.

**Claimed row detail:** tapping a claimed row opens a sheet:
- UID and generation, and when the claim is valid until (the epoch);
- the validator's rank and score, and whether it was selected this tempo (from the validator summary, Q9);
- on-chain incentive, with "stale" when flagged (Q10);
- the board's replica score.

## 7. Explainer

A short paragraph under the card, or in the second pane at regular width:

> Ranked the way the SN25 validator picks its Top 200: by how many distinct IP prefixes your devices provide from, with shared prefixes split between the networks on them. Updated about every 72 minutes. These are projections until you claim.

## 8. Earnings page

**Today:** the Top 200 tile (`Main/Account/Earnings/EarningsTiles.swift`, `Top200Tile`) reads `GET /sn/head` and says "ranks about #N of 200 head spots".

**Changes:**
- It reads `GET /sn/top/me`, so it shows the same projected position, margin and label as the Protocol tab.
- **While binding is closed:**
  - The "Claim your spot" button becomes the note "Claiming opens soon".
  - "Sign fleet binding" stays hidden.
- **When binding opens,** the existing claim flow is unchanged.
- **Claimed networks:** the tile shows the fleet's UID, validator rank and selection, as in the row detail sheet.

## 9. States

| State | What shows |
|---|---|
| Loading | placeholders for the card, rows and chart |
| Signed out | the public list only; no card; a sign-in prompt in the card's place |
| Empty snapshot | "Rankings will appear after the next update." |
| Load failed | the standard retry row; a failed refresh keeps the rows and shows a notice |

## 10. Strings and accessibility

- **Strings:** new keys go in the shared localizations store as `leaderboard_protocol_*`, tagged for `site`, `apple`, `android`, `windows` and `linux`.
  - They cover the tab name, banner, card lines, labels, the claim prompt and warning, the 200 line, the explainer, and the empty and error texts.
  - Apple looks strings up by their English text, so its view code must use the stored English exactly.
- **Accessibility:**
  - The 200 line is a VoiceOver element: "Top 200 line, score 41.2".
  - Label chips read as text.
  - The progress chart has an accessible summary, for example "Projected rank 173, up 12 places this week".

## 11. Mockup

The "Protocol leaderboard" design canvas shows:
- compact-width (iPhone): the tab with the banner, own-status card, explainer and ranked list around the 200 line;
- the claim prompt with binding closed and with it open;
- a claimed row's detail sheet;
- regular width (iPad or Mac) split.

It uses the apps' dark theme. It illustrates the layout; the stored strings and theme tokens are what ship.

## 12. Apple implementation notes

Rules the reference implementation settled where the design leaves room. The other apps should match them.

- **Claim prompt:** shown only for a row the server flags `claim_prompt` that is also measurable and at positions 1–200, and never for a network that has already claimed. The close-to-the-line line shows when the label is borderline, or, while labels read "estimate", when the margin is within ±20%.
- **Earnings tile:** shown for a network the board prompts to claim, or for one that has claimed (at any position), and hidden otherwise. Its margin is signed: "+12%", "−8%".
- **Card header:** the network's name while "Show my network name" is on, else "Anonymous". The switch is the Points board's own. Until the snapshot carries a name just turned on, the session's name stands in.
- **Signed out:** the public list only, with no card. Apple shows no sign-in prompt, since its tabs exist only in a session and there is no key for one.
- **Paging:**
  - The first page asks for 50 rows, and later pages follow `next` alone.
  - A seek asks for up to 200 rows at once.
  - A page that adds no rows ends the list, and a page from another snapshot restarts it.
- **Reload:** the tab reloads when it becomes visible again after 5 minutes.
- **VoiceOver:** a row reads "You" for the caller, the rank, the name, the score and its trend, the claimed UIDs, then the caller's label or "Not measurable".
