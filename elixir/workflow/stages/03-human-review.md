## Share Evidence

You MUST post test results to the **Linear issue** — NOT to the GitHub PR.

Your job: log in to the app, verify it works in a real browser, take screenshots, and post them to Linear. Do NOT read source code, do NOT investigate the codebase, do NOT fix anything.

### Step 1: Start the app

The app is Phoenix LiveView on `http://127.0.0.1:{{ slot.phoenix_port }}`; there is no frontend server. The backend is NOT started for you. Start it and wait for it in one call:

```bash
{{ tools.slot_app }} --slot {{ slot.directory }} up && {{ tools.slot_app }} --slot {{ slot.directory }} wait --timeout 300
```

If either step fails, post a comment that says so, with the log tail it printed, and stop. Do not post screenshots of an error page.

When you are done with the browser, stop the app and keep Postgres for the next dispatch:

```bash
{{ tools.slot_app }} --slot {{ slot.directory }} down && {{ tools.slot_app }} --slot {{ slot.directory }} up --minimal
```

### Step 2: Browser testing

Test the app in a real browser. The `screenshot` skill in the gf_engineering workspace is the full method (`$GEARFLOW_WORKSPACE/.claude/skills/screenshot/SKILL.md`).

#### Browser tooling

Playwright with Chromium is installed globally — drive it from a small node script, NOT via a Playwright MCP server (MCP burns enormous context). Write the script to `/tmp/evidence.js` and run it with `PHOENIX_PORT={{ slot.phoenix_port }} WALK_EMAIL=<email> NODE_PATH=$(npm root -g) node /tmp/evidence.js`:

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

### Step 3: Post the screenshots to Linear

Write the comment body to a file, then post it through `bin/linear`, never `curl`. Give one `--image` per screenshot you saved, with an `--alt` that says what it shows. `bin/linear` uploads each file to Linear and embeds it at the end of the comment, so you never write an image URL by hand:

```bash
printf '## Browser Test Results\n\nLogged in and verified core pages load. Screenshots below.\n' \
  > /tmp/evidence-{{ issue.identifier }}.md
{{ tools.linear }} comment {{ issue.identifier }} --body-file /tmp/evidence-{{ issue.identifier }}.md \
  --image /tmp/evidence-requisitions.png --alt "Requisitions index, dispatcher" \
  --image /tmp/evidence-<page>.png --alt "<what it shows>"   # <- YOUR real screenshot paths
```

If `bin/linear` fails on a file, it posts no comment. Fix the path and run it again.

### Done

Stop here. Do not read source code. Do not investigate. Do not fix anything.
