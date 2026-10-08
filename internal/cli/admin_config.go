package cli

// `admin config get|set` converges operator configuration in deployment
// target files: a kustomize overlay (ConfigMap generator `literals:`) or a
// docker compose file (`environment:`). Exactly one target flag is required;
// there are no baked-in paths. Values are matched line-wise so comments and
// layout elsewhere in the file are preserved.

import (
	"encoding/json"
	"errors"
	"os"
	"strings"

	"github.com/spf13/cobra"
)

func (c *commands) adminConfig() *cobra.Command {
	group := &cobra.Command{Use: "config", Short: "Converge operator config in overlay/compose targets"}
	group.AddCommand(c.adminConfigVar("coordinator-id"), c.adminConfigVar("ci-policies"))
	return group
}

func (c *commands) adminConfigVar(name string) *cobra.Command {
	group := &cobra.Command{Use: name, Short: "Get or set " + name}
	group.AddCommand(c.adminConfigGet(name), c.adminConfigSet(name))
	return group
}

// splitEnvLine parses a "- NAME=value" list entry, tolerating the leading
// dash, indentation, and single-quote wrapping. It reports whether the line
// is an env entry at all.
func splitEnvLine(line string) (name, value string, quoted bool, ok bool) {
	t := strings.TrimSpace(line)
	if !strings.HasPrefix(t, "- ") {
		return "", "", false, false
	}
	t = strings.TrimSpace(strings.TrimPrefix(t, "- "))
	i := strings.Index(t, "=")
	if i < 0 {
		return "", "", false, false
	}
	name, value = t[:i], t[i+1:]
	if len(value) >= 2 && strings.HasPrefix(value, "'") && strings.HasSuffix(value, "'") {
		value = strings.ReplaceAll(value[1:len(value)-1], "''", "'")
		quoted = true
	}
	return name, value, quoted, true
}

func normalizePoliciesFile(raw []byte) (string, error) {
	s := string(raw)
	if strings.HasSuffix(s, "\r\n") {
		s = s[:len(s)-2]
	} else {
		s = strings.TrimSuffix(s, "\n")
	}
	if strings.ContainsAny(s, "\r\n") {
		return "", errors.New("policies file must be single-line JSON; multi-line values cannot be stored in one env entry")
	}
	return s, nil
}

func quoteEnvValue(v string) string {
	if strings.ContainsAny(v, " \t#{}[]:,\"'") {
		return "'" + strings.ReplaceAll(v, "'", "''") + "'"
	}
	return v
}

type envTarget struct {
	path   string
	anchor string // "literals:" for overlays, "environment:" for compose
}

func resolveEnvTarget(overlay, compose string) (envTarget, error) {
	if overlay != "" && compose != "" {
		return envTarget{}, errors.New("use exactly one of --overlay or --compose")
	}
	if overlay != "" {
		return envTarget{path: overlay, anchor: "literals:"}, nil
	}
	if compose != "" {
		return envTarget{path: compose, anchor: "environment:"}, nil
	}
	return envTarget{}, errors.New("a target file is required: --overlay or --compose")
}

func readTargetLines(path string) ([]string, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, errors.New("cannot read target file: " + path)
	}
	// Refuse secrets-bearing paths that are world-readable? No: overlays are
	// committed config; values here are non-secret by contract (Secret
	// name/key references only, never inline values).
	return strings.Split(string(raw), "\n"), nil
}

func writeTargetLines(path string, lines []string) error {
	fi, err := os.Stat(path)
	if err != nil {
		return errors.New("cannot stat target file: " + path)
	}
	return os.WriteFile(path, []byte(strings.Join(lines, "\n")), fi.Mode().Perm())
}

// findEnv scans lines for NAME= entries. It returns the value and line index.
func findEnv(lines []string, name string) (string, int, bool) {
	for i, l := range lines {
		if n, v, _, ok := splitEnvLine(l); ok && n == name {
			return v, i, true
		}
	}
	return "", -1, false
}

// setEnvLine returns updated lines with NAME converged to value, and whether
// anything changed. New entries are inserted directly under the anchor line.
func setEnvLine(lines []string, anchor, name, value string) ([]string, bool, error) {
	if strings.ContainsAny(value, "\r\n") {
		return nil, false, errors.New("config values must be single-line")
	}
	if cur, idx, found := findEnv(lines, name); found {
		if cur == value {
			return lines, false, nil
		}
		indent := lines[idx][:len(lines[idx])-len(strings.TrimLeft(lines[idx], " "))]
		lines[idx] = indent + "- " + name + "=" + quoteEnvValue(value)
		// Preserve original quoting when the old line was quoted and the new
		// value needs no quotes: keep it unquoted (canonical form).
		return lines, true, nil
	}
	anchorIdx := -1
	anchorIndent := ""
	for i, l := range lines {
		t := strings.TrimSpace(l)
		if t == anchor {
			anchorIdx = i
			anchorIndent = l[:len(l)-len(strings.TrimLeft(l, " "))]
			break
		}
	}
	if anchorIdx < 0 {
		return nil, false, errors.New("target file has no " + anchor + " block; add one first")
	}
	entry := anchorIndent + "  - " + name + "=" + quoteEnvValue(value)
	out := append([]string{}, lines[:anchorIdx+1]...)
	out = append(out, entry)
	out = append(out, lines[anchorIdx+1:]...)
	return out, true, nil
}

func (c *commands) adminConfigGet(name string) *cobra.Command {
	overlay, compose := "", ""
	cmd := &cobra.Command{Use: "get", Short: "Read " + name + " from the target file", Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, args []string) error {
		t, err := resolveEnvTarget(overlay, compose)
		if err != nil {
			return err
		}
		lines, err := readTargetLines(t.path)
		if err != nil {
			return err
		}
		v, _, found := findEnv(lines, envName(name))
		if !found {
			return errors.New(name + " is not set in " + t.path)
		}
		return c.adminReport(cmd, "admin config get "+name, false, nil, map[string]any{"name": name, "value": v, "target": t.path})
	}}
	cmd.Flags().StringVar(&overlay, "overlay", "", "Kustomize overlay kustomization.yaml path")
	cmd.Flags().StringVar(&compose, "compose", "", "Docker compose file path")
	return cmd
}

func envName(name string) string {
	switch name {
	case "coordinator-id":
		return "AGENTBOARD_COORDINATOR_ID"
	case "ci-policies":
		return "AGENTBOARD_CI_POLICIES"
	}
	return name
}

func (c *commands) adminConfigSet(name string) *cobra.Command {
	overlay, compose, file := "", "", ""
	dryRun := false
	use := "set"
	if name == "coordinator-id" {
		use = "set AGENT_ID"
	}
	run := func(cmd *cobra.Command, args []string) error {
		desired := ""
		if name == "ci-policies" {
			if file == "" {
				return errors.New("ci-policies set requires --file policies.json")
			}
			raw, err := os.ReadFile(file)
			if err != nil {
				return errors.New("cannot read policies file")
			}
			if !json.Valid(raw) {
				return errors.New("policies file is not valid JSON; nothing was written")
			}
			desired, err = normalizePoliciesFile(raw)
			if err != nil {
				return err
			}
		} else {
			desired = args[0]
		}
		t, err := resolveEnvTarget(overlay, compose)
		if err != nil {
			return err
		}
		lines, err := readTargetLines(t.path)
		if err != nil {
			return err
		}
		key := envName(name)
		current, _, _ := findEnv(lines, key)
		diff := []adminDiff{}
		if current != desired {
			diff = append(diff, adminDiff{Scope: "config", Field: key, Current: current, Desired: desired})
		}
		if dryRun {
			if err := c.adminReport(cmd, "admin config set "+name, true, diff, map[string]any{"name": name, "target": t.path}); err != nil {
				return err
			}
			if len(diff) > 0 {
				return adminPending("admin config set "+name, len(diff))
			}
			return nil
		}
		if len(diff) == 0 {
			return c.adminReport(cmd, "admin config set "+name, false, nil, map[string]any{"name": name, "converged": true})
		}
		updated, _, err := setEnvLine(lines, t.anchor, key, desired)
		if err != nil {
			return err
		}
		if err := writeTargetLines(t.path, updated); err != nil {
			return &adminExit{code: 1, msg: "admin config set " + name + ": write failed: " + err.Error()}
		}
		return c.adminReport(cmd, "admin config set "+name, false, diff, map[string]any{"name": name, "target": t.path, "converged": true})
	}
	cmd := &cobra.Command{Use: use, Short: "Converge " + name + " in the target file", Args: cobra.NoArgs, RunE: run}
	if name == "ci-policies" {
		cmd.Flags().StringVar(&file, "file", "", "JSON policies file")
	} else {
		cmd.Args = cobra.ExactArgs(1)
	}
	cmd.Flags().StringVar(&overlay, "overlay", "", "Kustomize overlay kustomization.yaml path")
	cmd.Flags().StringVar(&compose, "compose", "", "Docker compose file path")
	cmd.Flags().BoolVar(&dryRun, "dry-run", false, "Show the diff without writing anything")
	cmd.Flags().BoolVar(&dryRun, "plan", false, "Alias for --dry-run")
	return cmd
}
