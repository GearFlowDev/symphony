Continuation guidance (turn {{turn_number}}/{{max_turns}}):

You're still in the same Claude session as turn 1 — the assigned rows from your initial prompt are in your context. Keep closing them. The orchestrator's Grader runs after this dispatch ends and will mark each row `done` / `partial` / `missing` based on the diff alone.

{{comments_section}}

## Step 1: Re-orient

```bash
cd "$(grep -oE 'DIRECTORY=[^ ]+' .symphony_slot | cut -d= -f2)"
source .symphony_slot
git status --short
git log --oneline "origin/${BASE_BRANCH:-main}..HEAD" | head
```

If a previous turn left uncommitted changes, decide whether to keep or revert them — the new assignment may have changed what's needed.

## Step 2: Close the assigned rows

Same loop as the initial dispatch — for each row in the "Your assigned rows" list:

1. Write the failing test (from the row's `Tests:` line)
2. Implement the change (in the row's `Touches:` files)
3. Run `direnv exec . mix test <path>`
4. Commit per row: `{{ issue.identifier }}: <row-id> <summary>`

After all assigned rows have green tests and commits:

```bash
direnv exec . mix check
direnv exec . mix test
b="$(git branch --show-current)"
seen=$(git ls-remote origin "refs/heads/$b" | cut -f1)   # origin's tip BEFORE you rewrite anything
if [ -n "$seen" ]; then
  git fetch origin "refs/heads/$b"                        # the slot fetches main only
  git merge-base --is-ancestor "$seen" HEAD || git rebase "$seen"   # take in commits you lack
fi
git fetch origin "${BASE_BRANCH:-main}"
git rebase "origin/${BASE_BRANCH:-main}"
git push --no-verify --force-with-lease="refs/heads/$b:$seen" origin "$b"
```

## Step 3: @agent feedback

Check Linear for any `@agent` comments newer than your last commit:

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_API_KEY_AUTOMATION" \
  -H "Content-Type: application/json" \
  -d '{"query": "query { issue(id: \"{{issue_id}}\") { comments { nodes { body createdAt user { name } } } } }"}' \
  | python3 -c "import sys,json; [print(f'{c[\"user\"][\"name\"]}: {c[\"body\"]}') for c in json.load(sys.stdin)['data']['issue']['comments']['nodes'] if '@agent' in c['body'].lower()]"
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
