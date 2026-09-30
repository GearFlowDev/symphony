## Resolve Review

The plan is code-complete and tester-approved, but a reviewer (CodeRabbit and/or
a human) **requested changes**, so the PR is blocked. Your only job this phase is
to drive the review to approved. Do not add features or refactor unrelated code.

CodeRabbit runs in **request-changes mode** (org-wide): its review submits as
`CHANGES_REQUESTED` and **blocks merge even when CI is green**. A green
"CodeRabbit" status check only means it *ran*, not that its comments are
resolved. You are not done until **every** thread is resolved and the review has
flipped to APPROVED on the current HEAD.

### Step 1: Re-orient

```bash
cd {{ slot.directory }} && {{ tools.pr }} status
```

Its first line names the PR as `<repo>#<number>`, its `coderabbit:` line says whether
CodeRabbit's newest review is of the head commit, and its `threads:` line counts the
unresolved threads. Use that number as `$PR_NUM` below, and start each command with
`cd {{ slot.directory }} && PR_NUM=<number> && `.

### Step 2: List EVERY open review thread

Resolve them all — do not cherry-pick. Get the unresolved threads with their
comment bodies (some bodies are collapsed under `<details>` — read them in full):

```bash
gh api graphql -f query='
{ repository(owner:"{owner}",name:"{repo}"){ pullRequest(number:'"$PR_NUM"'){
  reviewThreads(first:100){ nodes { id isResolved
    comments(first:5){ nodes { author{login} path line body } } } } } } }'
```

CodeRabbit must have reviewed your latest push. The `coderabbit:` line of `pr status`
says so: `(head)` after the commit means it reviewed the head. If it did not, it has
not seen your changes yet. Wait for its re-review before you assume a thread is stale.

### Step 3: EVERY comment gets a reply — no exceptions

**The rule: every CodeRabbit comment must be answered with a reply — the ones you
fix AND the ones you won't.** A comment you silently ignore, or bulk-resolve
without a reply, is not addressed. `@coderabbitai resolve` is NOT a substitute
for replying: it closes threads but leaves the reviewer no record of your
decision. Reply first, resolve last.

List every unresolved CodeRabbit thread's root comment id (reply targets):

```bash
gh api repos/{owner}/{repo}/pulls/$PR_NUM/comments --paginate \
  --jq '.[] | select(.in_reply_to_id==null and (.user.login|startswith("coderabbit"))) | {id, path, line, body}'
```

For **each** one, post a reply to that specific thread — pick exactly one:

- **Fixing it** → make the change (with a test if code changed) and commit, then:
  ```bash
  gh api repos/{owner}/{repo}/pulls/$PR_NUM/comments/<comment_id>/replies \
    -f body="Fixed in <sha>: <one line on what changed>."
  ```
- **Not fixing it** (out of scope / already correct / wrong / a deliberate
  trade-off) → reply with a specific, honest reason — this is REQUIRED, not
  optional:
  ```bash
  gh api repos/{owner}/{repo}/pulls/$PR_NUM/comments/<comment_id>/replies \
    -f body="Won't change: <concrete reason>."
  ```

Run `direnv exec . mix check` and `direnv exec . mix test` after code changes,
then push with `cd {{ slot.directory }} && {{ tools.pr }} push --no-verify --base {{ slot.base_branch }}`.

### Step 4: Verify no comment is unanswered, then resolve

Before resolving, prove every CodeRabbit thread now has a reply authored by you —
if any root comment has zero replies, go back to Step 3:

```bash
gh api repos/{owner}/{repo}/pulls/$PR_NUM/comments --paginate \
  --jq 'group_by(.in_reply_to_id // .id)
        | map({thread: .[0], replies: (length-1)})
        | .[] | select(.thread.user.login|startswith("coderabbit")) | select(.replies==0)
        | "UNANSWERED: \(.thread.path):\(.thread.line) id=\(.thread.id)"'
```

Empty output = every comment answered. Only then, with CI green, post:

```bash
cd {{ slot.directory }} && {{ tools.pr }} coderabbit resolve
```

`pr coderabbit` posts the command as the PR's own opener, as the harness's CodeRabbit
rule requires.

CodeRabbit resolves its threads and auto-flips its review `CHANGES_REQUESTED →
APPROVED` within a minute or two (CI must be green). For human review threads,
resolve them via the GraphQL `resolveReviewThread` mutation after replying.

### Step 5: Never bypass it

Do **NOT** dismiss the review and do **NOT** `--admin` merge — the harness denies
both, and the orchestrator will keep reopening this issue while the review is
`CHANGES_REQUESTED`. If CodeRabbit hasn't approved a few minutes after every
thread is resolved and CI is green, emit `SYMPHONY_NEEDS_HELP: CodeRabbit stuck
at CHANGES_REQUESTED despite resolved threads + green CI` and stop — a human
dismissal is the only fallback.

### Step 6: Stop

End your turn after pushing and posting `@coderabbitai resolve`. The orchestrator
re-checks the review gate: approved → the issue ships; still requesting changes →
it dispatches Resolve Review again with what remains. Do not poll the review
yourself and do not move the issue's status.
