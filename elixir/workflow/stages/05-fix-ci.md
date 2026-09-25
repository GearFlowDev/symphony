## Fix CI

The PR is code-complete and tester-approved, but **CI is red**. Your only job
this phase is to make CI green. Do not add features or refactor unrelated code.

### Step 1: Find what failed — and read the actual logs

Do NOT guess from the check name. Get the real failure output.

```bash
PR_NUM=$(gh pr list --head "$(git branch --show-current)" --json number --jq '.[0].number')

# Failing checks + their run/job links
gh pr checks $PR_NUM --json name,state,link --jq '.[] | select(.state != "SUCCESS")'

# For each failing check, pull the failing step's log from its run:
RUN_ID=$(gh pr checks $PR_NUM --json state,link --jq '.[] | select(.state != "SUCCESS") | .link' | grep -oE 'runs/[0-9]+' | grep -oE '[0-9]+' | head -1)
gh run view $RUN_ID --log-failed
```

Read the failed log. Identify the exact failing test, compile error, or lint
finding — the file, the assertion, the message. This is the failure you must
reproduce.

### Step 2: Reproduce locally

Run the same thing CI runs, in your working directory:

```bash
direnv exec . mix test            # the failing suite (or `mix test <path>` for one)
direnv exec . mix check           # format, credo, compile-as-error, etc.
```

If it passes locally but fails in CI, the failure is environment- or
data-dependent (seed, ordering, async, fixture). Read the log again for the
discriminator — do not push hoping it passes.

### Step 3: Fix the real cause

Fix the code or the test so the failure is gone. Match the surrounding style.
Do not delete or skip a failing test to make it pass.

### Step 4: Verify, commit, push

```bash
direnv exec . mix test && direnv exec . mix check
git add -A && git commit -m "{{ issue.identifier }}: fix CI" && git push --no-verify
```

### Step 5: Stop

End your turn after pushing. The orchestrator re-checks the PR's CI: green →
the issue ships; still red → it dispatches Fix CI again with the new failure.
Do not poll CI yourself and do not move the issue's status.
