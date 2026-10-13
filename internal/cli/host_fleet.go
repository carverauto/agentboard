package cli

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/carverauto/agentboard/internal/client"
	"github.com/carverauto/agentboard/internal/config"
	"github.com/carverauto/agentboard/internal/seatops"
	"github.com/carverauto/agentboard/internal/worker"
	"github.com/spf13/cobra"
)

func (c *commands) hostFleetCommand() *cobra.Command {
	group := &cobra.Command{Use: "fleet", Short: "Seat supply: launch this host's live fleet launch intents"}
	var hostID, tokenFile, harnesses, journal string
	var interval, leaseWait time.Duration
	var once bool
	serve := &cobra.Command{Use: "serve", Args: cobra.NoArgs,
		Short: "Reserve this host's live launch intents and open each seat in a new Herdr tab",
		Long: `Serve polls the board for launch intents bound to --host-id, which a
captain enrolled with ` + "`agentboard fleet host set`" + `. Each pass it reconciles the
intents this host holds against its step journal, reports launched seats whose
pane is gone as closed, then reserves pending intents up to the host's launch
cap (0 by default, so nothing launches until the captain raises it) and starts
each one with the same path as ` + "`seat spawn`" + `: a new tab labelled with the seat's
agent ID running scripts/launch-seat and the harness argv from the host-local
allowlist. Nothing it runs comes from the board. Run it under launchd or
systemd; see docs/setup/fleet-host.md.`,
		RunE: func(cmd *cobra.Command, _ []string) error {
			if !config.ValidID(hostID) {
				return errors.New("--host-id must be a lowercase slug")
			}
			if os.Getenv("AGENTBOARD_URL") == "" && !cmd.Root().PersistentFlags().Changed("url") {
				return errors.New("refuses: AGENTBOARD_URL is required so launched seats reach the board")
			}
			cfg, err := seatops.LoadSpawnConfig(harnesses)
			if err != nil {
				return err
			}
			secret, err := worker.ReadProtected(tokenFile, 4096)
			if err != nil {
				return errors.New("--token-file must be a protected fleet host token file")
			}
			api, err := client.NewFleetHost(c.cfg, strings.TrimSpace(string(secret)))
			if err != nil {
				return err
			}
			defer api.Close()
			binary, err := seatTreehouseBinary(seatOpsTreehouseVersion)
			if err != nil {
				return err
			}
			supplier := seatops.Supplier{
				Server:    apiSupply{api: api, host: hostID},
				Host:      seatops.HerdrCLI{Bin: os.Getenv("AGENTBOARD_HERDR_BIN")},
				Leases:    treehouseLeases{binary: binary},
				Config:    cfg,
				BoardURL:  c.cfg.URL,
				Journal:   journal,
				LeaseWait: leaseWait,
			}
			return serveSupply(cmd, supplier, interval, once)
		}}
	serve.Flags().StringVar(&hostID, "host-id", "", "Enrolled host ID; matches desired_host_id in fleet loadouts")
	serve.Flags().StringVar(&tokenFile, "token-file", "", "Protected file holding this host's token from `fleet host set`")
	serve.Flags().StringVar(&harnesses, "harnesses", seatops.DefaultSpawnConfigPath(), "Absolute path of the host-local harness allowlist")
	serve.Flags().StringVar(&journal, "journal", seatops.DefaultSupplyJournal(), "Launch step journal used for restart reconciliation")
	serve.Flags().DurationVar(&interval, "interval", 30*time.Second, "Time between passes")
	serve.Flags().DurationVar(&leaseWait, "lease-wait", time.Minute, "How long a new launch waits for its Treehouse lease before reporting uncertain")
	serve.Flags().BoolVar(&once, "once", false, "Run one pass and exit")
	for _, name := range []string{"host-id", "token-file"} {
		_ = serve.MarkFlagRequired(name)
	}
	group.AddCommand(serve)
	return group
}

// serveSupply runs passes until the context ends. A failed pass is printed and
// retried on the next interval; with --once its error is returned.
func serveSupply(cmd *cobra.Command, supplier seatops.Supplier, interval time.Duration, once bool) error {
	if interval < time.Second {
		return errors.New("--interval must be at least 1s")
	}
	encoder := json.NewEncoder(cmd.OutOrStdout())
	for {
		report, err := supplier.Tick(cmd.Context())
		switch {
		case errors.Is(err, seatops.ErrLocked):
			fmt.Fprintln(cmd.ErrOrStderr(), "skip: "+err.Error())
		case err != nil && once:
			return err
		case err != nil:
			fmt.Fprintln(cmd.ErrOrStderr(), "pass failed: "+err.Error())
		default:
			if encodeErr := encoder.Encode(report); encodeErr != nil {
				return encodeErr
			}
		}
		if once {
			return nil
		}
		select {
		case <-cmd.Context().Done():
			return nil
		case <-time.After(interval):
		}
	}
}

// apiSupply is the host's view of seat supply over the HTTP API.
type apiSupply struct {
	api  *client.Client
	host string
}

func (a apiSupply) Intents(ctx context.Context) (seatops.HostIntents, error) {
	var view seatops.HostIntents
	raw, err := a.api.JSON(ctx, http.MethodGet, "fleet-hosts/"+a.host+"/launch-intents", nil, nil)
	if err != nil {
		return view, err
	}
	return view, json.Unmarshal(raw, &view)
}

func (a apiSupply) Reserve(ctx context.Context, id string) (seatops.LaunchIntent, error) {
	return a.intent(ctx, id+"/reserve", map[string]any{})
}

func (a apiSupply) Report(ctx context.Context, id string, report seatops.LaunchReport) (seatops.LaunchIntent, error) {
	return a.intent(ctx, id+"/report", report)
}

func (a apiSupply) intent(ctx context.Context, path string, payload any) (seatops.LaunchIntent, error) {
	var response struct {
		Intent seatops.LaunchIntent `json:"intent"`
	}
	raw, err := a.api.JSON(ctx, http.MethodPost, "fleet-hosts/"+a.host+"/launch-intents/"+path, nil, payload)
	if err != nil {
		return response.Intent, err
	}
	return response.Intent, json.Unmarshal(raw, &response)
}
