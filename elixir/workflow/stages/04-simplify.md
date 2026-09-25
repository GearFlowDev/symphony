## Simplify

### Check CI status

First, check if CI passed on the PR:

```bash
PR_NUM=$(gh pr list --head "$(git branch --show-current)" --json number --jq '.[0].number')
gh pr checks $PR_NUM
```

If any checks failed:
1. Read the failure details: `gh pr checks $PR_NUM --json name,state --jq '.[] | select(.state != "SUCCESS")'`
2. Fix the issue locally
3. Run `direnv exec . mix check` to verify
4. Commit and push the fix

Do not proceed with simplification until CI is green.

### Address PR review feedback

Resolving CodeRabbit / human review threads is handled by the dedicated **Resolve
Review** phase (the orchestrator dispatches it when a review requests changes).
Do not duplicate that work here — focus this phase on simplification.

### Check test coverage

If the PR changed backend business logic without tests, add them before simplifying.

### Review the diff for simplification

```bash
git diff origin/main --stat
```

Then read specific files that look like they need simplification — do NOT dump the entire diff.

Look for:
- Duplicated logic that could be extracted
- Overly complex conditionals that can be simplified
- Inconsistent naming or patterns relative to the surrounding code
- Dead code or unnecessary changes
- Opportunities to reuse existing utilities or patterns in the codebase

### Simplify

Make targeted improvements. Rules:
- Only touch files in the PR diff — do not refactor unrelated code
- Do not add features or change behavior
- Do not add unnecessary abstractions for one-time operations
- Prefer clarity over cleverness
- Any new code you write also needs test coverage

### Run tests

After any changes: `direnv exec . mix test && direnv exec . mix check`

### Commit and push

If you made changes:
```bash
git add -A && git commit -m "{{ issue.identifier }}: simplify and address review feedback" && git push
```

### Close out the Linear issue

This is the last phase, so the comment you post now becomes the issue's latest comment — the first thing a human (or a future agent) reads to pick the work up. Leave the issue **continuation-ready**: no ambiguity about what happened, what's next, and where to look.

Post a wrap-up comment on the **Linear issue** (NOT GitHub) with exactly these three parts:

1. **Done** — what shipped, in one or two sentences, with the PR link. State CI status and whether review comments were addressed. If simplification changed nothing, say so in passing — don't make it the headline.
2. **Next** — what remains, and whose move it is. Your finish line above says who that is: under `Auto-Merge` the harness judges the hand-off and merges, and under `Auto-Build` or `Auto-Design` a person reviews and merges. List any follow-ups you deliberately left out of scope.
3. **Where to look** — the branch name, the 2-3 files at the heart of the change, and a pointer to the evidence comment (screenshots) above if one exists. Reference artifacts; do not restate their contents.

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: ${LINEAR_API_KEY_AUTOMATION:-$LINEAR_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"query": "mutation($id: String!, $body: String!) { commentCreate(input: { issueId: $id, body: $body }) { success } }", "variables": {"id": "{{ issue.id }}", "body": "YOUR_WRAPUP_HERE"}}'
```

### Done

You have completed the Simplify phase. Stop here.
