package cli

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"strings"

	"github.com/carverauto/agentboard/internal/client"
	"github.com/carverauto/agentboard/internal/config"
	"github.com/carverauto/agentboard/internal/worker"
	"github.com/spf13/cobra"
)

type nativeCaptainClient interface {
	WorkerControl(context.Context, string, string, any) (json.RawMessage, error)
	Close()
}

func (c *commands) openNativeCaptain() (nativeCaptainClient, error) {
	secret, err := worker.ReadProtected(os.Getenv("AGENTBOARD_CAPTAIN_TOKEN_FILE"), 4096)
	if err != nil {
		return nil, errors.New("AGENTBOARD_CAPTAIN_TOKEN_FILE must be a protected captain capability file")
	}
	return client.NewCaptain(c.cfg, strings.TrimSpace(string(secret)))
}

func workerNativeApprovalCommands(workerID *string, output func(*cobra.Command, any) error, openCaptain func() (nativeCaptainClient, error)) *cobra.Command {
	group := &cobra.Command{Use: "native-approval", Short: "Review, approve or retire immutable native inventory; never activate or bind"}
	var validateFile string
	validate := &cobra.Command{Use: "validate", Args: cobra.NoArgs, Short: "Validate and hash a local immutable manifest without network or native calls", RunE: func(cmd *cobra.Command, _ []string) error {
		manifest, err := worker.ReadNativeManifest(validateFile)
		if err != nil {
			return err
		}
		if *workerID != "" && *workerID != manifest.WorkerID {
			return errors.New("manifest worker does not match --worker-id")
		}
		hash, err := worker.NativeManifestSHA256(manifest)
		if err != nil {
			return err
		}
		return output(cmd, map[string]any{"protocol_revision": worker.Protocol, "authority_contract_revision": worker.NativeAuthorityContract, "manifest_sha256": hash, "manifest": manifest, "validated": true, "native_delivery_enabled": false})
	}}
	validate.Flags().StringVar(&validateFile, "manifest-file", "", "Regular, symlink-free exact manifest JSON file, at most 32 KiB (required)")
	group.AddCommand(validate)
	for _, action := range []string{"approve", "retire"} {
		var manifestFile, key string
		var revision int64
		command := &cobra.Command{Use: action, Args: cobra.NoArgs, Short: "Captain-only " + action + " of native authority; no credentials, binding or activation", RunE: func(cmd *cobra.Command, _ []string) error {
			if !cmd.Flags().Changed("expected-authority-revision") || revision < 0 || revision > 9007199254740991 || !nativeAuthorityKeyValid(key) {
				return errors.New("requires a safe nonnegative --expected-authority-revision and a bounded --key")
			}
			target := *workerID
			body := map[string]any{"expected_authority_revision": revision, "idempotency_key": key}
			var expected *worker.NativeManifest
			if action == "approve" {
				manifest, err := worker.ReadNativeManifest(manifestFile)
				if err != nil {
					return err
				}
				if target != "" && target != manifest.WorkerID {
					return errors.New("manifest worker does not match --worker-id")
				}
				target = manifest.WorkerID
				expected = &manifest
				body["manifest"] = manifest
			}
			if !config.ValidID(target) {
				return errors.New("native approval requires an exact --worker-id")
			}
			api, err := openCaptain()
			if err != nil {
				return err
			}
			defer api.Close()
			operation := "native-retire"
			if action == "approve" {
				operation = "native-approval"
			}
			raw, err := api.WorkerControl(cmd.Context(), operation, target, body)
			if err != nil {
				return err
			}
			result, err := worker.ParseNativeAuthorityMutation(raw)
			noOpRetire := action == "retire" && result.Authority.AuthorityRevision == revision && result.Authority.Manifest == nil && result.Authority.ApprovalID == nil && result.Authority.ManifestSHA256 == nil && !result.Authority.Permitted
			if err != nil || result.Authority.WorkerID != target || (result.Authority.AuthorityRevision != revision+1 && !noOpRetire) {
				return errors.New("native authority mutation response incompatible; inspect state before retrying")
			}
			if expected != nil && (result.Authority.Manifest == nil || *result.Authority.Manifest != *expected) {
				return errors.New("native approval response changed immutable manifest; inspect state before retrying")
			}
			if action == "retire" && result.Authority.Permitted {
				return errors.New("native retirement response remains permitted; inspect state before retrying")
			}
			return output(cmd, result)
		}}
		command.Flags().Int64Var(&revision, "expected-authority-revision", 0, "Exact revision from the current authority snapshot (required)")
		command.Flags().StringVar(&key, "key", "", "Stable explicit idempotency key (required)")
		if action == "approve" {
			command.Flags().StringVar(&manifestFile, "manifest-file", "", "Reviewed exact manifest JSON file (required)")
		}
		group.AddCommand(command)
	}
	return group
}
func nativeAuthorityKeyValid(key string) bool {
	if len(key) == 0 || len(key) > 128 {
		return false
	}
	for _, b := range []byte(key) {
		if b < 33 || b > 126 {
			return false
		}
	}
	return true
}

func workerNativeAuthorityCommand(load func() (worker.Config, worker.Binding, error), output func(*cobra.Command, any) error) *cobra.Command {
	var manifestFile string
	command := &cobra.Command{Use: "native-authority", Args: cobra.NoArgs, Short: "Read exact host-scoped native authority; no native connection or mutation", RunE: func(cmd *cobra.Command, _ []string) error {
		cfg, binding, err := load()
		if err != nil {
			return err
		}
		api, err := worker.OpenAPI(cfg, binding, false)
		if err != nil {
			return err
		}
		defer api.Close()
		var expected *worker.NativeManifest
		if manifestFile != "" {
			manifest, err := worker.ReadNativeManifest(manifestFile)
			if err != nil {
				return err
			}
			expected = &manifest
		}
		snapshot, err := api.FetchNativeAuthority(cmd.Context())
		if err != nil {
			return err
		}
		if expected != nil {
			if _, err := worker.BuildNativeApproval(*expected, snapshot, snapshot.RequestStarted()); err != nil {
				return err
			}
		}
		return output(cmd, snapshot)
	}}
	command.Flags().StringVar(&manifestFile, "manifest-file", "", "Optionally require a genuine current host approval matching this immutable manifest; never connects to native")
	return command
}
