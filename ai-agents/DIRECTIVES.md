# AI Agent Directives

This file is the reusable operating guide for future chat instances working in
this repository:

```text
/media/guilhermes/ssd/EAIE/bianbu-bananapi-bpi-f3-custom
```

When the user says to start a chat migration routine, follow the migration
routine below.

## Baseline Operating Rules

- Work only on the Banana Pi / Bianbu / EAIE custom-board project unless the
  user explicitly changes scope.
- Read [../README.md](../README.md) and
  [AGENT-HANDOFF-HELPER.md](AGENT-HANDOFF-HELPER.md) before making technical
  assumptions.
- Always refer to
  `/media/guilhermes/ssd/EAIE/bianbu-bananapi-bpi-f3-custom/COMMIT-SCOPE.md`
  before creating or suggesting commits.
- Do not commit automatically. Generate commit commands for user review.
- Do not run build, flash, SSH deploy, or live board deployment commands unless
  the user explicitly asks you to run them.
- Prefer generating commands for the user to run manually for long-running
  kernel, image, flash, and board-deploy operations.
- If SSH is needed, ask for the current board IP first. DHCP lease time is
  short, and prior board IPs are not reliable.
- Use `bash script.sh ...` or `/bin/bash script.sh ...` for repo scripts. The
  user's interactive shell is usually `zsh`, and some repo scripts may not be
  executable.
- Do not silently patch risky build, kernel, flashing, or deployment behavior.
  Explain the reasoning first when the change could affect reproducibility or
  board recovery.
- Do not revert unrelated dirty files or generated artifacts unless the user
  explicitly asks.

## Chat Migration Routine

When the user asks to migrate or refresh the chat context:

1. Inspect the worktree first:

   ```bash
   git status --short --untracked-files=all
   ```

2. Report all uncommitted, deleted, modified, and untracked files before making
   changes.

3. Ask whether the user wants to proceed if there are uncommitted or untracked
   changes. Do not modify files until the user confirms.

4. After confirmation, summarize the latest changes made since the current
   agent/chat instance assumed the workspace. Be explicit about:
   - code/build/kernel/rootfs changes
   - documentation changes
   - board validation results
   - open risks and unfinished tasks
   - commands that were only proposed versus commands actually run

5. Update [../README.md](../README.md) with durable project-level information
   that a developer should know beyond the current chat.

6. Update [AGENT-HANDOFF-HELPER.md](AGENT-HANDOFF-HELPER.md) with current
   session state for the next agent. Include:
   - actual current dirty worktree state
   - recent commits
   - current validated hardware/software state
   - current next task or investigation direction
   - known pitfalls
   - manual commands the user may want to run

7. Update this file if the migration process itself changes.

8. Review the resulting diff and final worktree state.

9. Do not commit. Provide suggested commit commands/messages only after the
   user asks, and ensure those messages follow `COMMIT-SCOPE.md`.

## Commit Message Rules

The source of truth is:

```text
/media/guilhermes/ssd/EAIE/bianbu-bananapi-bpi-f3-custom/COMMIT-SCOPE.md
```

Current listed commit types:

```text
feat
fix
refactor
```

Current listed scopes:

```text
build-system
kernel
uboot
ai-apps
ntn
system-config
daemon-control
rootfs
zt-secure-element
zt-secure-boot
```

Recent repository history also contains `docs(scope)` commits. Treat that as a
repository precedent, but prefer the explicit `COMMIT-SCOPE.md` list unless the
user approves extending it.
