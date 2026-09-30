Continuation guidance (turn {{turn_number}}/{{max_turns}}):

You're still in the same Claude session as turn 1 — the assigned rows from your initial prompt are in your context. Keep closing them. The orchestrator's Grader runs after this dispatch ends and will mark each row `done` / `partial` / `missing` based on the diff alone.

{{comments_section}}

## Step 1: Re-orient

Your slot is `{{ slot.directory }}`. Start every command with `cd {{ slot.directory }} && `.

```bash
cd {{ slot.directory }} && git status --short && git log --oneline origin/{{ slot.base_branch }}..HEAD | head
```

If a previous turn left uncommitted changes, decide whether to keep or revert them — the new assignment may have changed what's needed.

## Step 2: Close the assigned rows

Same loop as the initial dispatch — for each row in the "Your assigned rows" list:

1. Write the failing test (from the row's `Tests:` line)
2. Implement the change (in the row's `Touches:` files)
3. Run `direnv exec . mix test <path>`
4. Commit per row: `{{ issue.identifier }}: <row-id> <summary>`

After all assigned rows have green tests and commits, check, then push through `pr`:

```bash
cd {{ slot.directory }} && direnv exec . mix check && direnv exec . mix test
cd {{ slot.directory }} && {{ tools.pr }} push --no-verify --base {{ slot.base_branch }}
```

`pr push` takes in any commits origin has on the branch, merges `origin/{{ slot.base_branch }}`, and pushes, without a force-push. On a merge conflict it names the files: resolve them, `git commit`, and run it again. If no PR is open yet, run the Implement phase's `pr ship` line instead.

## Step 3: @agent feedback

Check Linear for any `@agent` comments newer than your last commit, through `bin/linear` (never `curl`):

```bash
cd {{ slot.directory }} && {{ tools.linear }} comments {{ issue.identifier }} --since "$(git log -1 --format=%cI)" | grep -i -B2 -A20 '@agent'
```

`@agent` instructions take priority over the row queue — implement them in this dispatch.

## Step 4: Stop

End your turn. The Grader runs next.

Do NOT:
- Post a status comment (orchestrator owns Linear comms).
- Update a `WORKPAD.md` file (none exists; plan is in the DB).
- Take screenshots (Test phase, not yours).
- Re-run after a green push.

## SYMPHONY_NEEDS_HELP

Only for true blockers — missing backend/data/design, broken slot, contradictory rows. Otherwise, pick the most reasonable interpretation and continue.
