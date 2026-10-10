package cli

import (
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"regexp"
	"strings"

	"github.com/carverauto/agentboard/internal/client"
	"github.com/carverauto/agentboard/internal/worker"
	"github.com/spf13/cobra"
)

func (c *commands) agentTokens() *cobra.Command {
	group := &cobra.Command{Use: "token", Short: "Captain-managed board credentials; plaintext goes only to a protected file"}
	for _, action := range []string{"issue", "rotate", "revoke", "list"} {
		action := action
		out, scope, id := "", "", ""
		var channels []string
		cmd := &cobra.Command{Use: action + " AGENT_ID", Args: idArgs, RunE: func(cmd *cobra.Command, args []string) error {
			// Bound participant grants before touching credential files or the network.
			if err := validateCredentialGrant(action, scope, channels); err != nil {
				return err
			}
			if err := c.cfg.Actor.Validate(); err != nil {
				return err
			}
			// Refuse existing destinations before mutating any credential state.
			var destination *os.File
			complete := false
			if action == "issue" || action == "rotate" {
				if out == "" {
					return errors.New("--out is required; credentials are never printed")
				}
				if _, err := os.Lstat(out); err == nil {
					return errors.New("--out must name a new protected credential file")
				} else if !os.IsNotExist(err) {
					return errors.New("--out must name a new protected credential file")
				}
				var err error
				destination, err = os.OpenFile(out, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
				if err != nil {
					return errors.New("--out must name a new protected credential file")
				}
				if err = destination.Chmod(0600); err != nil {
					destination.Close()
					os.Remove(out)
					return errors.New("cannot protect credential output file")
				}
				held := destination
				defer func() {
					held.Close()
					if !complete {
						os.Remove(out)
					}
				}()

			}
			secret, err := worker.ReadProtected(os.Getenv("AGENTBOARD_CAPTAIN_TOKEN_FILE"), 4096)
			if err != nil {
				return errors.New("AGENTBOARD_CAPTAIN_TOKEN_FILE must be a protected captain capability file")
			}
			// Captain operations use their existing independent capability.
			cfg := c.cfg
			cfg.Token = ""
			cfg.TokenFile = ""
			api, err := client.NewCaptain(cfg, strings.TrimSpace(string(secret)))
			if err != nil {
				return err
			}
			defer api.Close()
			if scope == "coordinator_participant" {
				raw, err := api.JSON(cmd.Context(), http.MethodGet, "meta", nil, nil)
				if err != nil {
					return err
				}
				var meta struct {
					API    int `json:"api_version"`
					Schema int `json:"schema_version"`
				}
				if json.Unmarshal(raw, &meta) != nil || meta.API != 1 || meta.Schema < 39 {
					return &client.Error{Code: "schema_unavailable", Message: "Coordinator participation requires schema 39; an operator must run release migrations"}
				}
			}
			data := map[string]any{}
			if scope != "" {
				data["scope"] = scope
			}
			if len(channels) > 0 {
				data["channel_ids"] = channels
			}
			if id != "" {
				data["credential_id"] = id
			}
			path := "agents/" + args[0] + "/tokens"
			method := http.MethodGet
			if action != "list" {
				path += "/" + action
				method = http.MethodPost
			}
			raw, err := api.JSON(cmd.Context(), method, path, nil, data)
			if err != nil {
				return err
			}
			var result struct {
				Credential  json.RawMessage `json:"credential"`
				Credentials json.RawMessage `json:"credentials"`
				Token       string          `json:"token"`
			}
			if json.Unmarshal(raw, &result) != nil {
				return errors.New("invalid credential response")
			}
			if destination != nil {
				if len(result.Token) < 32 || len(result.Token) > 256 || strings.ContainsAny(result.Token, "\r\n\t ") {
					return errors.New("invalid issued credential; inspect credential metadata before retrying")
				}
				if _, err = destination.WriteString(result.Token + "\n"); err != nil {
					return errors.New("credential file write failed; inspect credential metadata before retrying")
				}
				if err = destination.Sync(); err != nil {
					return errors.New("credential file sync failed; inspect credential metadata before retrying")
				}
				if err = destination.Close(); err != nil {
					return errors.New("credential file close failed; inspect credential metadata before retrying")
				}
				complete = true
				safe := map[string]any{"credential": json.RawMessage(result.Credential), "token_file": out}
				return json.NewEncoder(cmd.OutOrStdout()).Encode(safe)
			}
			if result.Credentials == nil {
				return errors.New("invalid credential metadata response")
			}
			return json.NewEncoder(cmd.OutOrStdout()).Encode(map[string]json.RawMessage{"credentials": result.Credentials})
		}}
		cmd.Flags().StringVar(&out, "out", "", "New 0600 credential output file (issue/rotate)")
		cmd.Flags().StringVar(&scope, "scope", "", "agent, coordinator, or explicit coordinator_participant scope (issue/rotate)")
		cmd.Flags().StringArrayVar(&channels, "channel", nil, "Immutable channel grant; repeat 1–20 times with --scope coordinator_participant")
		cmd.Flags().StringVar(&id, "credential-id", "", "Credential ID to revoke; omit to revoke all for the agent")
		group.AddCommand(cmd)
	}
	return group
}

var credentialChannelID = regexp.MustCompile(`\A[A-Za-z0-9_-]{1,128}\z`)

func validateCredentialGrant(action, scope string, channels []string) error {
	if action != "issue" && action != "rotate" {
		if len(channels) > 0 || scope != "" {
			return errors.New("--scope and --channel are only supported for issue/rotate")
		}
		return nil
	}
	if scope != "" && scope != "agent" && scope != "coordinator" && scope != "coordinator_participant" {
		return errors.New("unsupported credential scope")
	}
	if scope != "coordinator_participant" {
		if len(channels) > 0 {
			return errors.New("--channel requires explicit --scope coordinator_participant")
		}
		return nil
	}
	if len(channels) < 1 || len(channels) > 20 {
		return errors.New("coordinator_participant requires 1–20 distinct --channel values")
	}
	seen := make(map[string]bool, len(channels))
	for _, channel := range channels {
		if !credentialChannelID.MatchString(channel) || seen[channel] {
			return errors.New("--channel must be distinct 1–128 byte IDs using letters, digits, underscores or hyphens")
		}
		seen[channel] = true
	}
	return nil
}
