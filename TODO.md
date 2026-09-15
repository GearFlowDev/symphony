# Symphony TODO

**Invariant (owner directive, 2026-08-04):** once an issue enters symphony, the
workflow must drive it unattended to a green, mergeable, non-draft PR with all
CI passing and the CodeRabbit review resolved/approved. Merge is the only human
step. Any place the pipeline can stall short of that line without a human being
*required* is a bug.

## Code/context-aware completeness review (done 2026-08-11); residual validation
The dominant defect was incomplete propagation of a change across the codebase —
a signature/field changes but some callers/writers are never updated (GEA-4849,
5744, 5518, 5007). The plan authored blind (issue prose, no repo), graded blind
(`git diff --stat` only), so callers in untouched files were invisible to every
gate; CodeRabbit (diff-only) can't see them either. Shipped three layers:
- **Layer 0 — change census.** `priv/scripts/change-census.sh`: for functions the
  branch changed, greps `lib/` for call sites the diff did NOT touch (call-syntax
  match, 1–25 external-ref window to cut noise), plus dead new modules and
  unpushed commits. `orchestrator.ex:fetch_dispatch_census/1` runs it in the slot
  and feeds it to the Grader (`grader.ex` census section + hard requirement 11),
  un-blinding the post-dispatch gate.
- **Layer 1 — plan/worker sweep.** Planner rule 10 (`planner.ex`): any changed
  backend contract OWNS its call sites — enumerate them or emit an "update all
  callers" row. `02-execution.md`: stop steering the worker to "stay within
  Touches files"; require a pre-push caller sweep.
- **Layer 2 — structural completeness sweep in Test** (`03-test.md` Step 4d): the
  tester (fresh, tool-enabled, whole-repo) statically greps callers/writers of
  changed contracts; a stale caller / un-updated writer / dead module forces
  REQUEST_CHANGES. Reuses the existing tester verdict — no new orchestrator state.
**Replay validation (done 2026-08-11) — the census is a narrow aid, NOT a
completeness net.** Replayed against the labeled defect set: it caught **0 of 4**.
Two are structural blind spots — an intra-file miss (GEA-4849, un-threaded arg in
an already-touched file) and the **missing-writer / bypassed-call class**
(GEA-5744, 5518) where the defective path never *names* the changed symbol, so no
grep of changed symbols can see it. That class is ~half the real defects and is
fundamentally **Layer 2's job** (the tester's LLM sweep reads the code and can
reason "this creation path should write jobs_locations but doesn't"). The census
is a *changed-caller* detector for signature-change fan-out — genuinely useful
when the change is that shape (3/8 of a regular PR sample gave clean on-target
output), useless-to-noisy otherwise. Grader requirement 11 already frames it as
advisory; keep it there, do not gate on it. Applied three grep fixes from the
validation: drop files that define their own `defp name(` (biggest noise cut),
drop `name(s)` plural-prose matches, and fix the dead-code check (lib/-only so
test-support modules don't false-flag; module-position short-name grep so a
genuinely-dead module isn't hidden by bare-word matches). Residual noise ceiling:
stdlib name collisions (`Date.add`) — needs alias resolution, not worth it.

**CodeRabbit-during-build (done 2026-08-11).** `orchestrator.ex
maybe_request_coderabbit_review/2` posts `@coderabbitai review` at `:needs_test`
(code complete, PR externally clean) so CR reviews in parallel with the tester,
once per PR head. Its feedback flows through the existing review_gate → Resolve
Review path. Behavior note: a CR request-changes at that point triages (and
undrafts) before the tester walk — defensible (all rows done + CI green), shifts
the In-Review transition slightly earlier.

Residual: Layer 2 (the tester's structural sweep in 03-test.md step 4d) now
carries the real completeness load for the missing-writer class, and it is
prompt-based and unvalidated. Worth a live check that a tester actually catches a
missing-writer case, since the census provably can't.

## PR discovery now reads Linear attachments (done 2026-08-04); residual gaps
Dispatch resolves the issue's PR as: evaluator-stored PR → Linear-attached PR
(oldest open; repo-agnostic) → branch-name search. This fixes both observed
failure classes (GEA-5377: newer sibling PR shadowed the work PR; GEA-5247: a
gf_platform PR was invisible under a `3.0` label). Still open against the
invariant above:
- ~~Slot/repo routing comes from product labels~~ (done 2026-08-04: the
  resolved PR's repo now drives SYMPHONY_REPO; labels are the fallback).
- ~~Parked issues strand draft PRs~~ (done 2026-08-04: on park, a green-CI PR
  is undrafted so human review can proceed).
- The grader clobbers plan-row states to `missing` when a worker refuses to
  work (no evidence ≠ no code); a refusal run should leave row states untouched.
- Grader tmux paste race: `:paste_not_visible` when the grading prompt lands
  while the pane's input box is busy (queued messages / mid-stream output) —
  the paste queues instead of submitting and the dispatch is left ungraded.
  Twice in two days (GEA-5247 2026-08-03, GEA-5429 2026-08-04). Recovers via
  retry, but each hit costs a full dispatch cycle. Fix idea: wait for an idle
  input box (no queued-messages banner) before pasting, or retry the paste
  once after a short delay.
  Status 2026-09-02: partial — an 8-attempt progressive backoff exists
  (`tmux_cli.ex` `@paste_attempts`, 3c7b3b4); no idle-input gate before pasting.
  Status 2026-09-09: done for the truncation form. Claude Code 2.1.265/266 (installed
  2026-09-08 evening) stopped putting the pane in bracketed-paste mode, so a plain
  `paste-buffer` arrived as a keystroke burst and the TUI kept only its tail: GEA-7669's
  three Implement workers each received the last ~390 chars of a 20 KB prompt, GEA-7671's
  and the graders' the last 133–621, and the old check passed because it accepted the
  suffix alone. Fix: `paste-buffer -p` (bracketed paste, verified intact for 69 KB), and
  `paste_landed?/2` now demands the "[Pasted text #N +L lines]" placeholder with L equal
  to the prompt's newline count, or both prefix and suffix, inside the "❯" input region.
  Still open: the idle-input gate for the queued-messages case.

## Evaluator attributes a PR by the slot's CURRENT branch, not the issue's branch
Seen on GEA-5188 (2026-08-28): dashboard showed the issue complete with PR
`#2403` linked, but #2403 is an unrelated *merged* PR for GEA-5405, and GEA-5188
has no PR at all — its work sits pushed on `gea-5188-…` (9 commits, complete,
self-APPROVED) with nothing opened. Root cause: `Evaluator.evaluate/2` resolves
the PR from `detect_current_branch(workspace)` → `check_pr(--head <current>)`.
Slots are released and reused, so at eval time the slot had been re-checked-out
to gea-5405; `check_pr` matched #2403 and stored it as GEA-5188's `eval_pr_url`.
`history.ex` `has_pr`/`latest_pr_url` then trust that stale value, so the
dashboard reports a green, PR-backed completion over work that never shipped —
the worst failure mode (looks done, isn't). Fix idea: pin evaluation to the
issue's Linear branch (`run_context[:branch_name]`), and only accept a
`check_pr` hit whose head branch equals that branch — never the slot's ambient
`detect_current_branch`, which is authoritative for nothing once slots churn.
Belt-and-suspenders: when `branch_pushed` is true but `pr_created` is false,
surface "pushed, NO PR" on the dashboard instead of borrowing any URL.

Related but distinct — a BLOCKED/needs-human plan reads as "done". GEA-5567
(2026-08-31): dashboard showed "Test ✓ complete (6t)" linking `#3170` (an
unrelated OPEN PR for GEA-8141), over a branch with ZERO commits. Here the empty
branch was CORRECT: the planner deliberately wrote no implementation rows because
the issue is labeled needs-human and its body reserves a product/security call
for a human (it reverses the 2-day-old GEA-5237 credential fence and offers four
mutually exclusive options, one with a hard dep on GEA-5466). Plan status stayed
`dispatching` with a "blocked pending that decision" note — but dispatch read
"no open rows" as "all rows done → tester → complete", and the run recorded
`outcome=completed, needs_human=0`. So a plan that is empty *because it is
blocked* is indistinguishable from a plan that is empty *because it is finished*.
Fixes: (1) a plan with zero implementation rows AND a needs-human/blocked note
must escalate (needs_human=true, outcome=blocked), never complete — same family
as the refusal-run row-state bug below; (2) never let `pr_created` be satisfied
by a borrowed URL whose head branch ≠ the issue's Linear branch (the #3170
mislink is the PR-attribution bug above).

## Grader re-derives row state from the diff and overrides human directives
A plan row the ticket owner explicitly cancelled ("remove the '+' menu unit
link and its shortcut") kept getting re-marked `missing` by the Grader because
the code (correctly) doesn't contain it — three Implement dispatches on
GEA-5378 (2026-08-03), two needs_human comments, until a manual plan edit set
the row `deferred`. There is no human-facing way to mark a row
deferred/cancelled; workers can only plead via needs_help. Fix ideas: honor a
`deferred`/`cancelled` marker the grader never overrides (deferred already
works this way — the gap is that nothing sets it); teach the planner/grader
that a ticket owner's later comment supersedes plan rows; or add a dashboard
control to defer a row.
Status 2026-09-02: partial — `deferred` is honored (`plan.ex`, `workflow.ex`) and
the grader cannot emit it (`grader.ex` `valid_row?`), but nothing sets it: no
dashboard control, no owner-comment path, no `cancelled` state. Also
`merge_grade_into_plan` still overwrites any row id present in the grade JSON.

## Dependency-blocked issues get re-dispatched until the breaker trips
When an issue's plan depends on another issue's unmerged branch, the worker
correctly reports needs_help ("all rows depend on GEA-XXXX, not merged"), but
the orchestrator has no notion of a dependency block: it just re-dispatches the
same Implement row-closer next poll, the agent re-derives the same conclusion
(6 turns, 0 files), the grader says blocked, and after 3 cycles the breaker
escalates — with two duplicate needs_human comments on Linear along the way.
Seen on GEA-5235 (2026-07-31, three runs in one hour): every row needs
`account_memberships` + `Scope.for_user_in_account/2` from GEA-5234, whose
PR #2378 exists but is conflicted/unmerged. Fix idea: when a worker's
needs_help message names a blocking issue, park the issue (sticky blocked set)
until that issue's PR merges — or at least until the human retries — instead of
burning breaker cycles re-proving the same block.

## API 529/overload turns count as "no progress" and burn the breaker
When the Anthropic API browns out, each agent turn returns instantly with
"API Error: 529 Overloaded" — no tool calls, no work. The orchestrator counts
these as completed turns with `files_changed: 0`, so the no-progress watchdog
kills the run at 6 turns, the grader sees an unchanged tree and requests
changes, and after 3 identical cycles the breaker escalates to needs_human.
Seen on GEA-5243 (2026-07-29 15:00–16:02): one run's six turns were *all*
529s with zero tool calls; the issue got parked overnight for a pure
server-side brownout. Fix idea: detect API-error turns (the turn's assistant
output is only an error message / has zero tool calls and an error marker)
and treat them as transient — back off with the existing retry ladder without
incrementing no_progress_count or the cycle fingerprint.

## Resolve Conflicts loses its work on every re-dispatch, so transient flakiness parks the PR forever
A conflicted post-approval PR gets a Resolve Conflicts dispatch (rows stay done,
worker only rebases/resolves/pushes). The fingerprint that arms the breaker is
`rows | verdict | head` — for this phase only a **new PR head** counts as
progress, which is correct *if the worker pushes*. But the worker's resolution
lives only in the slot's working tree, and `slot-claim.sh` resets the slot to
`origin/$BRANCH` on every claim — so any dispatch that resolves the conflict but
fails to `git push` before it ends leaves **zero** durable progress, and the
next dispatch starts from scratch. Three such dispatches → identical fingerprint
→ breaker parks it needs_human. And a park never self-clears: the sticky
`blocked` MapSet only empties on a process restart or a manual force-dispatch, so
an issue parked for a purely transient reason stays dead until a human acts —
the exact invariant violation ("an agent MUST drive to a green mergeable PR").
Seen on GEA-5582 (PR #2517, 2026-08-08 → parked): the worker rebased and
resolved the single-file `accounts_live/show.ex` conflict correctly, then hit
"API Error: Connection closed mid-response" and had its wait-for-tests `sleep`
blocked by the harness, so it never reached `git push`; all three attempts died
the same way, ~2.5 hrs each. Unstuck 2026-08-10 by manual force-dispatch.
Fix ideas: (a) treat API-error / harness-blocked turns as transient (same as the
529 entry above) so they don't count toward the breaker; (b) don't let
slot-claim wipe a branch that has unpushed local commits ahead of its remote —
or have Resolve Conflicts push incrementally after `rebase --continue`; (c) give
needs_human a self-heal path — a parked issue whose block was a transient/infra
error should get one automatic retry after a cooldown instead of waiting on a
human. Also: the Resolve Conflicts stage tells the worker to `mix test` then
push; a worker that can't wait on background tests (harness blocks bare `sleep`)
should be told to run tests in the foreground.

## No-progress watchdog kills tester runs by design (testers never change files)
The per-turn progress check counts `files_changed`/`new_commits`, but Test
tester runs never produce either — they verify and post a verdict. Any tester
run that needs more than ~6 turns gets "No progress for 3 consecutive turns,
stopping early" before it can record its SYMPHONY_VERDICT. Seen on
GEA-5113/GEA-5115 (2026-07-28): re-dispatched testers were killed at turn 6
with no verdict, so the tester gate never got fresh evidence and the cycle
breaker escalated to needs_human. (The staleness half of that loop — a no-op
Fix CI dispatch invalidating an APPROVE at the same head SHA — is fixed:
`tester_gate` is now SHA-aware via `verdict_at_head?`.) Fix idea: for
Test-phase dispatches, count a recorded verdict or Linear report as progress,
or exempt the phase from the files/commits heuristic.

## Slot claim should prune stale git worktrees left by agents
An agent working GEA-4629 created a throwaway worktree
(`git worktree add /private/tmp/main-check main`) from slot1 and never removed
it. With `main` checked out there, every later claim of slot1 died at
`before_run` with `fatal: 'main' is already used by worktree ...` (exit 128) —
killed GEA-5000, GEA-4618, and GEA-4629's own retries across 2026-07-20/21
until the worktree was removed by hand. The claim script already does
`git reset`/`git clean` between runs; it should also
`git worktree list --porcelain` and `git worktree remove --force` any linked
worktree (then `git worktree prune`) so one agent's leftovers can't poison the
slot. Second incident of stale slot state breaking claims; same family as the
quarantined-slot boot crash below.

## Trust dialog default flipped to "No, exit" (fixed 2026-09-09)
Claude Code 2.1.26x lists "No, exit" first and preselected in the "Do you trust this
folder?" dialog. `wait_for_ready` answered it with a bare Enter (assuming "1. Yes" was
selected), which exits the CLI and leaves a zsh prompt in the pane — the next paste then
runs the prompt's lines as shell commands (reproduced in a lab session: `cd: too many
arguments` from a pasted line). Fixed: `answer_trust_dialog/1` reads which option the
`❯` cursor is on (`trust_cursor/1`), presses Down until it is on "Yes", then Enter.
Symphony workspaces are usually already trusted, which is why this stayed latent.

## ready_timeout kills the pane without capturing it (evidence destroyed)
`TmuxCLI.wait_for_ready` gives up after 30s and `kill_session`s the pane
without logging what was on screen, so every `{:start_session_failed,
:ready_timeout}` destroys its own diagnosis. Cost us ~1 day of dead dispatches
(2026-07-19/20): oh-my-zsh's update `[Y/n]` prompt was swallowing the typed
`unset CLAUDECODE && claude ...` line (`zsh: command not found: nset`), and the
log showed only ready_timeout. Root cause was machine config (the
`zstyle ':omz:update' mode reminder` line sat AFTER `source oh-my-zsh.sh` in
~/.zsh_settings, so it never applied — fixed 2026-07-20), but two hardenings
belong here:
- On ready_timeout, `capture-pane -p` and log the last screen before killing.
- Launch `claude` as the tmux session command (`new-session ... <cmd>`) instead
  of typing into an interactive shell, so shell-init prompts can't eat it.

## Stall watchdog counts before_run provisioning as agent inactivity
The orchestrator's stall reconciler (`reconcile_stalled_running_issues`) starts
its clock at dispatch and reads `codex.stall_timeout_ms` (300s default)
regardless of agent backend — `claude.stall_timeout_ms` never reaches it. A
`before_run` hook that legitimately provisions for >300s (recompile after main
moves) got stall-killed mid-wait with `session_id=n/a`, and the kill tore down
the devenv the hook's health gate was waiting on, so every retry failed the
same way (observed 2026-07-14, ~3h of looped dispatches on GEA-4619/4625).

Real fix, either/both: (a) start the stall clock only once the agent session
exists; (b) map the active backend's `stall_timeout_ms` onto the watchdog.
Mitigation in place: `codex.stall_timeout_ms: 1800000` in WORKFLOW*.md — must
stay >= hooks.timeout_ms until fixed.
Status 2026-09-02: partial (config-only) — code still reads
`codex_stall_timeout_ms` for every backend, starts the clock at `started_at`, and
the phase timer below is still `timeout_ms * 2` with no recent-activity guard.

Related: the phase-stuck timer (hardcoded `timeout_ms * 2`) killed an ACTIVELY
WORKING agent 31 min into its Test phase (GEA-4621, 2026-07-14 16:35 — pane
showed live token flow). A long test suite naturally holds one phase for
30-60 min. The phase timer should not fire while the session shows recent
activity; long-but-active phases are normal, not stuck.

## One dead slot at the head of the free list starves every dispatch (GEA-7671, 2026-09-15)
`slot-claim-registry.sh` claims the first free slot in numeric order and, when that
slot's backend never answers, exits 75 after 4 recycles and 450s. The orchestrator
retries 45s later and claims the same slot again. Observed 2026-09-15 08:23–09:40 CT:
seven Resolve Conflicts dispatches for GEA-7671, each ~8.5 min, zero worker turns, while
slots 11 and 14 sat free and healthy. The dead slot was slot10, the only procurement slot
whose untracked `.envrc` lacked the `MIX_ARCHIVES` mitigation (see the ETS badarg entry
below); every boot crashed the same way. Fixed on this machine by adding the line and
`direnv allow`. Symphony-side fixes still open:
- On boot failure, release the slot and continue to the next free slot inside the same
  claim instead of exiting 75.
- Detect the `Mix.State` ETS crash in the fresh `processes.log` and fail that slot fast
  (it never recovers by recycling).
- Slot provisioning must write the `MIX_ARCHIVES` export, or `devenv.nix` in
  gf_procurement must carry it, so a new slot cannot miss it.

## A transient Linear error during a retry poll drops the issue for good (2026-09-15)
`dispatch_issue/…` handles `{:error, reason}` from the retry-time issue refresh by
logging "Skipping dispatch; issue refresh failed" and returning state — no re-schedule.
Observed 2026-09-15 09:40 CT: Linear answered RATELIMITED (2500 req/h exhausted) on
GEA-7671's retry poll; the issue left the retry queue and nothing brought it back. It is
`In Review`, so the regular poll never lists it (`active_states` is Shaped/Todo/In
Progress), and `check_completed_pr_health` had lost it too (next entry). It vanished
from the dashboard until a manual force dispatch at 10:18. Fix: on a refresh error keep
the issue in the retry queue with backoff (treat like `no_capacity`), and honour the
rate-limit reset instead of hammering.

## Force dispatch wipes run history, so the PR-health check forgets the PR
`do_force_dispatch/2` calls `History.delete_all_runs/1` and drops the issue from the
`completed` set. After that, `check_completed_pr_health` has no `pr_url` for the issue,
so a conflicted PR is only re-detected while the retry chain is alive. Combined with the
entry above, one Linear hiccup after a force dispatch parks the issue silently. Fix:
keep the PR url (Linear attachment lookup) in the completed history, or do not delete
rows that carry `eval_pr_url`.

## Slot backends intermittently die at boot inside `Mix.start/0` (ETS badarg)
`devenv up` backend sometimes crashes before any app code loads:
`(MatchError) ... {Mix, :start, ...} {:EXIT, {:badarg, [{:ets, :lookup, [Mix.State, :shell] ...`
via `Mix.Local.check_elixir_version_in_ebin` → `append_archives` (mix 1.18.4,
nix store Elixir). Interactive `direnv exec . mix test`/`mix phx.server` in the
same directory works; only the process-compose-supervised boot path fails, and
intermittently — a plain retry of `devenv up` usually boots clean. When it
fails, process-compose does NOT restart the backend task, so the slot stays
dead until the next claim.

Observed 2026-07-09/10 repeatedly (slots 4 and 6; blocked the GEA-4477/4478/4479
testers), then 2026-07-13 as an every-boot failure on slot 4 (5+ consecutive,
even `mix deps.get` in the claim hook) while interactive runs kept passing.

Narrowed 2026-07-13: the crash site is `Mix.Local.check_elixir_version_in_ebin`,
which only calls `Mix.shell()` (→ the missing `Mix.State` ETS table) on the
archive version-WARNING branch — so the crash requires (a) an archive present in
`MIX_ARCHIVES` and (b) that warning path racing Mix.State inside the `:mix`
application start callback. The shared `~/.mix/archives/hex-2.2.2-otp-27`
requires `~> 1.6` (matches 1.18.4), so why the warning branch fires under
process-compose/hook boots but not interactively is still not proven.

Mitigations in place:
- Claim script detects the dead backend task in the fresh portion of
  `.devenv/processes.log` and recycles devenv (2 attempts) inside its wait loop;
  on exhaustion it releases the claim and exits 75 (backoff) instead of handing
  a worker a dead slot.
- Slot release leaves the backend RUNNING, so claims hit the healthy fast path
  and boots become rare.
- 2026-07-13: all procurement slots' untracked `.envrc` now export
  `MIX_ARCHIVES=$PWD/.devenv/state/empty-archives` (empty dir) — with no
  archives to iterate, `append_archives` never reaches the fragile warning
  path at all. If the crash stops recurring, this is the keeper; consider
  promoting it into `devenv.nix` in gf_procurement.
Status 2026-09-02: partial — recycle + exit 75 present (`slot-claim-registry.sh`,
`BOOT_RETRIES=4`); release leaves the backend running; `MIX_ARCHIVES` still lives
only in untracked per-slot `.envrc` files, not promoted to `devenv.nix`.

## `:paste_not_visible` crash storm pinned one issue's dispatches for hours
Observed 2026-07-09, 19:19–20:53Z: every GEA-4394 Test dispatch (25+ in a row) crashed
with `:paste_not_visible` from `TmuxCLI.paste_until_visible/4` (~3.5 min per attempt,
mostly hook time), while other issues' dispatches pasted fine in the same window. An
orchestrator restart cleared it — the next GEA-4394 dispatch pasted and ran normally.
Root cause not caught live (the failing sessions are killed on error, so the pane was
never inspected). Impact compounds: each failed dispatch still ran `enforce_pr_draft`,
flapping the PR's draft state, and burned a slot claim/release cycle.

Next time it fires: capture the worker pane BEFORE the runner kills the session
(e.g. on paste failure, `tmux capture-pane -p` into the run's log/DB row), so the
failure is diagnosable post-mortem. That capture hook is the fix to build first.
Status 2026-09-02: partial — `tmux_cli.ex` captures the pane tail and logs it
before returning `:paste_not_visible`; it is not yet written to the run's DB row.
Status 2026-09-09: the 2026-09-09 truncation (see "Grader tmux paste race" above) is the
inverse failure — the check passed on a partial paste — and is fixed by bracketed paste
plus a whole-prompt landing check. Pane capture into the DB row remains open.

## Stale `.symphony_slot` makes a retry adopt a slot dir as its workspace → double-booked slots, destroyed work
`Workspace.create_for_issue` ends with `resolve_slot_workspace/1`: if the issue's
symphony workspace still holds a `.symphony_slot` from a *previous* run, the retry's
"workspace" becomes that old slot directory — before any claim happens. The before_run
hook then runs with `WORKSPACE=<slot dir>`: its re-entry check fails (the old lease is
gone or mismatched), so it claims the next *free* lease (a different slot number) and
writes a contract into the current slot dir naming the other slot. From there:

- The agent works in slot X's directory while holding slot Y's lease, so slot X's lease
  looks free and another issue claims it legitimately → two agents in one working tree.
- The winner's provisioning `git reset --hard` destroys the loser's uncommitted work.
- Release hooks follow the corrupted contract and delete the *other* issue's lease,
  spreading the mismatch to more slots on each cycle.

Observed 2026-07-08: GEA-3370's 10:24 retry dispatched with
`workspace=gf_procurement-slot6` (log line 20319, symphony.log.3), claimed slot4's lease
with `"workspace": ...slot6`, and worked in slot6 — which GEA-4394 then claimed
legitimately at 10:38. At 10:46 the GEA-3370 chain reset slot6 to main, destroying
GEA-4394's uncommitted work (nothing pushed; no `gea-4394` branch on origin), and its
release deleted GEA-4394's slot6 lease. GEA-4394 escalated needs_human at 10:53. By
11:00 the contracts were fully crossed (slot4-dir says slot5, slot5-dir says slot4 with a
GEA-4137 branch, slot6-dir says slot4) and new dispatches (GEA-4395/2791/3245) were
churning open run rows.

Fix directions:
- Never resolve a slot at *create* time from a leftover contract. Either always pass the
  symphony workspace to before_run (the claim script's re-entry branch already handles
  legitimate re-claims), or validate before adopting: the lease named in `.symphony_slot`
  must exist, be symphony-owned, and name this issue + workspace; otherwise delete the
  stale contract and start clean.
- Delete the workspace's `.symphony_slot` whenever its lease is released (after_run,
  before_remove, stale sweep).
- Claim-script guard: refuse to run with `$WORKSPACE` inside `local-dev/` slot dirs.
Status 2026-09-02: partial — first two done (`workspace.ex` always returns the
symphony workspace; `slot-release-registry.sh` removes `.symphony_slot`); the
claim-script guard is still missing.

## needs_human_message truncated at 500 chars
The escalation message is cut mid-sentence at exactly 500 chars — in the DB column and
in the Linear comment, so the human-facing ask can lose its options. Observed 2026-07-02
(GEA-4259: option "(b)" lost) and 2026-07-08 (GEA-4394: slot-conflict detail lost).
Fix: raise/remove the cap where the message is captured; the column is TEXT.

## `mix test` reaps live tmux sessions and slot leases
Tests boot the app supervision tree, and the startup reapers run against shared system
state — real tmux sessions and real `local-dev/registry/` slot leases — even in
`MIX_ENV=test`. The DB is isolated (`symphony_test.db`); tmux and the registry are not.

Observed 2026-07-02: a `mix test` run reaped the live GEA-4226 Resolve Review worker's
Claude tmux session (and slot4's lease); the worker then hit the 10-minute stall timeout
and had to be re-dispatched. Every `mix test` on a machine with a running orchestrator
risks killing in-flight work.

Fix: skip tmux-session and slot-lease reaping (any shared-state mutation at startup)
when `Mix.env() == :test`.
Status 2026-09-09: done — `config :symphony_elixir, reap_orphans: false` under `:test`
(`config/config.exs`); `Application.start/1` skips the startup tmux reaper and
`Orchestrator.maybe_dispatch/1` skips both per-poll reapers when the flag is false.
Verified: `mix test test/symphony_elixir/claude/tmux_cli_test.exs` ran beside a live
worker (session 7d33bb2a) and left it untouched.

## Resolve Review workers get stall-killed while waiting on CodeRabbit
Resolve Review workers finish the triage (push fixes, reply to every thread), then sit
silent waiting for CodeRabbit's re-review. That quiet wait exceeds the 10-minute stall
timeout, so the orchestrator kills a worker doing exactly what it should.

Observed 2026-07-02 (GEA-4226 / gf_procurement PR #1768): worker pushed the fix and
replied to all 4 threads, was stall-terminated 2 minutes later while waiting; the next
dispatch found everything done and closed in 5 minutes. Cost: one wasted dispatch per
review round + misleading `stall` failures in the runs table.

Fix: emit a heartbeat (log line / explicit poll loop) while waiting on CodeRabbit, or a
per-phase stall timeout with a longer window for Resolve Review.
Status 2026-09-02: partial (config-only) — global stall timeout raised to 30 min;
no heartbeat, no per-phase window.

## slot-claim hangs on a dead-but-listening backend squatting the slot's Phoenix port
An orphaned backend beam from a previous run can keep listening on the slot's Phoenix
port while returning HTTP 500 (its worktree was git-reset under it). The new `devenv up`
backend can't bind the port, the health-check loop polls the broken zombie for 180s, and
the hook dies at the 300s `before_run` timeout — on every retry, until the issue burns
its failure budget and stops.

Observed 2026-07-02 (GEA-4259 / slot4): a day-old orphaned beam held port 3024 answering
500; four dispatches failed with `{:workspace_hook_timeout, "before_run", 300000}` until
the zombie was killed by hand — the next attempt succeeded immediately. Contributing:
`devenv processes down` can't stop prior runs' supervisors (unique socket path per
`devenv up`), so orphaned process-compose instances accumulate.

Fix: in slot-claim, if the slot's Phoenix port is LISTENING but the health check returns
non-200, kill the listener (ephemeral slots — it can only be a leftover) or fail fast
with a clear error. Consider sweeping orphaned process-compose supervisors whose lease is
gone. Related: the `runs` table holds ~44 `finished_at IS NULL` rows from crashed or
restarted runs — a startup sweep closing rows for runs that aren't alive would stop
"active runs" queries from lying.
Status 2026-09-02: mostly done — `slot-claim-registry.sh` treats 000/5xx as
unhealthy, `kill_slot_orphans` kills `process-compose|beam.smp` whose cwd is the
slot, and the health gate backs off instead of hanging; the legacy `slot-claim.sh`
still only warns. Startup sweep done: `History.close_orphaned_runs/0`.

## Post-ship review gate (done; verified 2026-09-02)
After a worker ships a PR, the orchestrator should poll CI and review status before marking the issue done. Currently the judge sees `pr_created: true` and moves on immediately — there's no time for CI to run or reviewers (CodeRabbit, humans) to post comments.

Needed:
- After Ship phase completes, enter a review-gate hold (e.g. 5 min)
- Poll CI status every ~60s until it resolves (passed/failed)
- Poll for new review comments (CodeRabbit takes 2-5 min)
- If CI fails or actionable review comments appear, retask the agent to fix
- Only mark done when CI passes and no unaddressed comments (or timeout)

Done: `external_ship_gate/1` (`orchestrator.ex`) chains `merge_gate` → `ci_gate`
(`gh pr checks`) → `review_gate` before `:done`, retasking to Resolve Conflicts /
Fix CI / Resolve Review; CodeRabbit is requested at `:needs_test` (see
CodeRabbit-during-build above).

## Surface blocked issues on the dashboard
Issues that hit `max_runs_per_issue` silently disappear from the dashboard — the orchestrator logs a warning but the user sees nothing. These issues still need work but something went wrong (infrastructure failures, stale locks, etc).

Needed:
- A "Blocked" section on the dashboard showing issues that hit max retries
- Show the reason (last error, run count, last outcome)
- A "Reset & Retry" button that clears the failed run history and re-dispatches
- This is the primary intervention point for users — they need to see it

Root causes to also fix:
- Failed slot claims (0-turn runs) count toward max_runs — they shouldn't
- Stale slot locks from crashed/killed runs are never cleaned up
- Consider a TTL on locks, a startup sweep, or orchestrator-level lock release on hook failure

Status 2026-09-02: partial — root causes done (`no_capacity` runs excluded from the
breaker, 7b84202; stale-lock sweep in `workspace.ex` + `STALE_LOCK_MAX_AGE_SECONDS`);
the free-text force-dispatch form clears the sticky blocked set (203ca9b). Still no
Blocked section or per-issue Reset & Retry.

## Detect issue description changes while agent is working
The orchestrator fetches the issue once at dispatch and never re-reads the description. If the user updates the issue (adds details, clarifies requirements, attaches screenshots) while the agent is working, the agent never sees the changes.

The agent runner already re-fetches issue *state* between turns (`continue_with_issue?`) and fetches new *comments* (`fetch_new_comments`). It should also detect description changes:

- Between turns, re-fetch the full issue (description included)
- Diff the description against what was originally dispatched
- If changed, inject a "The issue description was updated" notice into the continuation prompt with the new/changed content
- This lets users steer the agent mid-run by editing the issue

The `@agent` prefix convention for comments works for ad-hoc instructions. Description changes are for updating the source of truth.

## Evaluate test coverage quality, not just existence
The evaluator currently checks `tests_written: bool` — did any test file change. This doesn't catch agents that write one token test for a multi-file change. The judge should evaluate coverage adequacy:

- Compare test file count vs source file count (ratio)
- Check test line count relative to implementation line count
- Use the PR diff to identify untested code paths (functions added without corresponding test cases)
- Feed this back to the retask prompt: "You changed 5 source files but only wrote 1 test file. Add tests for X, Y, Z."

This would catch the GEA-2463 case where the agent wrote one test file for a large feature.

Status 2026-09-02: partial — evaluator still a bool; the LLM grader marks a row
`partial` when its diff has no test (`grader.ex`), which drives the retask.

## Judge should detect unanswered help requests on Linear
When an agent posts a question or asks for help on the Linear issue, the judge should not dispatch the next phase until a human responds. Currently the orchestrator detects `SYMPHONY_NEEDS_HELP` in the output stream, but if the agent posts a question as a regular Linear comment, the judge ignores it and moves on.

Needed:
- After each phase, check Linear comments for unanswered agent questions (e.g. comments ending with `?` from the automation user with no subsequent human reply)
- If found, hold dispatch and surface on the dashboard as "Waiting for human input"
- Resume when a human replies (detected on next poll)
- The dashboard should show these prominently — this is another intervention point

## Investigate Share Evidence phase crashes (exit 143 SIGTERM / exit 1)
The Share Evidence phase consistently crashes with subprocess_exit:1 (context overflow) or subprocess_exit:143 (SIGTERM). Blocking Playwright MCP via --strict-mcp-config helped reduce context usage from 1M to 30-44K but agents still crash with SIGTERM.

Possible causes:
- The `before_run` hook runs the full slot claim script on every retry, which does `git reset`, `mix deps.get`, and `devenv-start.sh` — this may interfere with a running Claude process
- Two agents dispatched simultaneously may have their hooks interfere with each other
- The `safe_port_close` function sends `kill -- -$PID` (SIGTERM to process group) which may be triggered prematurely
- The orchestrator may not cleanly terminate previous runs before dispatching retries

Status 2026-09-02: partial — `--strict-mcp-config` in place; the turn loop runs
through tmux so `safe_port_close` no longer reaches workers; the registry claim
script skips heavy setup when the slot is healthy. SIGTERM root cause still unknown.

## Completed Work view needs actionable detail
The Completed Work section on the dashboard shows badges but no useful information about what happened. When an agent fails, the operator needs to understand:

- What did the agent actually do? (files read, files changed, commands run)
- Where did it fail? (which tool call, what error)
- What was the last thing it tried to do?
- Did it make any progress? (commits, Linear comments posted)
- Was it a context issue, an API error, a code error, or a stuck loop?

The error column currently shows a truncated RuntimeError which is useless. Consider:
- An expandable detail panel per completed entry (like the timeline on running entries)
- A summary line: "Read 12 files, edited 3, ran mix test, failed on context overflow"
- Link to the session log if available
- Show the last tool call and its result

Status 2026-09-02: partial — rows show outcome, phases, PR, error, last activity,
turns, tokens; no expandable panel, summary line, or session-log link.

## Interactive agent takeover
Investigate whether a running agent session can be converted to interactive mode so the user can communicate with the agent and direct its activities. Currently agents run autonomously — the user can only watch. If the user sees an agent going off-track or wants to steer it, there's no way to intervene without killing the session and starting over.

Questions to answer:
- Can the Claude CLI accept user input mid-session while an agent is running?
- Could we inject messages into the conversation via the API (Anthropic or Claude Code)?
- Would a tmux-based approach work — attach to the session and type directly?
- What happens to the orchestrator's tracking if the user sends messages the orchestrator didn't initiate?
- Should this be a "pause and hand off" model (orchestrator stops, user takes over) or a "co-pilot" model (orchestrator and user both send messages)?

Status 2026-09-02: partial — `@agent` comment injection only (`linear/client.ex`,
`agent_runner.ex`, `fresh_agent_feedback/2`); no attach/steer.

## Show issue title on dashboard
The dashboard only shows issue identifiers (e.g. GEA-2631). Show the issue title alongside it so the operator can tell at a glance what each agent is working on without clicking through to Linear.

Status 2026-09-02: partial — title renders only in the Run history tab.

## Dashboard polling overhead
When the dashboard LiveView is open, it polls `run_events` every second per expanded timeline. This hammers the SQLite DB with redundant queries. Should debounce or only poll when timeline is expanded.

Status 2026-09-02: partial — already gated on expansion and the payload reload is
debounced 250 ms, but `render_timeline/2` still re-queries `events_for_run` on
every 1 s tick per expanded row.

## Orchestrator snapshot timeouts ("Snapshot unavailable") (done: interim fix)
The dashboard and TUI fetch status via `Orchestrator.snapshot()` → `GenServer.call(:snapshot, 15_000)`. The `:snapshot` handler is trivial (it just reads state), but the orchestrator is a single GenServer that runs its **entire poll cycle in-process**: Linear HTTP (`Tracker.fetch_candidate_issues` / `fetch_issue_states`), plan generation (`Planning.Workflow.assess` — one LLM call), and dispatch grading (`maybe_grade_plan_dispatch` — another LLM call). A GenServer handles one message at a time, so while a poll cycle is blocked on a slow LLM grade/plan (routinely >15s, worse under churn), the `:snapshot` call sits in the mailbox until it times out → `snapshot_payload` returns `:error` → "Snapshot unavailable / Snapshot timed out". Intermittent — only fires when a refresh lands during a slow cycle.

Fix:
- Proper: move the blocking poll-cycle work (LLM grade/plan, Linear calls, worker dispatch) into supervised `Task`s so the GenServer stays responsive to `:snapshot` and the other status/control calls.
- Cheap interim: raise the snapshot timeout above the worst-case grade time, and/or render the **last-known** snapshot on timeout (the dashboard already tracks `last_snapshot_fingerprint`) instead of erroring — shows slightly-stale status rather than "unavailable".

Done (046d226): the interim fix — ETS snapshot cache; `snapshot/2` returns the
last-known snapshot tagged `stale_age_ms` on timeout. The Task refactor is deferred.

## Add OpenCode as an alternative agent backend
Symphony's agent layer is already abstracted behind `Config.agent_runner_module()` (claude → `Claude.AgentRunner`, default → legacy Codex runner). Adding sst/opencode as a third backend is mostly mirroring the Claude modules.

Why bother:
- Lets users run Symphony against models other than Anthropic's (opencode supports Anthropic, OpenAI, OpenRouter, Ollama, etc. via provider/model)
- Removes vendor lock-in for the harness
- opencode is open-source and self-hostable

What's needed:
- `lib/symphony_elixir/opencode/cli.ex` — port spawn, PTY wrapper, NDJSON line streaming. `claude/cli.ex` is the template; flag mapping below.
- `lib/symphony_elixir/opencode/stream_parser.ex` — map opencode events (`tool_use`, `step_start`, `step_finish`, `text`, `reasoning`, `error`) to Symphony's internal event shape (`:session_started`, `:assistant`, `:tool_use`, `:tool_result`, `:result`). `sessionID` is on every line so session-id extraction is simpler than Claude's.
- `lib/symphony_elixir/opencode/agent_runner.ex` — turn loop. Almost a copy of `claude/agent_runner.ex` with the CLI alias swapped.
- Config keys in `config.ex`: `opencode_command`, `opencode_model`, `opencode_turn_timeout_ms`, `opencode_stall_timeout_ms`, `opencode_dangerously_skip_permissions?`. Add an `"opencode" -> SymphonyElixir.OpenCode.AgentRunner` branch in `agent_runner_module/0`.
- WORKFLOW.md: optional `agent.backend: opencode` and `opencode:` block.

Flag mapping (Claude → opencode):
- `claude -p <prompt>` → `opencode run <prompt>`
- `--output-format stream-json` → `--format json`
- `--resume <id>` → `--session <id>`
- `--dangerously-skip-permissions` → same flag, same semantics

Real friction points to handle:
- **Tool restriction is not a CLI flag.** Claude takes `--tools Agent,Bash,Edit,...` per invocation. opencode bakes permissions into named agents (`opencode agent create --permissions bash,read,edit,...`). Setup story: provision a `symphony-worker` agent during slot setup, pass `--agent symphony-worker` per run. This means slot-claim.sh (or first-time setup) needs to create the agent. No equivalent to `--tools ""` for "no tools" — must enumerate.
- **MCP isolation is config-file driven, not per-invocation.** Claude's `--strict-mcp-config --mcp-config '{}'` makes MCP servers vanish for the run. opencode honors whatever's in `~/.config/opencode/`. To match Symphony's current isolation, run opencode with a sandboxed config dir (e.g. `OPENCODE_CONFIG_DIR=/tmp/symphony-opencode-empty`) so user-level MCP servers don't bleed in. Verify the env var is honored before relying on it.
- **Token usage is not in the JSON stream.** Claude emits `usage: { input_tokens, output_tokens, cache_creation_input_tokens, cache_read_input_tokens }` on the `result` event. opencode's `run.ts` JSON emitter (sst/opencode v1.14) only writes `tool_use` / `step_start` / `step_finish` / `text` / `reasoning` / `error` — no usage. Symphony's per-run token accounting and the `codex_totals` rollup will go to zero for opencode runs unless we query the session via opencode's HTTP server (`opencode serve` + `/session/:id`) after the run completes. This is the biggest delta — all the others are flag/string remaps.
- **Phase inference table.** `StreamParser.infer_phase_from_tools` maps Claude's PascalCase tool names (`Read`, `Edit`, `Bash`) to phases. opencode uses lowercase (`read`, `edit`, `bash`). One-line change per mapping.

Estimate: ~500–700 lines of new code, no orchestrator changes, side-by-side via config. Half a day to wire and smoke-test against a low-stakes issue. Another half-day to add HTTP-based token accounting and verify MCP isolation.

References:
- sst/opencode run.ts: https://github.com/sst/opencode/blob/main/packages/opencode/src/cli/cmd/run.ts
- CLI docs: https://opencode.ai/docs/cli/
- Headless --resume status (closed, implemented): https://github.com/sst/opencode/issues/2404
- Stream JSON output (closed, implemented): https://github.com/sst/opencode/issues/2449
