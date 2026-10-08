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
	"strings"

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

func (c *commands) convergeWorkerCreate(ctx context.Context, p createParams, dryRun bool) ([]adminDiff, map[string]any, error) {
	diff := []adminDiff{{Scope: "worker", Field: "identity:" + p.id, Current: "unknown", Desired: "provisioned"}}
	_, statErr := os.Lstat(p.tokenFile)
	fileExists := statErr == nil
	if dryRun {
		// Plan mode is local-only: provision is a write on first call,
		// so an existing file counts as converged without a server read.
		if fileExists && !p.rotate {
			return nil, map[string]any{"worker_id": p.id, "converged": true}, nil
		}
		return diff, map[string]any{"worker_id": p.id}, nil
	}
	api, err := c.openCaptain(ctx)
	if err != nil {
		return nil, nil, err
	}
	defer api.Close()
	if p.rotate {
		// Rotation needs a revoked enrollment first: provision_new
		// rejects an active prior subscription.
		if _, _, rerr := c.convergeWorkerRevoke(ctx, p.id, false); rerr != nil {
			return nil, nil, rerr
		}
		res, err := c.provisionEnsure(ctx, api, p.id, p.host, p.repos, p.model, p.harness, p.key)
		if err != nil {
			return nil, nil, err
		}
		if res.Idempotent {
			if fileExists {
				return nil, map[string]any{"worker_id": p.id, "converged": true}, nil
			}
			return nil, nil, errors.New("identity exists but the token file is missing; rerun with --rotate")
		}
		if err := writeProtectedToken(p.tokenFile, res.HostToken, true); err != nil {
			return nil, nil, err
		}
		return diff, map[string]any{"worker_id": p.id, "token_file": p.tokenFile, "rotated": true}, nil
	}
	res, err := c.provisionEnsure(ctx, api, p.id, p.host, p.repos, p.model, p.harness, p.key)
	if err != nil {
		var cerr *client.Error
		if fileExists && errors.As(err, &cerr) && cerr.Code == "conflict" {
			return nil, nil, errors.New("credential file exists and the server holds a conflicting identity; rerun with --rotate")
		}
		return nil, nil, err
	}
	if res.Idempotent {
		// The server holds the identity but issues no token: only a
		// matching file counts as converged.
		if fileExists {
			return nil, map[string]any{"worker_id": p.id, "converged": true}, nil
		}
		return nil, nil, errors.New("identity exists but the token file is missing; rerun with --rotate")
	}
	if fileExists {
		// The server issued a fresh identity, so the existing file does
		// not match it. Refuse to overwrite; the operator removes the
		// file or reruns with --rotate (which revokes first).
		return nil, nil, errors.New("credential file " + p.tokenFile + " does not match the server identity; remove it and rerun, or rerun with --rotate")
	}
	if err := writeProtectedToken(p.tokenFile, res.HostToken, false); err != nil {
		return nil, nil, err
	}
	return diff, map[string]any{"worker_id": p.id, "token_file": p.tokenFile, "rotated": false}, nil
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
	_, err = api.JSON(ctx, http.MethodPost, "workers/"+id+"/revoke", nil, map[string]any{})
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
	if dryRun {
		// Plan mode never touches the server: provision is a write on
		// first call, so the ensure step is always listed and only the
		// supervision files are diffed concretely.
		diff := []adminDiff{{Scope: "worker", Field: "identity:" + p.id, Current: "unknown", Desired: "ensured"}}
		sdiff, _, err := supervisionDiff(p.home, p.configPath, p.platform)
		if err != nil {
			return nil, nil, err
		}
		return append(diff, sdiff...), map[string]any{"worker_id": p.id}, nil
	}
	diff := []adminDiff{}
	api, err := c.openCaptain(ctx)
	if err != nil {
		return nil, nil, err
	}
	defer api.Close()
	res, err := c.provisionEnsure(ctx, api, p.id, p.host, p.repos, p.model, p.harness, "admin/"+p.id+"/"+p.host)
	if err != nil {
		return nil, nil, err
	}
	if !res.Idempotent {
		diff = append(diff, adminDiff{Scope: "worker", Field: "identity:" + p.id, Current: "absent", Desired: "provisioned"})
		if res.HostToken == "" {
			return nil, nil, errors.New("invalid provision response")
		}
		if p.tokenFile == "" {
			return nil, nil, errors.New("new identity requires --token-file; credentials are never printed")
		}
		if err := writeProtectedToken(p.tokenFile, res.HostToken, false); err != nil {
			return nil, nil, err
		}
	}
	sdiff, _, err := supervisionDiff(p.home, p.configPath, p.platform)
	if err != nil {
		return nil, nil, err
	}
	diff = append(diff, sdiff...)
	if len(sdiff) > 0 {
		if _, err := worker.Install(p.home, p.configPath, p.platform, true); err != nil {
			return nil, nil, &adminExit{code: 1, msg: "admin worker enroll: supervision install failed: " + err.Error()}
		}
	}
	return diff, map[string]any{"worker_id": p.id, "converged": len(diff) == 0}, nil
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
	api, err := client.New(c.cfg)
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
