package cli

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"time"

	"github.com/carverauto/agentboard/internal/client"
	"github.com/carverauto/agentboard/internal/config"
	"github.com/spf13/cobra"
)

func (c *commands) watchCommand(resource string, filters []string) *cobra.Command {
	cmd := &cobra.Command{Use: "watch", Short: "Watch full filtered snapshots; reconnect reloads durable state", Args: cobra.NoArgs}
	values := map[string]*string{}
	for _, key := range filters {
		v := new(string)
		values[key] = v
		cmd.Flags().StringVar(v, key, "", "Filter by "+key)
	}
	if resource == "messages" {
		cmd.Flags().Bool("unread", false, "Unread direct messages only")
	}
	cmd.RunE = func(cmd *cobra.Command, args []string) error {
		q := url.Values{}
		for k, v := range values {
			if *v != "" {
				q.Set(k, *v)
			}
		}
		messageQuery(cmd, q)
		return c.watch(cmd, resource, q)
	}
	return cmd
}
func (c *commands) watch(cmd *cobra.Command, resource string, q url.Values) error {
	if !config.ValidID(c.cfg.Actor.ID) {
		return errors.New("Watch requires a valid --agent / AGENT_ID")
	}
	q.Del("limit")
	q.Del("cursor")
	if resource == "quota" {
		q.Set("stale_after", fmt.Sprint(c.cfg.StaleAfter.Seconds()))
	}
	api, err := client.New(c.cfg)
	if err != nil {
		return err
	}
	defer api.Close()
	meta, err := api.JSON(cmd.Context(), "GET", "meta", nil, nil)
	if err != nil {
		return err
	}
	var version struct {
		API    int `json:"api_version"`
		Schema int `json:"schema_version"`
	}
	required := 2
	if resource == "quota" {
		required = 3
	}
	if json.Unmarshal(meta, &version) != nil || version.API != 1 || version.Schema < required {
		return &client.Error{Code: "schema_unavailable", Message: fmt.Sprintf("Watch requires API v1 and schema %d or later", required)}
	}
	reconnect := false
	backoff := time.Second
	for {
		if cmd.Context().Err() != nil {
			return nil
		}
		response, err := api.Stream(cmd.Context(), resource+"/watch", q)
		if err == nil {
			result := c.readWatch(cmd, response, reconnect)
			if result.sawSnapshot {
				backoff = time.Second
			}
			if result.outputErr != nil {
				return result.outputErr
			}
			if cmd.Context().Err() != nil {
				return nil
			}
			err = result.readErr
			if err == nil {
				err = errors.New("Watch connection closed")
			}
		}
		retry := backoff
		var remote *client.Error
		if errors.As(err, &remote) {
			if remote.ExitCode() != 1 {
				return err
			}
			if remote.RetryAfter >= 120*time.Second {
				return err
			}
			if remote.RetryAfter > retry {
				retry = remote.RetryAfter
			}
		}
		fmt.Fprintln(cmd.ErrOrStderr(), "ab: watch disconnected; reconnecting:", err)
		reconnect = true
		timer := time.NewTimer(retry)
		select {
		case <-cmd.Context().Done():
			timer.Stop()
			return nil
		case <-timer.C:
		}
		if backoff < 30*time.Second {
			backoff *= 2
			if backoff > 30*time.Second {
				backoff = 30 * time.Second
			}
		}
	}
}

type watchRead struct {
	sawSnapshot bool
	readErr     error
	outputErr   error
}

func (c *commands) readWatch(cmd *cobra.Command, response *http.Response, reconnect bool) watchRead {
	defer response.Body.Close()
	result := watchRead{}
	scanner := bufio.NewScanner(response.Body)
	scanner.Buffer(make([]byte, 64<<10), client.MaxResponseBytes)
	for scanner.Scan() {
		var snapshot map[string]any
		if err := json.Unmarshal(scanner.Bytes(), &snapshot); err != nil {
			result.readErr = err
			return result
		}
		if !result.sawSnapshot && reconnect {
			snapshot["reason"] = "reconnect"
		}
		result.sawSnapshot = true
		encoded, _ := json.Marshal(snapshot)
		if err := c.output(cmd.OutOrStdout(), encoded); err != nil {
			result.outputErr = err
			return result
		}
	}
	result.readErr = scanner.Err()
	return result
}
