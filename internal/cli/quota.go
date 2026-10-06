package cli

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"

	"github.com/spf13/cobra"
)

func (c *commands) quota() *cobra.Command {
	group := &cobra.Command{Use: "quota", Short: "Preserve producer quota evidence; no provider connections or automatic routing"}
	file := "-"
	push := &cobra.Command{Use: "push", Short: "Ingest one quota-axi schema 5/6 JSON report from stdin or file", Args: cobra.NoArgs}
	push.Flags().StringVar(&file, "file", "-", "JSON input file (- means stdin)")
	push.RunE = func(cmd *cobra.Command, args []string) error {
		source := cmd.InOrStdin()
		if file != "-" {
			input, err := os.Open(file)
			if err != nil {
				return errors.New("Cannot open quota input file")
			}
			defer input.Close()
			source = input
		}
		raw, err := io.ReadAll(io.LimitReader(source, (5<<20)+1))
		if err != nil {
			return errors.New("Cannot read quota input")
		}
		if len(raw) > 5<<20 {
			return errors.New("Quota input exceeds 5 MiB")
		}
		if !json.Valid(raw) {
			return errors.New("Quota input must contain exactly one JSON report")
		}
		return c.request(cmd, http.MethodPost, "quota", nil, json.RawMessage(raw))
	}
	group.AddCommand(push, c.list("quota", []string{"provider", "account"}), c.watchCommand("quota", []string{"provider", "account"}))
	return group
}
