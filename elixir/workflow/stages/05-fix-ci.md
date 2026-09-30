## Fix CI

The PR is code-complete and tester-approved, but **CI is red**. Your only job
this phase is to make CI green. Do not add features or refactor unrelated code.

### Step 1: Find what failed — and read the actual logs

Do NOT guess from the check name. Get the real failure output.

```bash
cd {{ slot.directory }} && {{ tools.pr }} status
```

The first line is the verdict. Under `FAILING`, `pr status` lists each failed check
with the tail of its failed-step log. For a longer log, take the job id from
`pr status --json` (`.checks[].job`) and run:

```bash
cd {{ slot.directory }} && gh run view --job <job-id> --log-failed
```

Read the failed log. Identify the exact failing test, compile error, or lint
finding — the file, the assertion, the message. This is the failure you must
reproduce.

### Step 2: Reproduce locally

Run the same thing CI runs, in your working directory:

```bash
cd {{ slot.directory }} && direnv exec . mix test   # the failing suite (or `mix test <path>` for one)
cd {{ slot.directory }} && direnv exec . mix check  # format, credo, compile-as-error, etc.
```

If it passes locally but fails in CI, the failure is environment- or
data-dependent (seed, ordering, async, fixture). Read the log again for the
discriminator — do not push hoping it passes.

### Step 3: Fix the real cause

Fix the code or the test so the failure is gone. Match the surrounding style.
Do not delete or skip a failing test to make it pass.

### Step 4: Verify, commit, push

```bash
cd {{ slot.directory }} && direnv exec . mix test && direnv exec . mix check
cd {{ slot.directory }} && git add -A && git commit -m "{{ issue.identifier }}: fix CI" && \
  {{ tools.pr }} push --no-verify --base {{ slot.base_branch }}
```

### Step 5: Stop

End your turn after pushing. The orchestrator re-checks the PR's CI: green →
the issue ships; still red → it dispatches Fix CI again with the new failure.
Do not poll CI yourself and do not move the issue's status.
