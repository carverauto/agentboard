package cli

import (
	"encoding/json"
	"errors"
	"github.com/carverauto/agentboard/internal/client"
	"github.com/carverauto/agentboard/internal/worker"
	"github.com/spf13/cobra"
	"net/http"
	"os"
	"strings"
)

func (c *commands) agentTokens() *cobra.Command {
	group := &cobra.Command{Use: "token", Short: "Captain-managed board credentials; plaintext goes only to a protected file"}
	for _, action := range []string{"issue", "rotate", "revoke", "list"} {
		action := action
		out, scope, id := "", "", ""
		cmd := &cobra.Command{Use: action + " AGENT_ID", Args: idArgs, RunE: func(cmd *cobra.Command, args []string) error {
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
			data := map[string]any{}
			if scope != "" {
				data["scope"] = scope
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
		cmd.Flags().StringVar(&scope, "scope", "", "agent or coordinator scope (issue/rotate)")
		cmd.Flags().StringVar(&id, "credential-id", "", "Credential ID to revoke; omit to revoke all for the agent")
		group.AddCommand(cmd)
	}
	return group
}
