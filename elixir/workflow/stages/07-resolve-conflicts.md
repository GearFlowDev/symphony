## Resolve Conflicts

The plan is code-complete and tester-approved, but the base branch has moved and
the PR now has **merge conflicts**. Your only job this phase is to make the PR
mergeable again. Do not add features or refactor unrelated code.

### Step 1: Rebase onto the base branch

In your working directory:

```bash
BASE="${BASE_BRANCH:-main}"
git fetch origin "$BASE"
git rebase "origin/$BASE"
```

### Step 2: Resolve each conflict

For every conflicted file, understand **both** sides before choosing:

- Your branch's change exists to close a plan row — preserve its intent.
- The incoming change from the base branch shipped for a reason — preserve it too.
- When both touch the same lines, combine them; deleting either side's logic to
  make the conflict go away is almost always wrong.

After resolving each file: `git add <file>`, then `git rebase --continue` until
the rebase completes.

### Step 3: Verify, then push

```bash
direnv exec . mix test <files touched by the conflicts>
remote=$(git ls-remote origin "refs/heads/$(git branch --show-current)" | cut -f1)
git push --no-verify --force-with-lease="refs/heads/$(git branch --show-current):$remote" origin "$(git branch --show-current)"
```

Confirm the PR is mergeable again:

```bash
gh pr view --json mergeable --jq .mergeable   # must print MERGEABLE
```

`UNKNOWN` means GitHub is still recomputing — wait ~30s and re-check.

### Step 4: Stop

End your turn. Do not run `gh pr ready` (the PR is already ready and no PR here is
ever a draft), do not move the issue's status, and do not post
Linear comments — the orchestrator handles those. CI re-runs on your push; the
Fix CI phase handles it if it goes red.

Escalate with SYMPHONY_NEEDS_HELP only if the conflict is semantic and
unresolvable without a product decision — e.g. the base branch removed a module
or API your implementation depends on.
