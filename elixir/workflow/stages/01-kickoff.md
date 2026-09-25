## Investigate

Do NOT write any code. This phase is research and planning only.

### Read the issue

1. Read the **full issue description** — every word, not just the title.
2. Read **every comment** on the issue, oldest to newest.
3. If the description references other issues, read their titles and descriptions to understand context. Do not deep-dive into linked issues — just get enough context to understand what this issue needs.

### Find the relevant code

Search for the specific code paths related to this issue. Be targeted:

1. Use **Grep** to find functions, modules, or components mentioned in the issue.
2. Read only the files that are directly relevant — not the entire module tree.
3. If the issue mentions a page or feature, find the entry point and trace one level deep. Do not explore the entire codebase.

Use the **Agent tool with `subagent_type: "Explore"`** for broader searches so your context stays clean.

### Post your implementation plan to Linear

First, check if a plan has already been posted by fetching the issue comments and looking for "## Requirements". If a plan already exists, skip this step — do NOT post a duplicate.

If no plan exists, post a comment on the Linear issue using curl. The plan must be specific enough that a **different agent** (who has not read the codebase) can implement it.

The comment must include:

1. **Requirements checklist** — every distinct requirement as a markdown checkbox list:
   ```
   ## Requirements
   - [ ] Requirement 1
   - [ ] Requirement 2
   ```

2. **Implementation plan** — for each requirement, list:
   - The exact file paths to change
   - What to add, modify, or remove — be specific (function names, line ranges)
   - Your approach and why

3. **Open questions and the defaults this run takes** — for each point the issue leaves open, the most reasonable reading and the default you build to. These are not blockers (see If You Get Stuck).

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: ${LINEAR_API_KEY_AUTOMATION:-$LINEAR_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"query": "mutation($id: String!, $body: String!) { commentCreate(input: { issueId: $id, body: $body }) { success } }", "variables": {"id": "{{ issue.id }}", "body": "YOUR_COMMENT_HERE"}}'
```

### Done

You have completed the Investigate phase. Stop here. Do not write any code.
