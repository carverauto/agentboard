# Global skill installer diagram evidence

The source and standalone HTML were delivered with Archify showcase validation: 9/9 checks, zero composition errors/warnings. Final source SHA-256 `87d7b7203d722a36e870ba9f5e75c9c72edc6f42e05f3fe579b45d3aedda3534`; HTML SHA-256 `f02c9b3497f6fd2e9728bbf6e24af0b66dd2c94f39b9007a68a786b13f359810`.

Automated browser evidence passed at 1440×900, 1600×1000, 1920×1080 and 2048×1320, with light/dark endpoint captures bound in `global-skills.visual-check.json`. The initial tall composition failed vertical containment and was revised into two rows before final delivery.

Perceptual review passed after image-capable inspection of the delivered light desktop and dark large-display screenshots: labels fit, routes remain separate, both themes have clear contrast, diagram and conclusion cards fit the screen, and no conspicuous empty lower band dominates the composition. No candidate edits followed final delivery. Viewer design uses Archify’s classic theme; this is a system diagram, not a dashboard UI mockup.

The graph describes this branch’s offline CLI implementation, not a deployed server feature. No hooks or routines are installed. Repository source pointers were omitted because the feature commit was not yet public at rendering time; implementation is in `skill_bundle.go` and `internal/cli/skills.go`.
