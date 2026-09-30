## Step 0: Setup and Route

Before doing anything:

1. Work in `{{ slot.directory }}`: start every command with `cd {{ slot.directory }} && `
2. Update main:
   ```bash
   git fetch origin main
   git checkout main
   git pull --ff-only origin main
   ```
3. Read the CLAUDE.md in the working directory for project conventions

### Check for existing work

4. Check for existing PRs for this issue — search by identifier, not current branch:
   ```bash
   gh pr list --search "{{ issue.identifier }}" --json number,url,state,headRefName --jq '.[]'
   ```
5. Check current git state — branch, uncommitted changes

**If an open PR exists for this issue:**
- Check out that PR's branch: `git checkout <branch-name>` (use the `headRefName` from the PR)
- Rebase onto latest main: `git rebase origin/main`
- Do NOT create a new branch or new PR
- Skip to the Implement phase

**If no PR exists:**
- Create a branch from main: `git checkout -b {{ issue.branch_name }}`
- Start from the Investigate phase
