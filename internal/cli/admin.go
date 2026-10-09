package cli

// Idempotent `agentboard admin` operator subcommands (GH #138, OpenSpec
// add-admin-cli). Every mutating subcommand converges: it reads current
// state, diffs, applies only the diff, and reports the shared JSON envelope
// {command, dry_run, diff, result} under --json. Exit codes: dry-run 0 = no
// changes, 2 = pending, 1 = error; apply 0 = converged, 1 = error,
// 2 = runtime setup incomplete, 3 = rolled back. No token or secret value is ever written to stdout,
// stderr, logs, JSON output, or board records.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"

	"github.com/carverauto/agentboard/internal/client"
	"github.com/carverauto/agentboard/internal/config"
	"github.com/carverauto/agentboard/internal/worker"
	"github.com/spf13/cobra"
)

// adminExit carries a process exit code through cli.ExitCode.
type adminExit struct {
	code int
	msg  string
}

func (e *adminExit) Error() string { return e.msg }
func (e *adminExit) ExitCode() int { return e.code }

// adminFailure keeps an operation's diagnostic cause while enforcing the
// admin exit contract instead of the ordinary CLI's default invalid-input 2.
type adminFailure struct{ cause error }

func (e *adminFailure) Error() string { return e.cause.Error() }
func (e *adminFailure) Unwrap() error { return e.cause }
func (e *adminFailure) ExitCode() int { return 1 }

// Argument/flag parsing still belongs to Cobra. Once an admin operation starts,
// only explicit adminExit results may report pending changes or rollback.
func adminErrorBoundary(cmd *cobra.Command) {
	if run := cmd.RunE; run != nil {
		cmd.RunE = func(cmd *cobra.Command, args []string) error {
			err := run(cmd, args)
			if err == nil {
				return nil
			}
			var status *adminExit
			if errors.As(err, &status) {
				return err
			}
			return &adminFailure{cause: err}
		}
	}
	for _, child := range cmd.Commands() {
		adminErrorBoundary(child)
	}
}

// adminDiff is one current-vs-desired entry. Values must never carry secrets:
// secret state is reported with markers only (absent/present/created).
type adminDiff struct {
	Scope   string `json:"scope"`
	Field   string `json:"field"`
	Current string `json:"current"`
	Desired string `json:"desired"`
}

func (c *commands) adminCommands() *cobra.Command {
	group := &cobra.Command{Use: "admin", Short: "Idempotent operator setup: workers, config, safe rollouts"}
	group.AddCommand(c.adminWorker(), c.adminAgent(), c.adminConfig(), c.adminRollout(), c.adminDoctor(), c.adminApply())
	adminErrorBoundary(group)
	return group
}

// adminReport prints the shared envelope. Human output is one line per diff
// plus a result line; --json emits the full envelope.
func (c *commands) adminReport(cmd *cobra.Command, name string, dryRun bool, diff []adminDiff, result map[string]any) error {
	if c.json {
		return json.NewEncoder(cmd.OutOrStdout()).Encode(map[string]any{
			"command": name,
			"dry_run": dryRun,
			"diff":    diff,
			"result":  result,
		})
	}
	if pending, ok := result["pending_steps"].([]string); ok && len(pending) > 0 {
		for _, d := range diff {
			fmt.Fprintf(cmd.OutOrStdout(), "%s: %s %s: %s -> %s\n", name, d.Scope, d.Field, d.Current, d.Desired)
		}
		if dryRun {
			fmt.Fprintf(cmd.OutOrStdout(), "%s: setup planned; runtime readiness unverified\n", name)
		} else {
			fmt.Fprintf(cmd.OutOrStdout(), "%s: setup prepared; runtime readiness unverified\n", name)
		}
		for _, step := range pending {
			fmt.Fprintf(cmd.OutOrStdout(), "%s: pending: %s\n", name, step)
		}
		return nil
	}
	if len(diff) == 0 {
		fmt.Fprintf(cmd.OutOrStdout(), "%s: converged, no changes\n", name)
		return nil
	}
	for _, d := range diff {
		fmt.Fprintf(cmd.OutOrStdout(), "%s: %s %s: %s -> %s\n", name, d.Scope, d.Field, d.Current, d.Desired)
	}
	return nil
}

// adminPending returns the exit-2 pending-changes error for dry-run mode.
func adminPending(name string, n int) error {
	return &adminExit{code: 2, msg: fmt.Sprintf("%s: %d change(s) pending; rerun without --dry-run to apply", name, n)}
}

// openCaptain returns a board client bound to the operator's captain
// capability file, after the same API-compatibility gate as c.request.
func (c *commands) openCaptain(ctx context.Context) (*client.Client, error) {
	if err := c.cfg.Actor.Validate(); err != nil {
		return nil, err
	}
	secret, err := worker.ReadProtected(os.Getenv("AGENTBOARD_CAPTAIN_TOKEN_FILE"), 4096)
	if err != nil {
		return nil, errors.New("AGENTBOARD_CAPTAIN_TOKEN_FILE must be a protected captain capability file")
	}
	api, err := client.NewCaptain(c.cfg, strings.TrimSpace(string(secret)))
	if err != nil {
		return nil, err
	}
	raw, err := api.JSON(ctx, http.MethodGet, "meta", nil, nil)
	if err != nil {
		api.Close()
		return nil, err
	}
	var meta struct {
		API    int `json:"api_version"`
		Schema int `json:"schema_version"`
	}
	if json.Unmarshal(raw, &meta) != nil || meta.API != 1 || meta.Schema < 1 {
		api.Close()
		return nil, &client.Error{Code: "schema_unavailable", Message: "API or schema is incompatible; an operator must run release migrations"}
	}
	return api, nil
}

// preflightToken checks custody before a one-shot provisioning response can be
// issued. It is read-only, including in plan mode. Presence alone is never
// proof that a capability belongs to an enrollment.
func preflightToken(path string, rotate bool) (bool, error) {
	if path == "" {
		return false, errors.New("--token-file is required; credentials are never printed")
	}
	parent, err := os.Lstat(filepath.Dir(path))
	if err != nil || !parent.IsDir() || parent.Mode()&os.ModeSymlink != 0 || parent.Mode().Perm()&0022 != 0 || parent.Mode().Perm()&0300 != 0300 {
		return false, errors.New("credential parent directory must exist and must not be linked or group/world-writable")
	}
	owner, ok := parent.Sys().(*syscall.Stat_t)
	if !ok || int(owner.Uid) != os.Getuid() {
		return false, errors.New("credential parent directory must be owned by the current user")
	}
	_, err = os.Lstat(path)
	if os.IsNotExist(err) {
		return false, nil
	}
	if err != nil {
		return false, errors.New("cannot inspect credential output path")
	}
	data, err := worker.ReadProtected(path, 4096)
	if err != nil {
		return false, errors.New("existing credential file must be owned, regular and protected; inspect it before retrying")
	}
	token := strings.TrimSpace(string(data))
	if !rotate && (len(token) < 32 || len(token) > 256 || strings.ContainsAny(token, "\r\n\t ")) {
		return false, errors.New("existing credential file is invalid; inspect it before using --rotate")
	}
	return true, nil
}

func enrollmentPending(name string) error {
	return &adminExit{code: 2, msg: name + ": runtime readiness unverified; complete the reported explicit bind, doctor and activation steps"}
}

// writeProtectedToken atomically creates path with mode 0600 holding token.
// It refuses to overwrite without rotate, refuses group/world-writable
// parents, and validates the token shape before writing.
func writeProtectedToken(path, token string, rotate bool) error {
	if strings.ContainsAny(token, "\r\n\t ") || len(token) < 32 || len(token) > 256 {
		return errors.New("invalid issued credential; inspect credential metadata before retrying")
	}
	parent := filepath.Dir(path)
	fi, err := os.Stat(parent)
	if err != nil || !fi.IsDir() {
		return errors.New("credential parent directory must exist; create it first with owner-only permissions")
	}
	if fi.Mode().Perm()&0o022 != 0 {
		return errors.New("credential parent directory must not be group- or world-writable")
	}
	if _, err := os.Lstat(path); err == nil {
		if !rotate {
			return errors.New("credential file exists; rerun with --rotate to replace it")
		}
		if err := os.Remove(path); err != nil {
			return errors.New("cannot replace existing credential file")
		}
	} else if !os.IsNotExist(err) {
		return errors.New("cannot inspect credential output path")
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return errors.New("credential output path must name a new protected file")
	}
	done := false
	defer func() {
		f.Close()
		if !done {
			os.Remove(path)
		}
	}()
	if err := f.Chmod(0600); err != nil {
		return errors.New("cannot protect credential output file")
	}
	if _, err := f.WriteString(token + "\n"); err != nil {
		return errors.New("credential file write failed; inspect credential metadata before retrying")
	}
	if err := f.Sync(); err != nil {
		return errors.New("credential file sync failed; inspect credential metadata before retrying")
	}
	if err := f.Close(); err != nil {
		return errors.New("credential file close failed; inspect credential metadata before retrying")
	}
	done = true
	return nil
}

func adminIDArgs(cmd *cobra.Command, args []string) error {
	if err := cobra.ExactArgs(1)(cmd, args); err != nil {
		return err
	}
	if !config.ValidID(args[0]) {
		return errors.New("ID must be a lowercase agent/worker slug")
	}
	return nil
}

func (c *commands) adminWorker() *cobra.Command {
	group := &cobra.Command{Use: "worker", Short: "Idempotent worker identity lifecycle"}
	group.AddCommand(c.adminWorkerCreate(), c.adminWorkerEnroll(), c.adminWorkerRevoke())
	return group
}

type provisionResult struct {
	Worker     json.RawMessage `json:"worker"`
	HostToken  string          `json:"host_token"`
	Idempotent bool            `json:"idempotent"`
}

func (c *commands) provisionEnsure(ctx context.Context, api *client.Client, id, host string, repos []string, model, harness, key string) (*provisionResult, error) {
	raw, err := api.WorkerControl(ctx, "provision", "", map[string]any{
		"worker_id":       id,
		"host_id":         host,
		"idempotency_key": key,
		"repos":           repos,
		"model":           model,
		"harness":         harness,
	})
	if err != nil {
		return nil, err
	}
	var res provisionResult
	if json.Unmarshal(raw, &res) != nil {
		return nil, errors.New("invalid provision response")
	}
	return &res, nil
}

func (c *commands) adminWorkerCreate() *cobra.Command {
	tokenFile, host, model, harness := "", "", "", ""
	var repos []string
	rotate, dryRun := false, false
	cmd := &cobra.Command{Use: "create WORKER_ID", Short: "Create-or-reuse a worker identity; token goes only to a 0600 file", Args: adminIDArgs, RunE: func(cmd *cobra.Command, args []string) error {
		id := args[0]
		if tokenFile == "" {
			return errors.New("--token-file is required; credentials are never printed")
		}
		if len(repos) < 1 {
			return errors.New("at least one --repo is required")
		}
		if model == "" {
			model = c.cfg.Actor.Model
		}
		if harness == "" {
			harness = c.cfg.Actor.Harness
		}
		if host == "" {
			host, _ = os.Hostname()
		}
		key := "admin/" + id + "/" + host
		if rotate {
			key = fmt.Sprintf("admin/%s/%s/%d", id, host, time.Now().UnixNano())
		}
		diff, result, err := c.convergeWorkerCreate(cmd.Context(), createParams{
			id: id, host: host, repos: repos, model: model, harness: harness,
			key: key, tokenFile: tokenFile, rotate: rotate,
		}, dryRun)
		if err != nil {
			return err
		}
		if err := c.adminReport(cmd, "admin worker create", dryRun, diff, result); err != nil {
			return err
		}
		if dryRun && len(diff) > 0 {
			return adminPending("admin worker create", len(diff))
		}
		return nil
	}}
	cmd.Flags().StringVar(&tokenFile, "token-file", "", "New 0600 credential output file")
	cmd.Flags().StringVar(&host, "host", "", "Worker host scope (default: local hostname)")
	cmd.Flags().StringArrayVar(&repos, "repo", nil, "Repository scope owner/repo (repeatable, at least one)")
	cmd.Flags().StringVar(&model, "model", "", "Worker model scope (default: AGENTBOARD_MODEL)")
	cmd.Flags().StringVar(&harness, "harness", "", "Worker harness scope (default: AGENTBOARD_HARNESS)")
	cmd.Flags().BoolVar(&rotate, "rotate", false, "Revoke and re-provision with a fresh token")
	cmd.Flags().BoolVar(&dryRun, "dry-run", false, "Show the diff without writing anything")
	cmd.Flags().BoolVar(&dryRun, "plan", false, "Alias for --dry-run")
	return cmd
}

func (c *commands) adminWorkerEnroll() *cobra.Command {
	configPath, host, model, harness, home, platform := "", "", "", "", "", ""
	var repos []string
	tokenFile := ""
	dryRun := false
	cmd := &cobra.Command{Use: "enroll WORKER_ID", Short: "Prepare scoped identity and supervision; report explicit runtime steps", Args: adminIDArgs, RunE: func(cmd *cobra.Command, args []string) error {
		id := args[0]
		if len(repos) < 1 {
			return errors.New("at least one --repo is required")
		}
		if model == "" {
			model = c.cfg.Actor.Model
		}
		if harness == "" {
			harness = c.cfg.Actor.Harness
		}
		if host == "" {
			host, _ = os.Hostname()
		}
		if platform == "" {
			platform = runtime.GOOS
		}
		if configPath == "" {
			hd, _ := os.UserHomeDir()
			configPath = filepath.Join(hd, ".config", "agentboard", "worker", "config.json")
		}
		if home == "" {
			home, _ = os.UserHomeDir()
		}
		diff, result, err := c.convergeWorkerEnroll(cmd.Context(), enrollParams{
			id: id, host: host, repos: repos, model: model, harness: harness,
			tokenFile: tokenFile, configPath: configPath, home: home, platform: platform,
		}, dryRun)
		if err != nil {
			return err
		}
		if err := c.adminReport(cmd, "admin worker enroll", dryRun, diff, result); err != nil {
			return err
		}
		if dryRun && len(diff) > 0 {
			return adminPending("admin worker enroll", len(diff))
		}
		return enrollmentPending("admin worker enroll")
	}}
	cmd.Flags().StringVar(&configPath, "config", "", "Protected worker config path")
	cmd.Flags().StringVar(&tokenFile, "token-file", "", "0600 host token path (default: selected worker config token_file)")
	cmd.Flags().StringVar(&host, "host", "", "Worker host scope (default: local hostname)")
	cmd.Flags().StringArrayVar(&repos, "repo", nil, "Repository scope owner/repo (repeatable, at least one)")
	cmd.Flags().StringVar(&model, "model", "", "Worker model scope (default: AGENTBOARD_MODEL)")
	cmd.Flags().StringVar(&harness, "harness", "", "Worker harness scope (default: AGENTBOARD_HARNESS)")
	cmd.Flags().StringVar(&home, "home", "", "Owned home for supervision files (default: $HOME)")
	cmd.Flags().StringVar(&platform, "platform", "", "darwin or linux service profile (default: runtime GOOS)")
	cmd.Flags().BoolVar(&dryRun, "dry-run", false, "Show the diff without writing anything")
	cmd.Flags().BoolVar(&dryRun, "plan", false, "Alias for --dry-run")
	return cmd
}

func (c *commands) adminWorkerRevoke() *cobra.Command {
	dryRun := false
	cmd := &cobra.Command{Use: "revoke WORKER_ID", Short: "Revoke a worker identity; repeat-safe", Args: adminIDArgs, RunE: func(cmd *cobra.Command, args []string) error {
		id := args[0]
		diff, result, err := c.convergeWorkerRevoke(cmd.Context(), id, dryRun)
		if err != nil {
			return err
		}
		if err := c.adminReport(cmd, "admin worker revoke", dryRun, diff, result); err != nil {
			return err
		}
		if dryRun && len(diff) > 0 {
			return adminPending("admin worker revoke", len(diff))
		}
		return nil
	}}
	cmd.Flags().BoolVar(&dryRun, "dry-run", false, "Show the diff without writing anything")
	cmd.Flags().BoolVar(&dryRun, "plan", false, "Alias for --dry-run")
	return cmd
}

func (c *commands) adminAgent() *cobra.Command {
	group := &cobra.Command{Use: "agent", Short: "Wrapped agent registration with state report"}
	harness, model := "", ""
	dryRun := false
	cmd := &cobra.Command{Use: "register AGENT_ID", Short: "Register this agent and report bot/availability state", Args: adminIDArgs, RunE: func(cmd *cobra.Command, args []string) error {
		id := args[0]
		diff, result, err := c.convergeAgentRegister(cmd.Context(), id, harness, model, dryRun)
		if err != nil {
			return err
		}
		if err := c.adminReport(cmd, "admin agent register", dryRun, diff, result); err != nil {
			return err
		}
		if dryRun && len(diff) > 0 {
			return adminPending("admin agent register", len(diff))
		}
		return nil
	}}
	cmd.Flags().StringVar(&harness, "harness", "", "Assert this harness identity")
	cmd.Flags().StringVar(&model, "model", "", "Assert this model identity")
	cmd.Flags().BoolVar(&dryRun, "dry-run", false, "Show the diff without writing anything")
	cmd.Flags().BoolVar(&dryRun, "plan", false, "Alias for --dry-run")
	group.AddCommand(cmd)
	return group
}
