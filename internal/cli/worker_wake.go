package cli

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"unicode/utf8"

	"github.com/carverauto/agentboard/internal/worker"
	"github.com/spf13/cobra"
)

func workerWakeResolve(load func() (worker.Config, worker.Binding, error), output func(*cobra.Command, any) error) *cobra.Command {
	var inputFile string
	command := &cobra.Command{
		Use: "wake-resolve", Short: "Read canonical sources for one exact frozen wake attempt; no receipt", Args: cobra.NoArgs,
		Long: "Read an exact wake callback from --input-file: attempt_id, intent_id, reason_hash, payload_hash and the complete frozen recipient. Uses the configured epoch receipt capability. A non-actionable result has source:null and reason_codes; source text never grants execution authority. Does not reserve, submit, acknowledge or apply a decision.",
		RunE: func(cmd *cobra.Command, _ []string) error {
			request, err := readWakeCallback(inputFile)
			if err != nil {
				return err
			}
			cfg, binding, err := load()
			if err != nil {
				return err
			}
			if err := request.ValidateBinding(binding); err != nil {
				return err
			}
			api, err := worker.OpenAPI(cfg, binding, true)
			if err != nil {
				return err
			}
			defer api.Close()
			result, err := api.WakeResolve(cmd.Context(), binding, request)
			if err != nil {
				return err
			}
			return output(cmd, result)
		},
	}
	command.Flags().StringVar(&inputFile, "input-file", "", "Regular JSON file containing exactly the five frozen wake callback fields (required, at most 16 KiB)")
	return command
}

func readWakeCallback(path string) (worker.WakeCallback, error) {
	var request worker.WakeCallback
	if path == "" {
		return request, errors.New("wake-resolve requires --input-file")
	}
	invalid := errors.New("wake input must be a regular file containing at most 16 KiB of exact wake callback JSON")
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() > worker.MaxFrameBytes {
		return request, invalid
	}
	file, err := os.Open(path)
	if err != nil {
		return request, invalid
	}
	defer file.Close()
	opened, err := file.Stat()
	if err != nil || !os.SameFile(info, opened) {
		return request, invalid
	}
	raw, err := io.ReadAll(io.LimitReader(file, worker.MaxFrameBytes+1))
	if err != nil || len(raw) > worker.MaxFrameBytes || !utf8.Valid(raw) || !json.Valid(raw) || !triageUnicodeValid(raw) {
		return request, invalid
	}
	fields, ok := triageObject(raw, "attempt_id", "intent_id", "reason_hash", "payload_hash", "recipient")
	if !ok {
		return request, invalid
	}
	if _, ok = triageObject(fields["recipient"], "agent_id", "host_id", "repo", "enrollment_revision", "binding_epoch", "session_id", "adapter_generation"); !ok {
		return request, invalid
	}
	if json.Unmarshal(raw, &request) != nil {
		return request, invalid
	}
	return request, request.Validate()
}
