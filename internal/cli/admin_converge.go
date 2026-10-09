package cli

// Shared converge functions for `admin` subcommands and `admin apply -f`.
// Both surfaces call these; there is no separate mutation logic.

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"syscall"

	"github.com/carverauto/agentboard/internal/client"
	"github.com/carverauto/agentboard/internal/worker"
)

func sha256Hex(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

type createParams struct {
	id, host  string
	repos     []string
	model     string
	harness   string
	key       string
	tokenFile string
	rotate    bool
}

// verifyHostCapability performs a scoped read before reusing any existing file.
// It never provisions, binds, rotates, acknowledges or updates host health.
func verifyHostCapability(ctx context.Context, cfg worker.Config, b worker.Binding, repos []string) error {
	api, err := worker.OpenAPI(cfg, b, false)
	if err != nil {
		return errors.New("host capability unavailable; inspect the protected file before using --rotate")
	}
	defer api.Close()
	raw, err := api.Call(ctx, http.MethodGet, "doctor", nil, nil)
	if err != nil {
		return errors.New("cannot verify existing host capability; inspect enrollment before using --rotate")
	}
	var state struct {
		Scope  string `json:"scope"`
		Worker struct {
			ID      string   `json:"id"`
			Host    string   `json:"host_id"`
			Model   string   `json:"model"`
			Harness string   `json:"harness"`
			Repos   []string `json:"repos"`
			Revoked bool     `json:"revoked"`
		} `json:"worker"`
	}
	if json.Unmarshal(raw, &state) != nil {
		return errors.New("invalid worker state; existing capability not verified")
	}
	wanted := slices.Clone(repos)
	slices.Sort(wanted)
	wanted = slices.Compact(wanted)
	slices.Sort(state.Worker.Repos)
	w := state.Worker
	if state.Scope != "host" || w.ID != b.Agent || w.Host != b.Host || w.Model != b.Model || w.Harness != b.Harness || w.Revoked || !slices.Equal(w.Repos, wanted) {
		return errors.New("existing host capability does not match requested worker scope; inspect enrollment before retrying")
	}
	return nil
}

func (c *commands) convergeWorkerCreate(ctx context.Context, p createParams, dryRun bool) ([]adminDiff, map[string]any, error) {
	fileExists, err := preflightToken(p.tokenFile, p.rotate)
	if err != nil {
		return nil, nil, err
	}
	diff := []adminDiff{{Scope: "worker", Field: "identity:" + p.id, Current: "unverified", Desired: "provisioned with verified capability"}}
	if dryRun {
		// Local-only plans cannot establish server convergence from a file.
		return diff, map[string]any{"worker_id": p.id, "converged": false, "capability_verified": false}, nil
	}
	api, err := c.openCaptain(ctx)
	if err != nil {
		return nil, nil, err
	}
	defer api.Close()
	if fileExists && !p.rotate {
		err := verifyHostCapability(ctx, worker.Config{URL: c.cfg.URL, CAFile: c.cfg.CAFile, AccessServiceTokenFile: c.cfg.AccessServiceTokenFile},
			worker.Binding{Agent: p.id, Host: p.host, Model: p.model, Harness: p.harness, TokenFile: p.tokenFile}, p.repos)
		if err != nil {
			return nil, nil, err
		}
		return nil, map[string]any{"worker_id": p.id, "converged": true, "capability_verified": true}, nil
	}
	if p.rotate {
		scopeVerified := false
		if fileExists {
			// Prove retained scope before revoke; the server rejects scope changes
			// only at provision time, which is too late to protect a live worker.
			scopeVerified = verifyHostCapability(ctx, worker.Config{URL: c.cfg.URL, CAFile: c.cfg.CAFile, AccessServiceTokenFile: c.cfg.AccessServiceTokenFile},
				worker.Binding{Agent: p.id, Host: p.host, Model: p.model, Harness: p.harness, TokenFile: p.tokenFile}, p.repos) == nil
		}
		if !scopeVerified {
			// Missing-token recovery can replay only the original stable admin
			// key. A conflicting/unknown live enrollment fails without revoking.
			prior, err := c.provisionEnsure(ctx, api, p.id, p.host, p.repos, p.model, p.harness, "admin/"+p.id+"/"+p.host)
			if err != nil {
				return nil, nil, errors.New("rotation refused before revocation: original enrollment scope could not be verified")
			}
			if !prior.Idempotent {
				if err := writeProtectedToken(p.tokenFile, prior.HostToken, p.rotate); err != nil {
					return nil, nil, err
				}
				return diff, map[string]any{"worker_id": p.id, "token_file": p.tokenFile, "rotated": false}, nil
			}
		}
		if _, _, err := c.convergeWorkerRevoke(ctx, p.id, false); err != nil {
			return nil, nil, err
		}
	}
	res, err := c.provisionEnsure(ctx, api, p.id, p.host, p.repos, p.model, p.harness, p.key)
	if err != nil {
		return nil, nil, err
	}
	if res.Idempotent {
		return nil, nil, errors.New("identity exists but its current host capability is unavailable; inspect enrollment and rerun with --rotate")
	}
	if err := writeProtectedToken(p.tokenFile, res.HostToken, p.rotate); err != nil {
		return nil, nil, err
	}
	return diff, map[string]any{"worker_id": p.id, "token_file": p.tokenFile, "rotated": p.rotate}, nil
}

func (c *commands) convergeWorkerRevoke(ctx context.Context, id string, dryRun bool) ([]adminDiff, map[string]any, error) {
	if dryRun {
		return []adminDiff{{Scope: "worker", Field: "revoked:" + id, Current: "unknown", Desired: "true"}},
			map[string]any{"worker_id": id}, nil
	}
	api, err := c.openCaptain(ctx)
	if err != nil {
		return nil, nil, err
	}
	defer api.Close()
	_, err = api.WorkerControl(ctx, "revoke", id, map[string]any{})
	if err != nil {
		var cerr *client.Error
		if errors.As(err, &cerr) && (cerr.Code == "not_found" || strings.Contains(cerr.Message, "not enrolled")) {
			return nil, map[string]any{"worker_id": id, "converged": true}, nil
		}
		return nil, nil, err
	}
	return []adminDiff{{Scope: "worker", Field: "revoked:" + id, Current: "false", Desired: "true"}},
		map[string]any{"worker_id": id, "revoked": true}, nil
}

type enrollParams struct {
	id, host   string
	repos      []string
	model      string
	harness    string
	tokenFile  string
	configPath string
	home       string
	platform   string
}

func supervisionDiff(home, configPath, platform string) ([]adminDiff, worker.InstallPlan, error) {
	plan, err := worker.Install(home, configPath, platform, false)
	if err != nil {
		return nil, plan, err
	}
	// Preview checks file ownership, but Install's writes also require safe
	// output directories. Check existing ancestors before issuing a host token.
	for _, f := range plan.Files {
		for dir := filepath.Dir(f.Path); ; dir = filepath.Dir(dir) {
			info, err := os.Lstat(dir)
			if err == nil {
				owner, ok := info.Sys().(*syscall.Stat_t)
				manifestDir := filepath.Join(home, ".config", "agentboard", "worker")
				if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm()&0022 != 0 || info.Mode().Perm()&0300 != 0300 || (dir == manifestDir && info.Mode().Perm()&0077 != 0) || !ok || int(owner.Uid) != os.Getuid() {
					return nil, plan, errors.New("unsafe supervision output directory; inspect ownership and permissions before enrollment")
				}
				if dir == filepath.Clean(home) || !strings.HasPrefix(dir, filepath.Clean(home)+string(os.PathSeparator)) {
					break
				}
			} else if !os.IsNotExist(err) {
				return nil, plan, errors.New("cannot inspect supervision output directory")
			}
			if dir == filepath.Dir(dir) {
				break
			}
		}
	}
	diff := []adminDiff{}
	for _, f := range plan.Files {
		existing, err := os.ReadFile(f.Path)
		if err == nil && sha256Hex(existing) == f.Hash {
			continue
		}
		current := "absent"
		if err == nil {
			current = "drifted"
		}
		diff = append(diff, adminDiff{Scope: "supervision", Field: "file", Current: current, Desired: f.Path})
	}
	return diff, plan, nil
}

func (c *commands) convergeWorkerEnroll(ctx context.Context, p enrollParams, dryRun bool) ([]adminDiff, map[string]any, error) {
	// Validate all local prerequisites before a one-shot host token is issued.
	cfg, err := worker.Load(p.configPath)
	if err != nil {
		return nil, nil, errors.New("enrollment requires an existing valid protected worker config: " + err.Error())
	}
	var binding *worker.Binding
	for i := range cfg.Bindings {
		if cfg.Bindings[i].Agent == p.id {
			binding = &cfg.Bindings[i]
			break
		}
	}
	if binding == nil || binding.Host != p.host || binding.Model != p.model || binding.Harness != p.harness || strings.TrimRight(cfg.URL, "/") != strings.TrimRight(c.cfg.URL, "/") {
		return nil, nil, errors.New("worker config must match the requested worker, host, model, harness and board URL")
	}
	if p.tokenFile == "" {
		p.tokenFile = binding.TokenFile
	}
	tokenPath, err := filepath.Abs(p.tokenFile)
	if err != nil || filepath.Clean(tokenPath) != filepath.Clean(binding.TokenFile) {
		return nil, nil, errors.New("--token-file must match the protected worker config token_file")
	}
	if _, err := preflightToken(p.tokenFile, false); err != nil {
		return nil, nil, err
	}
	sdiff, plan, err := supervisionDiff(p.home, p.configPath, p.platform)
	if err != nil {
		return nil, nil, err
	}
	diff, _, err := c.convergeWorkerCreate(ctx, createParams{
		id: p.id, host: p.host, repos: p.repos, model: p.model, harness: p.harness,
		tokenFile: p.tokenFile, key: "admin/" + p.id + "/" + p.host,
	}, dryRun)
	if err != nil {
		return nil, nil, err
	}
	diff = append(diff, sdiff...)
	if !dryRun && len(sdiff) > 0 {
		if _, err := worker.Install(p.home, p.configPath, p.platform, true); err != nil {
			return nil, nil, &adminExit{code: 1, msg: "admin worker enroll: identity prepared, supervision install failed: " + err.Error()}
		}
	}
	// Native binding needs an explicit stable key and live identity proof. This
	// setup command never guesses a key, rebinds, probes a session or starts a
	// service. Keep its incomplete readiness visible, including on reruns.
	pending := []string{
		"Verify the intended native session and explicitly run worker bind with a stable --key if not already bound",
		"Run worker doctor against the protected config and selected worker",
		"Review the install reload requirements and explicitly activate supervision if needed",
	}
	return diff, map[string]any{"worker_id": p.id, "converged": false, "runtime_verified": false,
		"setup_converged": !dryRun, "pending_steps": pending, "reload_requirements": plan.Reload}, nil
}

func (c *commands) convergeAgentRegister(ctx context.Context, id, harness, model string, dryRun bool) ([]adminDiff, map[string]any, error) {
	if c.cfg.Actor.ID != "" && c.cfg.Actor.ID != id {
		return nil, nil, errors.New("AGENT_ID does not match AGENT_ID arg; refusing to register the wrong identity")
	}
	if harness != "" && c.cfg.Actor.Harness != "" && harness != c.cfg.Actor.Harness {
		return nil, nil, errors.New("--harness does not match the configured harness; refusing to register the wrong identity")
	}
	if model != "" && c.cfg.Actor.Model != "" && model != c.cfg.Actor.Model {
		return nil, nil, errors.New("--model does not match the configured model; refusing to register the wrong identity")
	}
	// Enrollment bootstraps an identity before it can receive an agent token.
	// Use the operator capability, including for authenticated dry-run reads.
	api, err := c.openCaptain(ctx)
	if err != nil {
		return nil, nil, err
	}
	defer api.Close()
	raw, err := api.JSON(ctx, http.MethodGet, "meta", nil, nil)
	if err != nil {
		return nil, nil, err
	}
	var meta struct {
		API    int `json:"api_version"`
		Schema int `json:"schema_version"`
	}
	if json.Unmarshal(raw, &meta) != nil || meta.API != 1 {
		return nil, nil, &client.Error{Code: "schema_unavailable", Message: "API or schema is incompatible"}
	}
	raw, err = api.JSON(ctx, http.MethodGet, "agents/"+id, nil, nil)
	known := err == nil
	if err != nil {
		var apiErr *client.Error
		if !errors.As(err, &apiErr) || apiErr.Code != "not_found" {
			return nil, nil, err
		}
	}
	var agent json.RawMessage
	if known {
		var env struct {
			Agent json.RawMessage `json:"agent"`
		}
		if json.Unmarshal(raw, &env) == nil {
			agent = env.Agent
		}
	}
	if dryRun {
		if known {
			return nil, map[string]any{"agent_id": id, "converged": true}, nil
		}
		return []adminDiff{{Scope: "agent", Field: "registered:" + id, Current: "absent", Desired: "present"}},
			map[string]any{"agent_id": id}, nil
	}
	created := []adminDiff{}
	if !known {
		if _, err := api.JSON(ctx, http.MethodPost, "agents/register", nil, map[string]any{}); err != nil {
			return nil, nil, err
		}
		raw, err = api.JSON(ctx, http.MethodGet, "agents/"+id, nil, nil)
		if err != nil {
			return nil, nil, err
		}
		var env struct {
			Agent json.RawMessage `json:"agent"`
		}
		if json.Unmarshal(raw, &env) == nil {
			agent = env.Agent
		}
		created = append(created, adminDiff{Scope: "agent", Field: "registered:" + id, Current: "absent", Desired: "present"})
	}
	avail, err := api.JSON(ctx, http.MethodGet, "availability", nil, nil)
	if err != nil {
		return nil, nil, err
	}
	return created, map[string]any{"agent_id": id, "agent": agent, "availability": json.RawMessage(avail), "converged": len(created) == 0}, nil
}

func convergeConfigSet(path, anchor, key, desired string, dryRun bool) ([]adminDiff, error) {
	lines, err := readTargetLines(path)
	if err != nil {
		return nil, err
	}
	current, _, _ := findEnv(lines, key)
	if current == desired {
		return nil, nil
	}
	diff := []adminDiff{{Scope: "config", Field: key, Current: current, Desired: desired}}
	if dryRun {
		return diff, nil
	}
	updated, _, err := setEnvLine(lines, anchor, key, desired)
	if err != nil {
		return nil, err
	}
	if err := writeTargetLines(path, updated); err != nil {
		return nil, &adminExit{code: 1, msg: "config write failed: " + err.Error()}
	}
	return diff, nil
}

func convergeOverlayPin(path, image, digest string, dryRun bool) ([]adminDiff, string, error) {
	lines, err := readTargetLines(path)
	if err != nil {
		return nil, "", err
	}
	_, prev, _, err := setOverlayDigest(lines, image, digest)
	if err != nil {
		return nil, "", err
	}
	if prev == digest {
		return nil, prev, nil
	}
	diff := []adminDiff{{Scope: "pin", Field: image, Current: prev, Desired: image + "@" + digest}}
	if dryRun {
		return diff, prev, nil
	}
	updated, _, _, err := setOverlayDigest(lines, image, digest)
	if err != nil {
		return nil, "", err
	}
	if err := writeTargetLines(path, updated); err != nil {
		return nil, "", &adminExit{code: 1, msg: "overlay write failed: " + err.Error()}
	}
	return diff, prev, nil
}

func convergeComposePin(path, image, pin string, dryRun bool) ([]adminDiff, string, error) {
	lines, err := readTargetLines(path)
	if err != nil {
		return nil, "", err
	}
	_, prev, _, err := setComposeImage(lines, image, pin)
	if err != nil {
		return nil, "", err
	}
	if prev == pin {
		return nil, prev, nil
	}
	diff := []adminDiff{{Scope: "pin", Field: image, Current: prev, Desired: pin}}
	if dryRun {
		return diff, prev, nil
	}
	updated, _, _, err := setComposeImage(lines, image, pin)
	if err != nil {
		return nil, "", err
	}
	if err := writeTargetLines(path, updated); err != nil {
		return nil, "", &adminExit{code: 1, msg: "compose write failed: " + err.Error()}
	}
	return diff, prev, nil
}
