package cli

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"

	"github.com/carverauto/agentboard/internal/worker"
	"github.com/spf13/cobra"
)

func (c *commands) hostCommands() *cobra.Command {
	home, _ := os.UserHomeDir()
	path := filepath.Join(home, ".config", "agentboard", "host", "config.json")
	id, cursor := "", ""
	dryRun := true
	group := &cobra.Command{Use: "host", Short: "Scoped wake shadow inspection; native activation remains disabled"}
	group.PersistentFlags().StringVar(&path, "config", path, "Protected worker-compatible host manifest with repository scopes")
	run := &cobra.Command{Use: "run", Short: "Poll bounded shadow pages with shared worker custody and backoff", Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, _ []string) error {
		if !dryRun {
			return errors.New("native host delivery requires the unimplemented #150 admission boundary and separate captain activation; use dry-run")
		}
		cfg, err := worker.Load(path)
		if err != nil {
			return err
		}
		return worker.ServeHost(cmd.Context(), cfg, cmd.OutOrStdout())
	}}
	run.Flags().BoolVar(&dryRun, "dry-run", true, "Inspect only; disabling dry-run is unsupported")
	group.AddCommand(run)
	inspect := &cobra.Command{Use: "inspect", Short: "Inspect one scoped wake page without consuming sources or journals", Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, _ []string) error {
		cfg, err := worker.Load(path)
		if err != nil {
			return err
		}
		for _, b := range cfg.Bindings {
			if b.Agent == id || (id == "" && len(cfg.Bindings) == 1) {
				value, err := worker.InspectWake(cmd.Context(), cfg, b, cursor)
				if err != nil {
					return err
				}
				return json.NewEncoder(cmd.OutOrStdout()).Encode(value)
			}
		}
		return errors.New("select a configured --worker-id")
	}}
	inspect.Flags().StringVar(&id, "worker-id", "", "Exact configured worker binding")
	inspect.Flags().StringVar(&cursor, "cursor", "", "Bounded UUID page cursor; no acknowledgement")
	group.AddCommand(inspect)
	platform, installHome := runtime.GOOS, home
	preview := &cobra.Command{Use: "install", Short: "Preview an owned dry-run supervision file; never write or load it", Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, _ []string) error {
		value, err := worker.HostSupervisionPreview(installHome, path, platform)
		if err != nil {
			return err
		}
		return json.NewEncoder(cmd.OutOrStdout()).Encode(value)
	}}
	preview.Flags().StringVar(&platform, "platform", platform, "linux systemd or darwin launchd")
	preview.Flags().StringVar(&installHome, "home", home, "Local preview home; no installation")
	group.AddCommand(preview)
	return group
}
