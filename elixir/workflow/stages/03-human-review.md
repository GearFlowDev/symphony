## Share Evidence

You MUST post test results to the **Linear issue** — NOT to the GitHub PR.

Your job: log in to the app, verify it works in a real browser, take screenshots, and post them to Linear. Do NOT read source code, do NOT investigate the codebase, do NOT fix anything.

### Step 1: Get your workspace info

```bash
set -a; source .symphony_slot; set +a   # exports PHOENIX_PORT for the node script
cd "$DIRECTORY"
```

The app is Phoenix LiveView on `PHOENIX_PORT`; there is no frontend server. The backend is NOT started for you: start it when it is down, and stop it when you are done.

```bash
curl -sf "http://127.0.0.1:$PHOENIX_PORT/" >/dev/null \
  || { direnv exec . mix phx.server > .phx.log 2>&1 & }
up=""
for _ in $(seq 1 60); do curl -sf "http://127.0.0.1:$PHOENIX_PORT/" >/dev/null && up=1 && break; sleep 2; done
[ -n "$up" ] && echo "backend up" || { echo "backend DOWN after 120 s — see .phx.log"; tail -n 30 .phx.log; }
```

If the backend is DOWN, post a comment that says so, with the tail of `.phx.log`, and stop. Do not post screenshots of an error page.

### Step 2: Browser testing

Test the app in a real browser. The `screenshot` skill in the gf_engineering workspace is the full method (`$GEARFLOW_WORKSPACE/.claude/skills/screenshot/SKILL.md`).

#### Browser tooling

Playwright with Chromium is installed globally — drive it from a small node script, NOT via a Playwright MCP server (MCP burns enormous context). Write the script to `/tmp/evidence.js` and run with `NODE_PATH=$(npm root -g) node /tmp/evidence.js`:

```js
const { chromium } = require('playwright');
(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  // 127.0.0.1, not localhost: slot servers bind IPv4 and `localhost` can resolve to ::1.
  const app = `http://127.0.0.1:${process.env.PHOENIX_PORT}`;
  // Dev-only auto-login: it sets the session cookie, no login page.
  await page.goto(`${app}/xray/${encodeURIComponent(process.env.WALK_EMAIL)}`);
  // ... navigate, then:
  await page.screenshot({ path: '/tmp/evidence-page.png', fullPage: true });
  await browser.close();
})();
```

#### Login

1. Log in with the dev-only auto-login: `http://127.0.0.1:$PHOENIX_PORT/xray/<email>`. It sets the session cookie. The login page sends a one-time code, so a script cannot use it.
2. Use the dispatcher test account: `WALK_EMAIL="${GF_EMAIL_HANDLE:-$(whoami)}+dispatcher@gearflow.com"`.
3. Wait for the dashboard to load

#### Smoke test — navigate core pages

After login, navigate to each of these index pages and confirm they load without errors:
- `/issues` (Issues)
- `/requisitions` (Requisitions)
- `/mobilizations` (Mobilizations)
- `/maintenance` (Maintenance)

Take a screenshot of at least the Requisitions page as baseline evidence.

#### Issue-specific testing

Read the issue description to understand what changed. If the change is user-facing:
- Navigate to the affected page(s)
- Exercise the specific flow described in the issue
- Take screenshots at each key step showing the change works
- If the issue involves role restrictions, test with the appropriate role accounts:
  - Dispatcher: `${GF_EMAIL_HANDLE:-$(whoami)}+dispatcher@gearflow.com`
  - Requester: `${GF_EMAIL_HANDLE:-$(whoami)}+requester@gearflow.com`
  - Manager: `${GF_EMAIL_HANDLE:-$(whoami)}+manager@gearflow.com`

If the change is backend-only (no UI impact), the smoke test screenshots are sufficient.

### Step 3: Upload screenshots and post to Linear

Upload the screenshots you captured and collect ready-to-paste markdown. Pass
the ACTUAL files you saved (any names). The helper uploads each to Linear,
prints one `![name](assetUrl)` line per file, and NEVER prints an empty `![]()`:

```bash
URLS=$("${SYMPHONY_SCRIPTS}linear-embed-images.sh" /tmp/evidence-*.png)   # <- use YOUR real screenshot paths
```

If `$URLS` is empty the upload failed — do NOT post empty `![]()`; fix the paths
and re-run. Then post a comment with the embedded screenshots through
`bin/linear`, never `curl`:

```bash
printf '## Browser Test Results\n\nLogged in and verified core pages load. Screenshots below.\n\n%s\n' "$URLS" \
  > /tmp/evidence-{{ issue.identifier }}.md
LINEAR="${GEARFLOW_WORKSPACE:-/data/workspace}/local-dev/gf_harness_surfaces/bin/linear"
"$LINEAR" comment {{ issue.identifier }} --body-file /tmp/evidence-{{ issue.identifier }}.md
```

### Done

Stop here. Do not read source code. Do not investigate. Do not fix anything.
