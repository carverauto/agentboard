# Agent workflow skills

The canonical workflow is [skills/agentboard/SKILL.md](../skills/agentboard/SKILL.md). Thin variants cover [Claude](../skills/agentboard-claude/SKILL.md), [Codex](../skills/agentboard-codex/SKILL.md), [Pi](../skills/agentboard-pi/SKILL.md), [Grok](../skills/agentboard-grok/SKILL.md), [Cursor](../skills/agentboard-cursor/SKILL.md), [OpenCode](../skills/agentboard-opencode/SKILL.md), [OMP](../skills/agentboard-omp/SKILL.md), [Muse](../skills/agentboard-muse/SKILL.md), and [Herdr-hosted sessions](../skills/agentboard-herdr/SKILL.md). The [captain playbook](../skills/agentboard-captain/SKILL.md) covers explicitly directed quota/assignment choices.

For this repository, Codex discovers workspace skills under `.agents/skills`, and Claude/OpenCode bindings already use `.claude/skills`/`.opencode/skills`. Copy or symlink the canonical and selected variant directories into the supported directory for your installation, preserving sibling relationships. For other harnesses, load the Markdown through their supported project/session instructions; these variants do not claim unverified discovery paths or hooks. Keep the `docs/` references available, or use the original repository paths when loading skills.

For example, from the repository root, install the Codex pair with links:

```sh
mkdir -p .agents/skills
ln -s ../../skills/agentboard .agents/skills/agentboard
ln -s ../../skills/agentboard-codex .agents/skills/agentboard-codex
```

The links resolve to the repository's canonical files and their documentation. If either destination already exists, inspect it first rather than overwriting an installed workflow. Installation is opt-in; this change does not replace existing harness settings.

A plain shell worker uses the same CLI:

```sh
export AGENT_ID=shell-worker AGENTBOARD_HARNESS=shell AGENTBOARD_MODEL=human
export AGENTBOARD_URL=https://agentboard.farm01.carverauto.dev
agentboard agent register --name 'Shell worker'
agentboard task list --owner "$AGENT_ID" --json
agentboard msg list --unread --json
agentboard task claim TASK --json
agentboard agent heartbeat --status busy --task TASK --json
agentboard task renew TASK --json
agentboard task update TASK --body 'Verification evidence and next step' --json
```

Configure the model to describe the actual caller. Shell automation can use its own stable descriptive actor model. For a session hosted by Herdr, retain its underlying harness and record `--backend herdr`; do not confuse the backend with the harness/model.

No automatic hooks, lease sweeper, provider routing, merges, or deployments are installed. A heartbeat is not a renewal. See the canonical skill for conflict/expiry handling and the [API docs](api.md) for JSON output and exit codes.

All harnesses inherit the canonical visual delivery rule: feature/design PRs include validated Archify source and HTML; OpenSpec proposals automatically render in Lavish. Upload portable HTML with `agentboard doc push` and link its durable task viewer before completion. See [documentation delivery](documents.md).
