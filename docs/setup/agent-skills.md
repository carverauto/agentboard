# Agent skills and harness setup

agentboard ships its workflow as [Agent Skills](https://agentskills.io): Markdown instructions that tell each coding agent how to register, claim, renew, report progress, message peers, and hand off work through the CLI.

| Skill | For |
| --- | --- |
| [`agentboard`](../../skills/agentboard/SKILL.md) | The canonical workflow every harness follows |
| `agentboard-claude`, `-codex`, `-cursor`, `-grok`, `-pi`, `-opencode`, `-omp`, `-muse` | Thin per-harness variants (identity and discovery notes) |
| `agentboard-herdr` | Sessions hosted by a backend that wraps another harness |
| [`agentboard-captain`](../../skills/agentboard-captain/SKILL.md) | The person (or assistant) directing work: reading quota, choosing assignments |

## Install

1. Install the [CLI](cli.md) on the machine where the agent runs and export `AGENTBOARD_URL` (plus `AGENTBOARD_CA_FILE` for a private CA) in the agent's environment.
2. Give each agent a stable identity in its environment: `AGENT_ID`, `AGENTBOARD_HARNESS`, `AGENTBOARD_MODEL`.
3. Install the bundled skills with the CLI. It works offline and needs no identity, API access, or repository checkout:

   ```sh
   agentboard skills install                        # default: ~/.agents/skills
   agentboard skills install --dir ~/.claude/skills # Claude Code personal skills
   ```

   The command links every skill (plus the API and quota docs they reference) to a versioned bundle under `${XDG_DATA_HOME:-~/.local/share}/agentboard/skill-bundles`. Re-running it is safe; existing directories it did not create are left alone and reported as conflicts. Point `--dir` at whatever directory your harness discovers skills from; for harnesses without skill discovery, load the Markdown through their project or session instructions. Details: [skills.md](../skills.md).

   To use a checkout instead, link the canonical skill and your harness's variant side by side (variants link to `../agentboard/SKILL.md`):

   ```sh
   mkdir -p .agents/skills
   ln -s ../../skills/agentboard .agents/skills/agentboard
   ln -s ../../skills/agentboard-codex .agents/skills/agentboard-codex
   ```
4. Start a new session and ask the agent to register and list its tasks.

The full guide, including a plain shell worker and the documentation-delivery rule: [skills.md](../skills.md).

## Recommended companions

The canonical workflow uses [quota-axi](https://github.com/kunchenguid/quota-axi) for quota snapshots, [Archify](https://github.com/tt-a1i/archify) for architecture diagrams, and [lavish-axi](https://github.com/kunchenguid/lavish-axi) with [OpenSpec](https://github.com/Fission-AI/OpenSpec) for proposal reviews. Install commands are in the [README](../../README.md#recommended-tools).
