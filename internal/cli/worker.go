package cli

import (
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/carverauto/agentboard/internal/worker"
	"github.com/spf13/cobra"
)

func (c *commands) workerCommands() *cobra.Command {
	home, _ := os.UserHomeDir()
	configPath := env("AGENTBOARD_WORKER_CONFIG", filepath.Join(home, ".config", "agentboard", "worker", "config.json"))
	id, session, generation := "", "", ""
	group := &cobra.Command{Use: "worker", Short: "Explicit supervised API-only worker runtime"}
	group.PersistentFlags().StringVar(&configPath, "config", configPath, "Protected versioned worker config path")
	group.PersistentFlags().StringVar(&id, "worker-id", "", "Configured stable worker ID")
	group.PersistentFlags().StringVar(&session, "session-id", "", "Require this native session identity")
	group.PersistentFlags().StringVar(&generation, "adapter-generation", "", "Require this native adapter generation")
	load := func() (worker.Config, worker.Binding, error) {
		cfg, err := worker.Load(configPath)
		if err != nil {
			return cfg, worker.Binding{}, err
		}
		wanted := id
		if wanted == "" {
			wanted = c.cfg.Actor.ID
		}
		if wanted == "" && len(cfg.Bindings) == 1 {
			wanted = cfg.Bindings[0].Agent
		}
		for _, b := range cfg.Bindings {
			if b.Agent == wanted {
				if (session != "" && session != b.Session) || (generation != "" && generation != b.Generation) {
					return cfg, b, errors.New("native session generation does not match binding")
				}
				return cfg, b, nil
			}
		}
		return cfg, worker.Binding{}, errors.New("select a configured --worker-id")
	}
	output := func(cmd *cobra.Command, value any) error { return json.NewEncoder(cmd.OutOrStdout()).Encode(value) }
	group.AddCommand(&cobra.Command{Use: "serve", Short: "Serve independent bindings; stdout is bounded JSON health", Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, _ []string) error {
		cfg, err := worker.Load(configPath)
		if err != nil {
			return err
		}
		return worker.Serve(cmd.Context(), cfg, cmd.OutOrStdout())
	}})
	group.AddCommand(&cobra.Command{Use: "check-in", Short: "Read all durable responsibilities/obligations/pending pages; no receipt", Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, _ []string) error {
		cfg, b, err := load()
		if err != nil {
			return err
		}
		a, err := worker.OpenAPI(cfg, b, true)
		if err != nil {
			return err
		}
		defer a.Close()
		value, err := a.CheckIn(cmd.Context())
		if err != nil {
			return err
		}
		return output(cmd, value)
	}})
	var ids []string
	kind, key := "handled", ""
	ack := &cobra.Command{Use: "ack", Short: "Explicit exact received/handled receipt for current frozen attempt", Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, _ []string) error {
		cfg, b, err := load()
		if err != nil {
			return err
		}
		raw, err := worker.Ack(cmd.Context(), cfg, b, kind, ids, key)
		if err != nil {
			return err
		}
		return output(cmd, raw)
	}}
	ack.Flags().StringSliceVar(&ids, "ids", nil, "Exact delivery IDs, comma separated")
	ack.Flags().StringVar(&kind, "kind", kind, "received or handled")
	ack.Flags().StringVar(&key, "key", "", "Stable receipt idempotency key (required)")
	group.AddCommand(ack)
	group.AddCommand(&cobra.Command{Use: "doctor", Short: "Verify live API protocol/scope, adapter identity and receipt path", Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, _ []string) error {
		cfg, b, err := load()
		if err != nil {
			return err
		}
		a, err := worker.OpenAPI(cfg, b, false)
		if err != nil {
			return err
		}
		defer a.Close()
		raw, err := a.Call(cmd.Context(), http.MethodGet, "doctor", nil, nil)
		if err != nil {
			return err
		}
		receipt, err := worker.OpenAPI(cfg, b, true)
		if err != nil {
			return err
		}
		defer receipt.Close()
		if _, err = worker.CurrentState(cmd.Context(), receipt, b); err != nil {
			return err
		}
		p, err := worker.VerifyAdapter(cmd.Context(), b)
		if err != nil {
			_ = output(cmd, map[string]any{"protocol_revision": worker.Protocol, "server": raw, "adapter_supported": false, "reason": err.Error()})
			return err
		}
		return output(cmd, map[string]any{"protocol_revision": worker.Protocol, "server": raw, "adapter": p, "receipt_path": "verified API read; exact handling remains explicit"})
	}})
	bindKey := ""
	bind := &cobra.Command{Use: "bind", Short: "Explicit verified session rebind; save epoch receipt capability without printing it", Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, _ []string) error {
		if bindKey == "" {
			return errors.New("bind requires a stable --key")
		}
		cfg, b, err := load()
		if err != nil {
			return err
		}
		p, err := worker.VerifyAdapter(cmd.Context(), b)
		if err != nil {
			return err
		}
		a, err := worker.OpenAPI(cfg, b, false)
		if err != nil {
			return err
		}
		defer a.Close()
		raw, err := a.Call(cmd.Context(), http.MethodPost, "bind", nil, map[string]any{"idempotency_key": bindKey, "expected_epoch": b.Epoch, "host_id": b.Host, "session_id": b.Session, "pane_id": b.Generation, "adapter": b.Adapter, "adapter_version": p.Version, "capabilities": p.Capabilities})
		if err != nil {
			return err
		}
		var result struct {
			Binding struct {
				Epoch   int64  `json:"binding_epoch"`
				Session string `json:"session_id"`
				Pane    string `json:"pane_id"`
			} `json:"binding"`
			Token string `json:"receipt_token"`
		}
		if json.Unmarshal(raw, &result) != nil || result.Binding.Epoch <= b.Epoch || result.Binding.Session != b.Session || result.Binding.Pane != b.Generation || result.Token == "" || strings.ContainsAny(result.Token, "\r\n\t ") {
			return errors.New("bind result missing new protected capability; inspect state and explicitly rebind, never repeat uncertain bind blindly")
		}
		// A successful capability response is never emitted to stdout or diagnostics.
		if err := worker.SaveCapability(b.TokenFile+".receipt", result.Token); err != nil {
			return err
		}
		for i := range cfg.Bindings {
			if cfg.Bindings[i].Agent == b.Agent {
				cfg.Bindings[i].Epoch = result.Binding.Epoch
			}
		}
		if err := worker.WriteProtected(configPath, cfg); err != nil {
			return err
		}
		return output(cmd, map[string]any{"protocol_revision": worker.Protocol, "worker_id": b.Agent, "binding_epoch": result.Binding.Epoch, "receipt_capability": "saved to protected reference", "adapter": p})
	}}
	bind.Flags().StringVar(&bindKey, "key", "", "Stable explicit binding idempotency key")
	group.AddCommand(bind)
	for _, action := range []string{"pause", "resume", "unbind"} {
		group.AddCommand(&cobra.Command{Use: action, Short: "Durable epoch-fenced " + action + "; pending work retained", Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, _ []string) error {
			cfg, b, err := load()
			if err != nil {
				return err
			}
			a, err := worker.OpenAPI(cfg, b, false)
			if err != nil {
				return err
			}
			defer a.Close()
			raw, err := a.Call(cmd.Context(), http.MethodPost, action, nil, map[string]any{"binding_epoch": b.Epoch})
			if err != nil {
				return err
			}
			return output(cmd, raw)
		}})
	}
	for _, action := range []string{"install", "uninstall"} {
		apply := false
		platform := runtime.GOOS
		installHome := home
		command := &cobra.Command{Use: action, Short: "Preview owned supervision files; --apply writes files without activation", Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, _ []string) error {
			var p worker.InstallPlan
			var err error
			if action == "install" {
				p, err = worker.Install(installHome, configPath, platform, apply)
			} else {
				p, err = worker.Uninstall(installHome, configPath, platform, apply)
			}
			if err != nil {
				return err
			}
			return output(cmd, p)
		}}
		command.Flags().BoolVar(&apply, "apply", false, "Apply reviewed owned-file changes (never starts/stops services)")
		command.Flags().StringVar(&platform, "platform", platform, "darwin or linux service profile")
		command.Flags().StringVar(&installHome, "home", home, "Owned home for install; supports disposable conformance")
		group.AddCommand(command)
	}
	return group
}
