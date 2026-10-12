package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/carverauto/agentboard/internal/nativequeue/owner"
	"github.com/carverauto/agentboard/internal/worker"
	"github.com/spf13/cobra"
)

func cliNativeFixture() worker.NativeManifest {
	return worker.NativeManifest{ManifestVersion: 1, ID: "fixture-approval", WorkerID: "worker-native", HostID: "fixture-host", EnrollmentRevision: 10, BindingEpoch: 3, SessionID: "session", PaneID: "pane", SocketPath: "/tmp/not-a-real-native-socket", InitializeApproved: true,
		Endpoint:  owner.Endpoint{ServerID: "server", EndpointID: "endpoint", Profile: "codex-durable-advisory-v1", NativeVersion: "0.162.0", ProtocolSource: "rust-v0.162.0", SchemaSHA256: strings.Repeat("a", 64), ExperimentalAPI: true, QueueAPI: true},
		Recipient: owner.Recipient{ThreadID: "11111111-1111-4111-8111-111111111111", IdentityKind: "durable-conversation-v1", EnrollmentRevision: 10, BindingEpoch: 3, Persistent: true, TopLevel: true},
		Peer:      owner.ProcessIdentity{PID: 42, UID: 0, BootID: "22222222-2222-4222-8222-222222222222", StartTicks: 4, ExecutableSHA256: strings.Repeat("b", 64)}}
}

type cliNativeCaptain struct {
	call func(context.Context, string, string, any) (json.RawMessage, error)
}

func (c *cliNativeCaptain) WorkerControl(ctx context.Context, op, id string, p any) (json.RawMessage, error) {
	return c.call(ctx, op, id, p)
}
func (c *cliNativeCaptain) Close() {}
func TestWorkerNativeApprovalCLIExactOperations(t *testing.T) {
	manifest := cliNativeFixture()
	raw, _ := json.Marshal(manifest)
	path := filepath.Join(t.TempDir(), "manifest.json")
	if err := os.WriteFile(path, raw, 0600); err != nil {
		t.Fatal(err)
	}
	for _, action := range []string{"validate", "approve", "retire", "retire-noop", "retire-repeat"} {
		t.Run(action, func(t *testing.T) {
			calls, opens := 0, 0
			workerID := manifest.WorkerID
			var got map[string]any
			open := func() (nativeCaptainClient, error) {
				opens++
				return &cliNativeCaptain{call: func(_ context.Context, op, id string, p any) (json.RawMessage, error) {
					calls++
					got = p.(map[string]any)
					want := "native-retire"
					if action == "approve" {
						want = "native-approval"
					}
					if op != want || id != manifest.WorkerID {
						t.Fatal("wrong captain route")
					}
					revision := int64(3)
					var approval *worker.NativeManifest
					var hash, idp *string
					if action == "approve" {
						approval = &manifest
						h, _ := worker.NativeManifestSHA256(manifest)
						hash = &h
						idp = &manifest.ID
					}
					if strings.HasPrefix(action, "retire-") {
						revision = 2
					}
					result := worker.NativeAuthorityMutation{ProtocolRevision: 1, AuthorityContractRevision: 1, Idempotent: action == "retire-repeat", Authority: worker.NativeAuthoritySnapshot{ProtocolRevision: 1, AuthorityContractRevision: 1, WorkerID: manifest.WorkerID, HostID: manifest.HostID, AuthorityRevision: revision, Manifest: approval, ManifestSHA256: hash, ApprovalID: idp, EnrollmentRevision: 10, BindingEpoch: 3, ReasonCodes: []string{"profile_live_disabled"}}}
					raw, err := json.Marshal(result)
					return raw, err
				}}, nil
			}
			output := func(cmd *cobra.Command, v any) error { return json.NewEncoder(cmd.OutOrStdout()).Encode(v) }
			command := workerNativeApprovalCommands(&workerID, output, open)
			var out bytes.Buffer
			command.SetOut(&out)
			command.SetErr(io.Discard)
			verb := action
			if strings.HasPrefix(action, "retire-") {
				verb = "retire"
			}
			args := []string{verb}
			if action == "validate" || action == "approve" {
				args = append(args, "--manifest-file", path)
			}
			if action != "validate" {
				args = append(args, "--expected-authority-revision", "2", "--key", "fixture-key")
			}
			command.SetArgs(args)
			if err := command.Execute(); err != nil {
				t.Fatal(err)
			}
			if action == "validate" {
				if calls != 0 || opens != 0 || !strings.Contains(out.String(), `"native_delivery_enabled":false`) {
					t.Fatal("validation obtained credentials or called remote/native")
				}
				return
			}
			if calls != 1 || opens != 1 || got["expected_authority_revision"] != int64(2) || got["idempotency_key"] != "fixture-key" {
				t.Fatal("mutation body changed or multiple calls")
			}
			wantFields := 2
			if action == "approve" {
				wantFields = 3
				if got["manifest"] != manifest {
					t.Fatal("manifest rewritten")
				}
			}
			if len(got) != wantFields {
				t.Fatal("approval added binding/activation/credential fields")
			}
		})
	}
}
func TestWorkerNativeApprovalCLIRejectsBeforeCredentials(t *testing.T) {
	manifest := cliNativeFixture()
	raw, _ := json.Marshal(manifest)
	path := filepath.Join(t.TempDir(), "manifest.json")
	if err := os.WriteFile(path, raw, 0600); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{
		{"approve", "--manifest-file", path, "--key", "fixture"},
		{"approve", "--manifest-file", path, "--expected-authority-revision", "0"},
		{"approve", "--manifest-file", path, "--key", "fixture", "--expected-authority-revision", "-1"},
		{"approve", "--manifest-file", path, "--key", "fixture", "--expected-authority-revision", "9007199254740992"},
		{"approve", "--manifest-file", path, "--key", "bad key", "--expected-authority-revision", "0"},
		{"approve", "--manifest-file", path, "--key", "fixture", "--expected-authority-revision", "0"},
		{"retire", "--key", "fixture", "--expected-authority-revision", "0"},
	} {
		workerID := "foreign"
		if args[0] == "retire" {
			workerID = ""
		}
		calls := 0
		command := workerNativeApprovalCommands(&workerID, func(*cobra.Command, any) error { t.Fatal("invalid command emitted output"); return nil }, func() (nativeCaptainClient, error) { calls++; return nil, nil })
		command.SetOut(io.Discard)
		command.SetErr(io.Discard)
		command.SetArgs(args)
		if err := command.Execute(); err == nil || calls != 0 {
			t.Fatalf("invalid args touched captain credentials: %v", args)
		}
	}
}
func TestWorkerNativeCommandsRegisteredWithoutNativeExecution(t *testing.T) {
	t.Setenv("AGENTBOARD_ACCESS_SERVICE_TOKEN_FILE", "")
	t.Setenv("AGENTBOARD_TOKEN", "")
	t.Setenv("AGENTBOARD_TOKEN_FILE", "")
	root := NewRoot()
	for _, args := range [][]string{{"worker", "native-approval", "validate"}, {"worker", "native-approval", "approve"}, {"worker", "native-approval", "retire"}, {"worker", "native-authority"}} {
		cmd, remaining, err := root.Find(args)
		if err != nil || len(remaining) != 0 || cmd == root {
			t.Fatalf("command absent: %v", args)
		}
	}
	m := cliNativeFixture()
	raw, _ := json.Marshal(m)
	path := filepath.Join(t.TempDir(), "manifest.json")
	if err := os.WriteFile(path, raw, 0644); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	root.SetOut(&out)
	root.SetErr(io.Discard)
	root.SetArgs([]string{"worker", "native-approval", "validate", "--manifest-file", path})
	if err := root.Execute(); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), `"validated":true`) {
		t.Fatal("offline root validation failed")
	}
}
