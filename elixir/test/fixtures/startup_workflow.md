---
tracker:
  kind: memory
  active_states:
    - Todo
    - In Progress
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done

agent:
  backend: codex

codex:
  command: codex app-server
---

Test workflow. The application boots against this file under `:test` so startup
validation has something valid to validate; every test that cares writes its own
`WORKFLOW.md` and points `Workflow.set_workflow_file_path/1` at it.
