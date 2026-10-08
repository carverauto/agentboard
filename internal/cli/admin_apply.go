package cli

// `admin doctor` and `admin apply -f` (GH #138).
//
// The apply file is a strict YAML subset (apiVersion
// agentboard.carverauto.dev/v1, kind AdminConfig): 2-space indented maps,
// `key: value` scalars, `- item` lists, `#` full-line comments, single- and
// double-quoted scalars. Tabs, flow styles, anchors, and duplicate keys are
// rejected. Any key that looks like an inline secret (token/secret/password
// unless it ends in _file/_path/_name/_ref) rejects the whole file before
// anything runs. `apply` converges files plus board state through the same
// converge functions as the individual subcommands; it never runs kubectl or
// docker (cluster rolls stay in `admin rollout`).

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/carverauto/agentboard/internal/client"
	"github.com/spf13/cobra"
)

// ---------- strict YAML subset ----------

type ynode struct {
	line int
	str  string
	has  bool
	m    map[string]ynode
	l    []ynode
}

func (n ynode) isMap() bool  { return n.m != nil }
func (n ynode) isList() bool { return n.l != nil }
func (n ynode) isStr() bool  { return n.has }

func stripComment(s string) string {
	inS, inD := false, false
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '\'':
			if !inD {
				if inS && i+1 < len(s) && s[i+1] == '\'' {
					i++
				} else {
					inS = !inS
				}
			}
		case '"':
			if !inS {
				if inD && i > 0 && s[i-1] == '\\' {
					// escaped
				} else {
					inD = !inD
				}
			}
		case '#':
			if !inS && !inD && i > 0 && (s[i-1] == ' ' || s[i-1] == '\t') {
				return strings.TrimRight(s[:i-1], " \t")
			}
		}
	}
	return s
}

func parseScalar(s string, line int) (string, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return "", nil
	}
	if strings.HasPrefix(s, "'") {
		if len(s) < 2 || !strings.HasSuffix(s, "'") {
			return "", fmt.Errorf("line %d: unterminated single-quoted scalar", line)
		}
		return strings.ReplaceAll(s[1:len(s)-1], "''", "'"), nil
	}
	if strings.HasPrefix(s, "\"") {
		if len(s) < 2 || !strings.HasSuffix(s, "\"") {
			return "", fmt.Errorf("line %d: unterminated double-quoted scalar", line)
		}
		var b strings.Builder
		inner := s[1 : len(s)-1]
		for i := 0; i < len(inner); i++ {
			if inner[i] == '\\' && i+1 < len(inner) {
				i++
				switch inner[i] {
				case 'n':
					b.WriteByte('\n')
				case 't':
					b.WriteByte('\t')
				case '\\', '"':
					b.WriteByte(inner[i])
				default:
					return "", fmt.Errorf("line %d: bad escape", line)
				}
			} else {
				b.WriteByte(inner[i])
			}
		}
		return b.String(), nil
	}
	for _, bad := range []string{"{", "}", "[", "]", "*", "&", "!", "|", ">", "%@", "`"} {
		if strings.HasPrefix(s, bad) {
			return "", fmt.Errorf("line %d: flow/block styles are not supported", line)
		}
	}
	if strings.Contains(s, "\t") {
		return "", fmt.Errorf("line %d: tabs are not allowed", line)
	}
	return s, nil
}

type yline struct {
	num    int
	indent int
	text   string
}

func parseYAMLSubset(raw string) (ynode, error) {
	var lines []yline
	for i, l := range strings.Split(raw, "\n") {
		n := i + 1
		if strings.Contains(l, "\t") {
			// Tabs are only legal inside quoted scalars; the scalar
			// parser re-checks, so pre-scan the leading whitespace.
			lead := l[:len(l)-len(strings.TrimLeft(l, " \t"))]
			if strings.Contains(lead, "\t") {
				return ynode{}, fmt.Errorf("line %d: tabs are not allowed", n)
			}
		}
		t := stripComment(l)
		if strings.TrimSpace(t) == "" || strings.TrimSpace(t) == "---" {
			continue
		}
		indent := len(l) - len(strings.TrimLeft(l, " "))
		lines = append(lines, yline{num: n, indent: indent, text: strings.TrimSpace(t)})
	}
	pos := 0
	doc, err := parseBlock(lines, &pos, -1)
	if err != nil {
		return ynode{}, err
	}
	if pos != len(lines) {
		return ynode{}, fmt.Errorf("line %d: unexpected content", lines[pos].num)
	}
	if !doc.isMap() {
		return ynode{}, errors.New("top-level mapping required")
	}
	return doc, nil
}

func parseBlock(lines []yline, pos *int, parent int) (ynode, error) {
	if *pos >= len(lines) || lines[*pos].indent <= parent {
		return ynode{}, errors.New("empty block")
	}
	if strings.HasPrefix(lines[*pos].text, "- ") || lines[*pos].text == "-" {
		return parseList(lines, pos, parent)
	}
	return parseMap(lines, pos, parent)
}

func parseMap(lines []yline, pos *int, parent int) (ynode, error) {
	m := map[string]ynode{}
	indent := lines[*pos].indent
	for *pos < len(lines) && lines[*pos].indent == indent {
		l := lines[*pos]
		if strings.HasPrefix(l.text, "- ") || l.text == "-" {
			return ynode{}, fmt.Errorf("line %d: list item inside mapping", l.num)
		}
		ki := strings.Index(l.text, ":")
		if ki < 0 {
			return ynode{}, fmt.Errorf("line %d: expected key: value", l.num)
		}
		key := strings.TrimSpace(l.text[:ki])
		if key == "" {
			return ynode{}, fmt.Errorf("line %d: empty key", l.num)
		}
		if _, dup := m[key]; dup {
			return ynode{}, fmt.Errorf("line %d: duplicate key %q", l.num, key)
		}
		rest := strings.TrimSpace(l.text[ki+1:])
		*pos++
		if rest != "" {
			v, err := parseScalar(rest, l.num)
			if err != nil {
				return ynode{}, err
			}
			m[key] = ynode{line: l.num, str: v, has: true}
			continue
		}
		if *pos >= len(lines) || lines[*pos].indent < indent {
			m[key] = ynode{line: l.num, m: map[string]ynode{}}
			continue
		}
		if lines[*pos].indent == indent {
			// Same-indent continuation is only a dash list (`key:\n- item`).
			if !strings.HasPrefix(lines[*pos].text, "- ") && lines[*pos].text != "-" {
				return ynode{}, fmt.Errorf("line %d: expected an indented block", lines[*pos].num)
			}
			child, err := parseList(lines, pos, indent)
			if err != nil {
				return ynode{}, err
			}
			child.line = l.num
			m[key] = child
			continue
		}
		child, err := parseBlock(lines, pos, indent)
		if err != nil {
			return ynode{}, err
		}
		child.line = l.num
		m[key] = child
	}
	return ynode{m: m}, nil
}

func parseList(lines []yline, pos *int, parent int) (ynode, error) {
	var out []ynode
	indent := lines[*pos].indent
	for *pos < len(lines) && lines[*pos].indent == indent &&
		(strings.HasPrefix(lines[*pos].text, "- ") || lines[*pos].text == "-") {
		l := lines[*pos]
		rest := ""
		if l.text != "-" {
			rest = strings.TrimSpace(strings.TrimPrefix(l.text, "- "))
		}
		*pos++
		if rest == "" {
			if *pos >= len(lines) || lines[*pos].indent <= indent {
				out = append(out, ynode{line: l.num, m: map[string]ynode{}})
				continue
			}
			child, err := parseBlock(lines, pos, indent)
			if err != nil {
				return ynode{}, err
			}
			child.line = l.num
			out = append(out, child)
			continue
		}
		if ki := strings.Index(rest, ":"); ki > 0 && !strings.HasPrefix(rest, "'") && !strings.HasPrefix(rest, "\"") {
			// "- key: value" map item; fold following lines at deeper indent.
			key := strings.TrimSpace(rest[:ki])
			val := strings.TrimSpace(rest[ki+1:])
			m := map[string]ynode{}
			if val != "" {
				v, err := parseScalar(val, l.num)
				if err != nil {
					return ynode{}, err
				}
				m[key] = ynode{line: l.num, str: v, has: true}
			} else {
				if *pos < len(lines) && lines[*pos].indent > indent {
					child, err := parseBlock(lines, pos, indent)
					if err != nil {
						return ynode{}, err
					}
					m[key] = child
				} else {
					m[key] = ynode{line: l.num, m: map[string]ynode{}}
				}
			}
			for *pos < len(lines) && lines[*pos].indent > indent &&
				!strings.HasPrefix(lines[*pos].text, "- ") && lines[*pos].text != "-" {
				sl := lines[*pos]
				ki2 := strings.Index(sl.text, ":")
				if ki2 < 0 {
					return ynode{}, fmt.Errorf("line %d: expected key: value", sl.num)
				}
				k2 := strings.TrimSpace(sl.text[:ki2])
				if _, dup := m[k2]; dup {
					return ynode{}, fmt.Errorf("line %d: duplicate key %q", sl.num, k2)
				}
				rest2 := strings.TrimSpace(sl.text[ki2+1:])
				if rest2 == "" && *pos+1 < len(lines) && lines[*pos+1].indent > sl.indent &&
					(strings.HasPrefix(lines[*pos+1].text, "- ") || lines[*pos+1].text == "-") {
					*pos++
					sub, err := parseList(lines, pos, sl.indent)
					if err != nil {
						return ynode{}, err
					}
					sub.line = sl.num
					m[k2] = sub
					continue
				}
				v2, err := parseScalar(rest2, sl.num)
				if err != nil {
					return ynode{}, err
				}
				if rest2 == "" {
					m[k2] = ynode{line: sl.num, m: map[string]ynode{}}
				} else {
					m[k2] = ynode{line: sl.num, str: v2, has: true}
				}
				*pos++
			}
			out = append(out, ynode{line: l.num, m: m})
			continue
		}
		v, err := parseScalar(rest, l.num)
		if err != nil {
			return ynode{}, err
		}
		out = append(out, ynode{line: l.num, str: v, has: true})
	}
	return ynode{l: out}, nil
}

// ---------- schema ----------

type adminWorkerSpec struct {
	ID, Action, Host string
	Repos            []string
	Model, Harness   string
	TokenFile        string
	Config, Home     string
	Platform         string
	Rotate           bool
}

type adminAgentSpec struct {
	ID, Harness, Model string
}

type adminFileConfig struct {
	Overlay, Compose string
	CoordinatorID    string
	CIPoliciesFile   string
}

type adminPinImage struct {
	Name, Digest string
}

type adminFilePins struct {
	Overlay, Compose string
	Images           []adminPinImage
}

type adminFile struct {
	Workers []adminWorkerSpec
	Agents  []adminAgentSpec
	Config  adminFileConfig
	Pins    adminFilePins
}

var secretKey = map[string]bool{"token": true, "secret": true, "password": true, "privatekey": true, "private_key": true, "credential": true, "credentials": true}

func secretKeyName(k string) bool {
	lk := strings.ToLower(k)
	for _, suf := range []string{"_file", "_path", "_name", "_ref"} {
		if strings.HasSuffix(lk, suf) {
			return false
		}
	}
	return secretKey[lk]
}

func rejectInlineSecrets(n ynode) error {
	if n.isMap() {
		for k, v := range n.m {
			if secretKeyName(k) {
				return fmt.Errorf("line %d: inline secret %q rejected; use a *_file reference", v.line, k)
			}
			if err := rejectInlineSecrets(v); err != nil {
				return err
			}
		}
	}
	if n.isList() {
		for _, v := range n.l {
			if err := rejectInlineSecrets(v); err != nil {
				return err
			}
		}
	}
	return nil
}

func strField(m map[string]ynode, key string, what string) (string, error) {
	n, ok := m[key]
	if !ok || (!n.isStr() && !n.isMap() && !n.isList()) {
		return "", nil
	}
	if !n.isStr() {
		return "", fmt.Errorf("%s.%s must be a string", what, key)
	}
	return n.str, nil
}

func boolField(m map[string]ynode, key string, what string) (bool, error) {
	n, ok := m[key]
	if !ok {
		return false, nil
	}
	if !n.isStr() {
		return false, fmt.Errorf("%s.%s must be true/false", what, key)
	}
	b, err := strconv.ParseBool(n.str)
	if err != nil {
		return false, fmt.Errorf("%s.%s must be true/false", what, key)
	}
	return b, nil
}

func checkKeys(m map[string]ynode, allowed map[string]bool, what string) error {
	for k, v := range m {
		if !allowed[k] {
			return fmt.Errorf("%s: unknown field %q (line %d)", what, k, v.line)
		}
	}
	return nil
}

func decodeAdminFile(doc ynode) (adminFile, error) {
	var f adminFile
	av, ok := doc.m["apiVersion"]
	if !ok || !av.isStr() || av.str != "agentboard.carverauto.dev/v1" {
		return f, errors.New("apiVersion must be agentboard.carverauto.dev/v1")
	}
	kind, ok := doc.m["kind"]
	if !ok || !kind.isStr() || kind.str != "AdminConfig" {
		return f, errors.New("kind must be AdminConfig")
	}
	if err := checkKeys(doc.m, map[string]bool{"apiVersion": true, "kind": true, "workers": true, "agents": true, "config": true, "pins": true}, "top level"); err != nil {
		return f, err
	}
	if err := rejectInlineSecrets(doc); err != nil {
		return f, err
	}
	if w, ok := doc.m["workers"]; ok {
		if !w.isList() {
			return f, errors.New("workers must be a list")
		}
		for _, it := range w.l {
			if !it.isMap() {
				return f, fmt.Errorf("line %d: worker entry must be a mapping", it.line)
			}
			if err := checkKeys(it.m, map[string]bool{"id": true, "action": true, "host": true, "repos": true, "model": true, "harness": true, "token_file": true, "config": true, "home": true, "platform": true, "rotate": true}, "workers[]"); err != nil {
				return f, err
			}
			var s adminWorkerSpec
			var err error
			if s.ID, err = strField(it.m, "id", "workers[]"); err != nil {
				return f, err
			}
			if s.ID == "" {
				return f, fmt.Errorf("line %d: worker id is required", it.line)
			}
			if s.Action, err = strField(it.m, "action", "workers[]"); err != nil {
				return f, err
			}
			if s.Action != "create" && s.Action != "enroll" && s.Action != "revoke" {
				return f, fmt.Errorf("line %d: worker action must be create/enroll/revoke", it.line)
			}
			if s.Host, err = strField(it.m, "host", "workers[]"); err != nil {
				return f, err
			}
			if r, ok := it.m["repos"]; ok {
				if !r.isList() {
					return f, fmt.Errorf("line %d: repos must be a list", r.line)
				}
				for _, e := range r.l {
					if !e.isStr() {
						return f, fmt.Errorf("line %d: repo must be a string", e.line)
					}
					s.Repos = append(s.Repos, e.str)
				}
			}
			if s.Model, err = strField(it.m, "model", "workers[]"); err != nil {
				return f, err
			}
			if s.Harness, err = strField(it.m, "harness", "workers[]"); err != nil {
				return f, err
			}
			if s.TokenFile, err = strField(it.m, "token_file", "workers[]"); err != nil {
				return f, err
			}
			if s.Config, err = strField(it.m, "config", "workers[]"); err != nil {
				return f, err
			}
			if s.Home, err = strField(it.m, "home", "workers[]"); err != nil {
				return f, err
			}
			if s.Platform, err = strField(it.m, "platform", "workers[]"); err != nil {
				return f, err
			}
			if s.Rotate, err = boolField(it.m, "rotate", "workers[]"); err != nil {
				return f, err
			}
			f.Workers = append(f.Workers, s)
		}
	}
	if a, ok := doc.m["agents"]; ok {
		if !a.isList() {
			return f, errors.New("agents must be a list")
		}
		for _, it := range a.l {
			if !it.isMap() {
				return f, fmt.Errorf("line %d: agent entry must be a mapping", it.line)
			}
			if err := checkKeys(it.m, map[string]bool{"id": true, "harness": true, "model": true}, "agents[]"); err != nil {
				return f, err
			}
			var s adminAgentSpec
			var err error
			if s.ID, err = strField(it.m, "id", "agents[]"); err != nil {
				return f, err
			}
			if s.ID == "" {
				return f, fmt.Errorf("line %d: agent id is required", it.line)
			}
			if s.Harness, err = strField(it.m, "harness", "agents[]"); err != nil {
				return f, err
			}
			if s.Model, err = strField(it.m, "model", "agents[]"); err != nil {
				return f, err
			}
			f.Agents = append(f.Agents, s)
		}
	}
	if cf, ok := doc.m["config"]; ok {
		if !cf.isMap() {
			return f, errors.New("config must be a mapping")
		}
		if err := checkKeys(cf.m, map[string]bool{"overlay": true, "compose": true, "coordinator_id": true, "ci_policies_file": true}, "config"); err != nil {
			return f, err
		}
		var err error
		if f.Config.Overlay, err = strField(cf.m, "overlay", "config"); err != nil {
			return f, err
		}
		if f.Config.Compose, err = strField(cf.m, "compose", "config"); err != nil {
			return f, err
		}
		if f.Config.CoordinatorID, err = strField(cf.m, "coordinator_id", "config"); err != nil {
			return f, err
		}
		if f.Config.CIPoliciesFile, err = strField(cf.m, "ci_policies_file", "config"); err != nil {
			return f, err
		}
	}
	if pn, ok := doc.m["pins"]; ok {
		if !pn.isMap() {
			return f, errors.New("pins must be a mapping")
		}
		if err := checkKeys(pn.m, map[string]bool{"overlay": true, "compose": true, "images": true}, "pins"); err != nil {
			return f, err
		}
		var err error
		if f.Pins.Overlay, err = strField(pn.m, "overlay", "pins"); err != nil {
			return f, err
		}
		if f.Pins.Compose, err = strField(pn.m, "compose", "pins"); err != nil {
			return f, err
		}
		if im, ok := pn.m["images"]; ok {
			if !im.isList() {
				return f, errors.New("pins.images must be a list")
			}
			for _, it := range im.l {
				if !it.isMap() {
					return f, fmt.Errorf("line %d: image entry must be a mapping", it.line)
				}
				if err := checkKeys(it.m, map[string]bool{"name": true, "digest": true}, "pins.images[]"); err != nil {
					return f, err
				}
				nm, _ := strField(it.m, "name", "pins.images[]")
				dg, _ := strField(it.m, "digest", "pins.images[]")
				if nm == "" || dg == "" {
					return f, fmt.Errorf("line %d: image name and digest are required", it.line)
				}
				if digestRef.FindStringSubmatch(nm+"@"+dg) == nil || pinRepoHasTag(nm) {
					return f, fmt.Errorf("line %d: pins must be IMAGE@sha256 digests; tags rejected", it.line)
				}
				f.Pins.Images = append(f.Pins.Images, adminPinImage{Name: nm, Digest: dg})
			}
		}
	}
	return f, nil
}

func loadAdminFile(path string) (adminFile, error) {
	var f adminFile
	raw, err := os.ReadFile(path)
	if err != nil {
		return f, errors.New("cannot read apply file: " + path)
	}
	doc, err := parseYAMLSubset(string(raw))
	if err != nil {
		return f, err
	}
	return decodeAdminFile(doc)
}

// ---------- doctor ----------

func (c *commands) adminDoctor() *cobra.Command {
	applyFile, overlay, compose := "", "", ""
	var agentIDs []string
	namespace, deployment, kubeContext := "", "", ""
	cmd := &cobra.Command{Use: "doctor", Short: "Read-only drift report across workers, agents, config, and pins", Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, args []string) error {
		return c.runDoctor(cmd, applyFile, overlay, compose, agentIDs, namespace, deployment, kubeContext)
	}}
	cmd.Flags().StringVarP(&applyFile, "file", "f", "", "Apply file holding desired state")
	cmd.Flags().StringVar(&overlay, "overlay", "", "Kustomize overlay path for file checks")
	cmd.Flags().StringVar(&compose, "compose", "", "Compose file path for file checks")
	cmd.Flags().StringArrayVar(&agentIDs, "agent-id", nil, "Agent IDs to check (repeatable)")
	cmd.Flags().StringVar(&namespace, "namespace", "", "Namespace for the live pin check")
	cmd.Flags().StringVar(&deployment, "deployment", "", "Deployment for the live pin check")
	cmd.Flags().StringVar(&kubeContext, "context", "", "kubectl context for the live pin check")
	return cmd
}

func (c *commands) runDoctor(cmd *cobra.Command, applyFile, overlay, compose string, agentIDs []string, namespace, deployment, kubeContext string) error {
	name := "admin doctor"
	drift := []adminDiff{}
	notes := map[string]any{}
	api, err := client.New(c.cfg)
	if err != nil {
		return err
	}
	defer api.Close()
	raw, err := api.JSON(cmd.Context(), http.MethodGet, "meta", nil, nil)
	if err != nil {
		return &adminExit{code: 1, msg: name + ": board unreachable: " + err.Error()}
	}
	var meta struct {
		API    int `json:"api_version"`
		Schema int `json:"schema_version"`
	}
	if json.Unmarshal(raw, &meta) != nil || meta.API != 1 {
		return &adminExit{code: 1, msg: name + ": incompatible board API"}
	}
	notes["schema_version"] = meta.Schema

	if applyFile == "" && (overlay != "" || compose != "") {
		return errors.New("--overlay/--compose require -f; pass an apply file holding desired state")
	}
	var af adminFile
	if applyFile != "" {
		af, err = loadAdminFile(applyFile)
		if err != nil {
			return err
		}
		if af.Config.Overlay != "" && af.Config.Compose != "" {
			return errors.New("use exactly one of --overlay or --compose")
		}
		for _, a := range af.Agents {
			agentIDs = append(agentIDs, a.ID)
		}
	}
	seen := map[string]bool{}
	for _, id := range agentIDs {
		if seen[id] {
			continue
		}
		seen[id] = true
		araw, err := api.JSON(cmd.Context(), http.MethodGet, "agents/"+id, nil, nil)
		if err != nil {
			drift = append(drift, adminDiff{Scope: "agent", Field: id, Current: "absent", Desired: "registered"})
			continue
		}
		var env struct {
			Agent map[string]any `json:"agent"`
		}
		state := "registered"
		if json.Unmarshal(araw, &env) == nil && env.Agent != nil {
			if h, _ := env.Agent["harness"].(string); h != "" {
				state = "registered(harness=" + h + ")"
			}
		}
		notes["agent:"+id] = state
	}
	if applyFile != "" {
		for _, w := range af.Workers {
			if w.TokenFile == "" || w.Action == "revoke" {
				continue
			}
			fi, err := os.Lstat(w.TokenFile)
			switch {
			case os.IsNotExist(err):
				drift = append(drift, adminDiff{Scope: "worker", Field: w.ID, Current: "token-file absent", Desired: w.TokenFile})
			case err != nil:
				drift = append(drift, adminDiff{Scope: "worker", Field: w.ID, Current: "token-file unreadable", Desired: w.TokenFile})
			case fi.Mode().Perm() != 0600:
				drift = append(drift, adminDiff{Scope: "worker", Field: w.ID, Current: "token-file mode not 0600", Desired: w.TokenFile})
			default:
				notes["worker:"+w.ID] = "token-file protected"
			}
		}
		t := envTarget{}
		if af.Config.Overlay != "" || af.Config.Compose != "" {
			t, err = resolveEnvTarget(af.Config.Overlay, af.Config.Compose)
			if err != nil {
				return err
			}
		} else if overlay != "" || compose != "" {
			var terr error
			t, terr = resolveEnvTarget(overlay, compose)
			if terr != nil {
				return terr
			}
		}
		if af.Pins.Overlay != "" && af.Pins.Compose != "" {
			return errors.New("pins takes exactly one of overlay or compose")
		}
		if len(af.Pins.Images) > 0 && af.Pins.Overlay == "" && af.Pins.Compose == "" {
			return errors.New("pins.images requires exactly one of pins.overlay or pins.compose")
		}
		if (af.Config.CoordinatorID != "" || af.Config.CIPoliciesFile != "") && t.path == "" {
			return errors.New("config section needs overlay or compose")
		}
		pinsPath, pinKind := af.Pins.Overlay, "overlay"
		if af.Pins.Compose != "" {
			pinsPath, pinKind = af.Pins.Compose, "compose"
		}
		if t.path != "" || pinsPath != "" {
			if t.path != "" {
				lines, err := readTargetLines(t.path)
				if err != nil {
					return err
				}
				if af.Config.CoordinatorID != "" {
					if cur, _, found := findEnv(lines, "AGENTBOARD_COORDINATOR_ID"); !found || cur != af.Config.CoordinatorID {
						drift = append(drift, adminDiff{Scope: "config", Field: "AGENTBOARD_COORDINATOR_ID", Current: cur, Desired: af.Config.CoordinatorID})
					}
				}
				if af.Config.CIPoliciesFile != "" {
					praw, err := os.ReadFile(af.Config.CIPoliciesFile)
					if err != nil {
						return errors.New("cannot read policies file: " + af.Config.CIPoliciesFile)
					}
					want, nerr := normalizePoliciesFile(praw)
					if cur, _, found := findEnv(lines, "AGENTBOARD_CI_POLICIES"); nerr != nil || !found || cur != want {
						drift = append(drift, adminDiff{Scope: "config", Field: "AGENTBOARD_CI_POLICIES", Current: currentMarker(cur, found), Desired: "policies file content"})
					}
				}
			}
			if pinsPath != "" {
				plines, err := readTargetLines(pinsPath)
				if err != nil {
					return err
				}
				for _, im := range af.Pins.Images {
					want := im.Name + "@" + im.Digest
					if pinKind == "overlay" {
						_, prev, _, err := setOverlayDigest(plines, im.Name, im.Digest)
						if err != nil || prev != im.Digest {
							drift = append(drift, adminDiff{Scope: "pin", Field: im.Name, Current: prev, Desired: want})
						}
					} else {
						_, prev, _, err := setComposeImage(plines, im.Name, want)
						if err != nil || prev != want {
							drift = append(drift, adminDiff{Scope: "pin", Field: im.Name, Current: prev, Desired: want})
						}
					}
				}
			}
		}
	}
	if namespace != "" && deployment != "" {
		k, err := lookRunner("kubectl")
		if err != nil {
			return err
		}
		k.context, k.namespace = kubeContext, namespace
		out, err := k.run(cmd.Context(), "", time.Minute, "get", "deployment/"+deployment, "-o", "jsonpath={.spec.template.spec.containers[*].image}")
		if err != nil {
			return &adminExit{code: 1, msg: name + ": live pin read failed: " + err.Error()}
		}
		notes["live_pin"] = strings.TrimSpace(out)
	}
	return c.adminReport(cmd, name, false, drift, notes)
}

func currentMarker(cur string, found bool) string {
	if !found {
		return "absent"
	}
	return cur
}

// ---------- apply ----------

func (c *commands) adminApply() *cobra.Command {
	file := ""
	dryRun := false
	cmd := &cobra.Command{Use: "apply", Short: "Converge a declarative file through the same subcommands", Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, args []string) error {
		if file == "" {
			return errors.New("--file is required")
		}
		af, err := loadAdminFile(file)
		if err != nil {
			return err
		}
		return c.runApply(cmd, af, dryRun)
	}}
	cmd.Flags().StringVarP(&file, "file", "f", "", "AdminConfig file path")
	cmd.Flags().BoolVar(&dryRun, "dry-run", false, "Show the diff without writing anything")
	cmd.Flags().BoolVar(&dryRun, "plan", false, "Alias for --dry-run")
	return cmd
}

func workerDefaults(c *commands, s adminWorkerSpec) adminWorkerSpec {
	if s.Host == "" {
		s.Host, _ = os.Hostname()
	}
	if s.Model == "" {
		s.Model = c.cfg.Actor.Model
	}
	if s.Harness == "" {
		s.Harness = c.cfg.Actor.Harness
	}
	if s.Platform == "" {
		s.Platform = "linux"
	}
	if s.Config == "" {
		hd, _ := os.UserHomeDir()
		s.Config = filepath.Join(hd, ".config", "agentboard", "worker", "config.json")
	}
	return s
}

func (c *commands) runApply(cmd *cobra.Command, af adminFile, dryRun bool) error {
	name := "admin apply"
	all := []adminDiff{}
	ctx := cmd.Context()
	for _, w := range af.Workers {
		w = workerDefaults(c, w)
		switch w.Action {
		case "create":
			if w.TokenFile == "" {
				return errors.New("worker " + w.ID + ": create requires token_file")
			}
			if len(w.Repos) < 1 {
				return errors.New("worker " + w.ID + ": at least one repo is required")
			}
			if w.Rotate {
				return errors.New("worker " + w.ID + ": rotate is CLI-only; apply files must be re-runnable")
			}
			key := "admin/" + w.ID + "/" + w.Host
			diff, _, err := c.convergeWorkerCreate(ctx, createParams{
				id: w.ID, host: w.Host, repos: w.Repos, model: w.Model, harness: w.Harness,
				key: key, tokenFile: w.TokenFile, rotate: w.Rotate,
			}, dryRun)
			if err != nil {
				return &adminExit{code: 1, msg: name + ": worker " + w.ID + ": " + err.Error()}
			}
			all = append(all, diff...)
		case "enroll":
			if len(w.Repos) < 1 {
				return errors.New("worker " + w.ID + ": at least one repo is required")
			}
			diff, _, err := c.convergeWorkerEnroll(ctx, enrollParams{
				id: w.ID, host: w.Host, repos: w.Repos, model: w.Model, harness: w.Harness,
				tokenFile: w.TokenFile, configPath: w.Config, home: w.Home, platform: w.Platform,
			}, dryRun)
			if err != nil {
				return &adminExit{code: 1, msg: name + ": worker " + w.ID + ": " + err.Error()}
			}
			all = append(all, diff...)
		case "revoke":
			diff, _, err := c.convergeWorkerRevoke(ctx, w.ID, dryRun)
			if err != nil {
				return &adminExit{code: 1, msg: name + ": worker " + w.ID + ": " + err.Error()}
			}
			all = append(all, diff...)
		}
	}
	for _, a := range af.Agents {
		diff, _, err := c.convergeAgentRegister(ctx, a.ID, a.Harness, a.Model, dryRun)
		if err != nil {
			return &adminExit{code: 1, msg: name + ": agent " + a.ID + ": " + err.Error()}
		}
		all = append(all, diff...)
	}
	if af.Config.Overlay != "" || af.Config.Compose != "" {
		t, err := resolveEnvTarget(af.Config.Overlay, af.Config.Compose)
		if err != nil {
			return err
		}
		if af.Config.CoordinatorID != "" {
			diff, err := convergeConfigSet(t.path, t.anchor, "AGENTBOARD_COORDINATOR_ID", af.Config.CoordinatorID, dryRun)
			if err != nil {
				return &adminExit{code: 1, msg: name + ": config: " + err.Error()}
			}
			all = append(all, diff...)
		}
		if af.Config.CIPoliciesFile != "" {
			raw, err := os.ReadFile(af.Config.CIPoliciesFile)
			if err != nil {
				return errors.New("cannot read policies file")
			}
			if !json.Valid(raw) {
				return errors.New("policies file is not valid JSON; nothing was written")
			}
			desired, err := normalizePoliciesFile(raw)
			if err != nil {
				return err
			}
			diff, err := convergeConfigSet(t.path, t.anchor, "AGENTBOARD_CI_POLICIES", desired, dryRun)
			if err != nil {
				return &adminExit{code: 1, msg: name + ": config: " + err.Error()}
			}
			all = append(all, diff...)
		}
	} else if af.Config.CoordinatorID != "" || af.Config.CIPoliciesFile != "" {
		return errors.New("config section needs overlay or compose")
	}
	if af.Pins.Overlay != "" && af.Pins.Compose != "" {
		return errors.New("pins takes exactly one of overlay or compose")
	}
	if len(af.Pins.Images) > 0 && af.Pins.Overlay == "" && af.Pins.Compose == "" {
		return errors.New("pins.images requires exactly one of pins.overlay or pins.compose")
	}
	if af.Pins.Overlay != "" || af.Pins.Compose != "" {
		for _, im := range af.Pins.Images {
			if af.Pins.Overlay != "" {
				diff, _, err := convergeOverlayPin(af.Pins.Overlay, im.Name, im.Digest, dryRun)
				if err != nil {
					return &adminExit{code: 1, msg: name + ": pins: " + err.Error()}
				}
				all = append(all, diff...)
			} else {
				diff, _, err := convergeComposePin(af.Pins.Compose, im.Name, im.Name+"@"+im.Digest, dryRun)
				if err != nil {
					return &adminExit{code: 1, msg: name + ": pins: " + err.Error()}
				}
				all = append(all, diff...)
			}
		}
	}
	if err := c.adminReport(cmd, name, dryRun, all, map[string]any{"converged": len(all) == 0}); err != nil {
		return err
	}
	if dryRun && len(all) > 0 {
		return adminPending(name, len(all))
	}
	return nil
}
