// Package agentboard contains the workflow payload shipped with the CLI.
package agentboard

import "embed"

// Skills includes the shared workflows and their supporting documentation.
//
//go:embed skills/*/SKILL.md docs/api.md docs/quota.md GROK_BOT.md
var Skills embed.FS
