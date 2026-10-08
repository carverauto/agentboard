// Package agentboard contains the workflow payload shipped with the CLI.
package agentboard

import "embed"

// Skills includes the shared workflows and their supporting documentation.
//
//go:embed skills/*/SKILL.md skills/agentboard/ask-user-escalation.md skills/agentboard-muse/participation.md docs/api.md docs/quota.md docs/participation.md docs/context.md docs/coordinator/adapters/grok-bot.md
var Skills embed.FS

// SeatLauncher is the same isolation engine used by source-side launchers.
// Python 3 and Git are explicit runtime prerequisites for seat recovery.
//
//go:embed scripts/launch-seat
var SeatLauncher string
