## Resolve Conflicts

The plan is code-complete and tester-approved, but the base branch has moved and
the PR now has **merge conflicts**. Your only job this phase is to make the PR
mergeable again. Do not add features or refactor unrelated code.

### Step 1: Merge the base branch in

```bash
cd {{ slot.directory }} && {{ tools.pr }} push --no-verify --base {{ slot.base_branch }}
```

`pr push` takes in any commits origin has on the branch, then merges
`origin/{{ slot.base_branch }}`. When the merge conflicts, it stops and names the
conflicted files. When it merges clean, it pushes, and you go to Step 3.

### Step 2: Resolve each conflict

For every conflicted file, understand **both** sides before choosing:

- Your branch's change exists to close a plan row — preserve its intent.
- The incoming change from the base branch shipped for a reason — preserve it too.
- When both touch the same lines, combine them; deleting either side's logic to
  make the conflict go away is almost always wrong.

After resolving each file: `git add <file>`. When every file is resolved,
`git commit --no-edit` to complete the merge.

### Step 3: Verify, then push

```bash
cd {{ slot.directory }} && direnv exec . mix test <files touched by the conflicts>
cd {{ slot.directory }} && {{ tools.pr }} push --no-verify --base {{ slot.base_branch }}
cd {{ slot.directory }} && {{ tools.pr }} status --no-logs
```

`pr push` never force-pushes. If origin moved since Step 1, it merges the new
commits in first, and stops again on a conflict.

The first line of `pr status` must not be `FAILING` with "conflicts with its base".
`PENDING` means GitHub is still computing mergeability or CI runs: that is fine, and
you do not poll it.

### Step 4: Stop

End your turn. Do not run `gh pr ready` (the PR is already ready and no PR here is
ever a draft), do not move the issue's status, and do not post
Linear comments — the orchestrator handles those. CI re-runs on your push; the
Fix CI phase handles it if it goes red.

Escalate with SYMPHONY_NEEDS_HELP only if the conflict is semantic and
unresolvable without a product decision — e.g. the base branch removed a module
or API your implementation depends on.
