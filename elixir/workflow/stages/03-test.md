## Test

You are running as the **tester sub-agent** for `{{ issue.identifier }}`. The Implement phase has finished. A PR is open. Your job is to independently verify every Contract row and produce a Tester Report. You did NOT write the code, and you may NOT modify it. Your only output is the Tester Report comment on Linear.

Match the verification to the row's deliverable:

- **UI rows** — walk them in a real browser (Steps 2-4 below).
- **Backend-only rows** — run the row's tests plus the full suite; no browser needed.
- **Documentation / research rows** (no `Tests:` line, deliverable is a committed doc) — verify the artifact instead: it exists in the PR diff, every section the issue body required is present and substantive, and its references are real (issue links resolve, cited file:line locations exist, claimed data has a stated source). Skip the browser preflight entirely for a docs-only PR.

**Why this is a separate phase**: the worker who wrote the code is the worst person to verify it works — they remember which paths they walked and unconsciously avoid the ones they didn't. You start fresh, with no assumption about what's done.

### Step 1: Load the Contract

1. Work in `{{ slot.directory }}`: start every command with `cd {{ slot.directory }} && `.
2. Read the latest `## Contract Audit` comment on Linear and `WORKPAD.md` at the repo root. The Contract row list is your test plan.
3. Read `docs/<area>/TESTER_PROMPT.md` if it exists in this repo. If a process-specific tester playbook exists, follow it instead of these generic instructions.
4. Read the PR's state, and put the slot on the PR's head:
   ```bash
   cd {{ slot.directory }} && {{ tools.pr }} status --no-logs
   cd {{ slot.directory }} && git checkout {{ issue.branch_name }} && git pull --ff-only origin {{ issue.branch_name }}
   ```
   The first line of `pr status` names the PR, and its `pr:` line gives the head commit you test.

### Step 2: Preflight

```bash
# Backend up, and the asset bundle built: `slot-app up` runs the setup task (deps,
# migrations, assets.build) and starts the backend; `wait` polls it. Phoenix serves every
# page on port {{ slot.phoenix_port }}; there is no frontend server.
{{ tools.slot_app }} --slot {{ slot.directory }} up && {{ tools.slot_app }} --slot {{ slot.directory }} wait --timeout 300
cd {{ slot.directory }} && ls -la priv/static/assets/app.js

# Playwright is on the system via npx — verify (will install Chromium on first call)
npx --yes playwright --version
```

After the walk, stop the app and keep Postgres for the next dispatch:

```bash
{{ tools.slot_app }} --slot {{ slot.directory }} down && {{ tools.slot_app }} --slot {{ slot.directory }} up --minimal
```

If `app.js` is < ~250KB, the bundle is a stub: rebuild it with `cd {{ slot.directory }} && direnv exec . mix assets.build` and retry. If preflight fails (a stub bundle after a rebuild, or a `slot-app` failure), post a `## Tester Report` with `Recommendation: BLOCKED` and stop.

### Step 3: How to drive a real browser (use this — do NOT report "no Playwright tooling")

The `screenshot` skill in the gf_engineering workspace is the full method (`$GEARFLOW_WORKSPACE/.claude/skills/screenshot/SKILL.md`). The short form follows.

You are running inside Symphony's harness with an empty MCP server config — there is no Playwright MCP. **That does not mean Playwright is unavailable.** It is installed on the system. Drive it directly from Bash via `npx playwright`.

The pattern: write a one-shot Node script per page that opens the LiveView route on `PHOENIX_PORT`, takes screenshots at desktop (1280) and tablet (768) widths, and prints any console errors. Then attach the PNGs to your Tester Report with `bin/linear comment --image` (Step 5).

Example you can adapt — save as `/tmp/walk-<page>.cjs`. Playwright is installed globally, so run it with `NODE_PATH="$(npm root -g)"`: a script under `/tmp` cannot resolve the package otherwise, and an ES module ignores `NODE_PATH`, so the script is CommonJS.

```javascript
const { chromium } = require('playwright');

(async () => {

// 127.0.0.1, not localhost: slot servers bind IPv4 and `localhost` can resolve to ::1.
const APP = `http://127.0.0.1:${process.env.PHOENIX_PORT}`;
const PAGE = process.argv[2] || '/issues';
const EMAIL = process.env.WALK_EMAIL; // a seeded user, e.g. "${GF_EMAIL_HANDLE:-$(whoami)}+dispatcher@gearflow.com"

const errors = [];
const browser = await chromium.launch();

for (const [width, label] of [[1280, 'desktop'], [768, 'tablet']]) {
  const ctx = await browser.newContext({ viewport: { width, height: 900 } });
  const page = await ctx.newPage();
  page.on('console', msg => { if (msg.type() === 'error') errors.push(`${label} ${PAGE}: ${msg.text()}`); });
  // Log in with the dev-only auto-login: it sets the session cookie, no login page.
  // (The Full Platform's login page sends a one-time code, so a script cannot use it.)
  await page.goto(`${APP}/xray/${encodeURIComponent(EMAIL)}`, { waitUntil: 'networkidle' });
  await page.goto(`${APP}${PAGE}`, { waitUntil: 'networkidle' });
  await page.screenshot({ path: `/tmp/walk-${PAGE.replaceAll('/','_')}-${label}.png`, fullPage: true });
  await ctx.close();
}

await browser.close();
console.log(JSON.stringify({ errors }, null, 2));
})();
```

Then for each page:

```bash
PHOENIX_PORT={{ slot.phoenix_port }} WALK_EMAIL="${GF_EMAIL_HANDLE:-$(whoami)}+dispatcher@gearflow.com" \
  NODE_PATH="$(npm root -g)" node /tmp/walk-<page>.cjs <route>
```

Keep the list of PNG files you saved. Step 5 attaches each one to the report with its
own `--image`. Never hand-write an image tag, and never post an empty `![]()`.

If `npx playwright` fails to launch Chromium (first-run), do `npx --yes playwright install chromium` once and retry.

### Step 4: Walk every Contract row

For each row in the Contract:

1. Run the Playwright script for the route covering this row.
2. **Two-record rule.** Walk it on at least two representative records (empty + populated, two card variants, or one of each role-gated record). Add a second route invocation with a different record id.
3. **Click everything** the row covers — buttons, dropdowns, dialogs, drag targets, keyboard shortcuts. Extend the script with `page.click()` / `page.keyboard.press()` calls. The point is to surface event handlers that crash on second-render.
4. **Verify against the issue's own requirements.** There is no React app to diff against: it was deleted on 2026-07-06 (GEA-4136). When the issue names a reference (a design, a sibling page, a storybook component), diff your screenshots against that reference on copy, icon name, badge variant and dropdown option format.
5. **Console must be clean.** The script's `errors` output is your evidence. New errors are blockers; pre-existing warnings are allowed only if listed in the Contract's "Known issues" section.
6. Mark the row in your scratchpad:
   - `✅ verified` — implemented and behaves like the spec
   - `⚠ partial` — implemented but with drift; describe the drift specifically
   - `❌ missing or broken` — not implemented, or implemented but crashes / misbehaves

### Step 4b: Shell & integration (overlay / cross-cutting components)

If the work adds or changes an overlay/sheet/modal, or a component reachable from more than one page, walking the content rows is NOT enough — the gaps live in how the component behaves as a *shell* and integrates with the rest of the app, none of which shows up as a per-row "does the card render". Against the reference the issue names (a design, or the sibling components that already do this), verify and screenshot:

- **Dismiss & interaction.** Open it, then: click a blank area outside it (does it close like the reference?), click a nav link or button *outside* it (does the link navigate, or get eaten by an overlay?), press Escape, and use the back/close control. Match the reference's backdrop exactly — a dimmed scrim, or deliberately none with the underlying list still visible and interactive.
- **Every breakpoint.** At mobile and desktop widths, confirm the layout matches the reference (e.g. full-screen vs. fixed-width sidebar) at the *same* breakpoint the reference uses — don't accept `sm` where the reference flips at `md`.
- **Every entry point.** Open it from each surface the reference exposes it on — a per-page bell/button on each section page, deep-link URLs — not only its own route. A missing entry point is a missing row even when the component itself is perfect.

Drift here (wrong backdrop, wrong breakpoint, a missing entry point, the wrong dismiss destination) is `⚠ partial` or `❌`, exactly like content drift.

### Step 4c: Sibling-route sweep (component + siblings)

A change is only safe if it doesn't break its neighbors. Load the component's own route AND every sibling section route that shares its layout or data helpers. Assert each returns HTTP 200 with a clean console — no 500, `KeyError`, or `Ecto.Query.CastError`. This is cheap and catches the classic failures: a `/:section/inbox` path cast as a record id, or a shared helper that returns an incomplete struct once a new template branch reads it. Any crash is `❌` and forces `REQUEST_CHANGES` (or `BLOCKED` if the route won't load at all), regardless of how clean the content rows looked.

### Step 4d: Structural completeness sweep (every PR, not just UI)

The browser walk proves the paths you walked work; it says nothing about the callers you didn't walk. The dominant defect in this system is a change that lands in one place and leaves its siblings behind — a function whose contract moved while some callers kept the old usage, a schema field or table whose new writer was added but legacy write paths still bypass it, a new module nothing calls. A green suite hides all three. So run a static sweep, code-aware, before you decide:

```bash
cd {{ slot.directory }} && git fetch -q origin {{ slot.base_branch }}
# What contracts did this branch change?
cd {{ slot.directory }} && git diff origin/{{ slot.base_branch }}..HEAD | grep -E '^[+-].*\b(def |defp |field :|create table|alter table)'
```

For each changed function signature / return shape, each added-or-changed schema field or table, and each new module:

1. `grep -rn '\bthe_name\b' lib/` (and the table name for schema changes) for every other caller/reader/writer.
2. Open each hit the diff did NOT touch. Does it still pass the old arguments, read the legacy column, or otherwise assume the old contract? If so that is a **real gap**, not a style nit — verify it end to end (does the old caller now misfire or silently no-op?), then mark it `❌`.
3. A new module with no non-test caller is dead code → `❌` the row that was meant to wire it in.

Report what you swept and what you found. Treat a confirmed stale caller / un-updated writer / dead module exactly like a broken Contract row: it forces `REQUEST_CHANGES`, with the specific `file:line` in your reason. Be concrete — a mere textual mention of a name is not a defect; only flag a caller that genuinely still relies on the old contract.

### Step 5: Post the Tester Report — to Linear ONLY

**The Tester Report goes to the Linear issue and NOWHERE else.** The orchestrator
parses it from Linear comments — a report posted to the GitHub PR is invisible to
it, so the issue loops forever. Write the report to a file and post it through
`bin/linear`, never `curl`:

```bash
{{ tools.linear }} comment {{ issue.identifier }} --body-file /tmp/tester-report-{{ issue.identifier }}.md \
  --image /tmp/walk-_issues-desktop.png --alt "/issues, desktop" \
  --image /tmp/walk-_issues-tablet.png --alt "/issues, tablet"   # <- one --image per PNG you saved
```

Each `--image` uploads one file to Linear and embeds it at the end of the report, after
the Recommendation line; the Nth `--alt` captions the Nth image. If `bin/linear` fails on
a file, it posts no report: fix the path and run it again.

**NEVER** post the report to GitHub — no `gh pr comment`, no `gh pr review`, no
`gh api .../issues/comments`. Nothing about the report touches the PR.

Report format:

```
## Tester Report

- PR: <url>
- Records walked: <list, e.g. "Issue ABC (populated, equipment card), Issue XYZ (empty state)">
- Roles tested: <list, e.g. "dispatcher, requester">
- Console: <clean | new errors: <list>>
- Asset bundle: <fresh ~XXX KB | stub>
- Shell (overlay/cross-cutting only): <n/a | verified: dismiss+breakpoints+entry-points | drift: <list>>
- Sibling-route sweep: <n/a | routes loaded clean: <list> | crashes: <list>>
- Structural completeness sweep: <changed contracts checked: <list of symbols/tables> | callers/writers all carried | stale: <file:line list>>

### Verified rows

- ✅ Row 1 — <one-line confirmation, with screenshot link if visual>
- ✅ Row 2 — ...

### Drift / partial

- ⚠ Row N — <specific drift, e.g. "the button label says 'Update' but the issue says 'Save'">

### Missing / broken

- ❌ Row M — <what's missing or how it crashes, with reproduction steps>

**Recommendation: APPROVE** | **REQUEST_CHANGES** | **BLOCKED**

<no Screenshots section: `--image` appends every state and dialog you walked, at
both widths, below this line>
```

The `Recommendation:` line is parsed by the orchestrator by exact match, so
**every report MUST contain one literal `Recommendation: APPROVE`,
`Recommendation: REQUEST_CHANGES`, or `Recommendation: BLOCKED` line.** This is
true on a re-test too: if nothing changed and the work is still good, that is an
`APPROVE` — say `Recommendation: APPROVE` again in full. Do NOT write shorthand
like "no drift, standing recommendation holds" or "see prior report" and do NOT
reference a previous verdict instead of stating one — the orchestrator can't
parse that, reads it as REQUEST_CHANGES, and loops the issue forever. Choose:

- **APPROVE** — every Contract row is `✅ verified`, console is clean, no drift, the structural completeness sweep is clean (no stale caller / un-updated writer / dead module), and (for an overlay/cross-cutting component) the shell is verified and the sibling-route sweep is clean. The orchestrator marks Test done and dispatches Share Evidence.
- **REQUEST_CHANGES** — at least one row is `⚠` or `❌`. The orchestrator re-dispatches Implement to address the gaps.
- **BLOCKED** — the page can't be tested at all (preflight failed, page won't load, slot is broken). Include a description of the blocker.

### Step 6: Emit the machine verdict

After the Linear report is posted, print the machine-readable verdict on its own
line in your output (this is separate from the Linear comment — the orchestrator
reads it from your output stream, and it is how your verdict actually reaches the
machine; the Linear report is for humans):

```
SYMPHONY_VERDICT: APPROVE <pr-head-sha>
SYMPHONY_VERDICT: REQUEST_CHANGES <pr-head-sha> — <one-line reason>
```

Use `APPROVE`, `REQUEST_CHANGES`, or `BLOCKED` to match your `Recommendation:`
line exactly, and append the PR head SHA you tested (`git rev-parse HEAD`). Emit
this on **every** run, including re-tests.

For `REQUEST_CHANGES` and `BLOCKED`, append ` — ` and a **single-line** reason
naming the concrete gap (file/behavior), e.g.
`REQUEST_CHANGES abc1234 — create/update in Jobs context still lack the admin gate`.
The orchestrator stores it and feeds it into the next worker's prompt — without
it the next Implement pass has to re-guess what you objected to. Keep it on one
line; everything after a newline is dropped.

### Step 7: Stop

Do NOT modify code. Do NOT push. Do NOT open or close PRs. Your outputs are the
Linear Tester Report comment and the `SYMPHONY_VERDICT` line.

End your turn cleanly after posting. The orchestrator reads the verdict and decides whether to dispatch the next phase or re-dispatch Implement.
