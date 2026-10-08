package cli_test

// Tests for `agentboard admin` (GH #138): idempotency (second run is a
// no-op), plan-mode exit codes with no writes, and no-secret-output capture
// across stdout, stderr, and --json.

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/carverauto/agentboard/internal/cli"
)

const admSecretPrefix = "test-host-token-00000000000000000000"

type admBoard struct {
	t           *testing.T
	server      *httptest.Server
	provisioned map[string]int // idempotency_key -> token serial
	revoked     map[string]bool
	registered  map[string]bool
	provisions  int
}

func newAdmBoard(t *testing.T) *admBoard {
	t.Helper()
	f := &admBoard{t: t, provisioned: map[string]int{}, revoked: map[string]bool{}, registered: map[string]bool{}}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v1/meta", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"api_version":1,"schema_version":22}`))
	})
	mux.HandleFunc("POST /api/v1/workers/provision", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			WorkerID string   `json:"worker_id"`
			HostID   string   `json:"host_id"`
			Key      string   `json:"idempotency_key"`
			Repos    []string `json:"repos"`
			Model    string   `json:"model"`
			Harness  string   `json:"harness"`
		}
		f.provisions++
		if json.NewDecoder(r.Body).Decode(&body) != nil || body.WorkerID == "" || body.HostID == "" || body.Key == "" || len(body.Repos) < 1 {
			w.WriteHeader(422)
			w.Write([]byte(`{"error":{"code":"invalid_input","message":"bad provision"},"protocol_revision":1}`))
			return
		}
		if n, seen := f.provisioned[body.Key]; seen {
			json.NewEncoder(w).Encode(map[string]any{"worker": map[string]any{"id": body.WorkerID}, "idempotent": true, "seen": n, "protocol_revision": 1})
			return
		}
		n := len(f.provisioned) + 1
		f.provisioned[body.Key] = n
		json.NewEncoder(w).Encode(map[string]any{
			"worker":     map[string]any{"id": body.WorkerID},
			"host_token": fmt.Sprintf("%s%02d", admSecretPrefix, n),
			"idempotent": false, "protocol_revision": 1,
		})
	})
	mux.HandleFunc("POST /api/v1/workers/{id}/revoke", func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		enrolled := false
		for key := range f.provisioned {
			if strings.Contains(key, "/"+id+"/") {
				enrolled = true
			}
		}
		if !enrolled || f.revoked[id] {
			w.WriteHeader(404)
			w.Write([]byte(`{"error":{"code":"not_found","message":"Worker not enrolled"},"protocol_revision":1}`))
			return
		}
		f.revoked[id] = true
		w.Write([]byte(`{"revoked":true,"protocol_revision":1}`))
	})
	mux.HandleFunc("POST /api/v1/agents/register", func(w http.ResponseWriter, r *http.Request) {
		id := r.Header.Get("X-Agentboard-Agent")
		if id == "" {
			w.WriteHeader(401)
			w.Write([]byte(`{"error":{"code":"unauthorized","message":"no actor"},"protocol_revision":1}`))
			return
		}
		f.registered[id] = true
		w.Write([]byte(`{"agent":{"id":"` + id + `"},"protocol_revision":1}`))
	})
	mux.HandleFunc("GET /api/v1/agents/{id}", func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		if !f.registered[id] {
			w.WriteHeader(404)
			w.Write([]byte(`{"error":{"code":"not_found","message":"no such agent"},"protocol_revision":1}`))
			return
		}
		w.Write([]byte(`{"agent":{"id":"` + id + `","harness":"test"},"protocol_revision":1}`))
	})
	mux.HandleFunc("GET /api/v1/availability", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"availability":[],"protocol_revision":1}`))
	})
	mux.HandleFunc("GET /api/v1/agents", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"agents":[],"protocol_revision":1}`))
	})
	f.server = httptest.NewServer(mux)
	t.Cleanup(f.server.Close)
	return f
}

func admEnv(t *testing.T, f *admBoard) string {
	t.Helper()
	t.Setenv("AGENTBOARD_URL", f.server.URL)
	t.Setenv("AGENT_ID", "test-operator")
	t.Setenv("AGENTBOARD_MODEL", "fixture")
	t.Setenv("AGENTBOARD_HARNESS", "test")
	dir := t.TempDir()
	cap := filepath.Join(dir, "captain.token")
	if err := os.WriteFile(cap, []byte("test-captain-capability-000000000000"), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("AGENTBOARD_CAPTAIN_TOKEN_FILE", cap)
	return dir
}

func runAdm(t *testing.T, args ...string) (string, string, error) {
	t.Helper()
	root := cli.NewRoot()
	var out, errb strings.Builder
	root.SetOut(&out)
	root.SetErr(&errb)
	root.SetArgs(args)
	err := root.Execute()
	return out.String(), errb.String(), err
}

func admCreateArgs(dir string, extra ...string) []string {
	base := []string{"admin", "worker", "create", "worker-a",
		"--token-file", filepath.Join(dir, "worker.token"),
		"--host", "host-a", "--repo", "owner/repo",
		"--model", "m", "--harness", "h"}
	return append(base, extra...)
}

func TestAdminWorkerCreateTwiceIsNoop(t *testing.T) {
	f := newAdmBoard(t)
	dir := admEnv(t, f)
	out, errb, err := runAdm(t, admCreateArgs(dir)...)
	if err != nil {
		t.Fatalf("create failed: %v (stderr %s)", err, errb)
	}
	tok, rerr := os.ReadFile(filepath.Join(dir, "worker.token"))
	if rerr != nil {
		t.Fatalf("token file missing: %v", rerr)
	}
	fi, _ := os.Stat(filepath.Join(dir, "worker.token"))
	if fi.Mode().Perm() != 0600 {
		t.Fatalf("token file mode = %o, want 600", fi.Mode().Perm())
	}
	secret := strings.TrimSpace(string(tok))
	if !strings.HasPrefix(secret, admSecretPrefix) {
		t.Fatalf("unexpected token shape")
	}
	if strings.Contains(out, secret) || strings.Contains(errb, secret) {
		t.Fatalf("secret leaked into output")
	}
	// Second run: the file exists, so create verifies against the server
	// with the stable idempotency key (a read-only retry) and converges
	// without writing anything.
	before, _ := os.ReadFile(filepath.Join(dir, "worker.token"))
	out2, _, err := runAdm(t, admCreateArgs(dir)...)
	if err != nil {
		t.Fatalf("second create failed: %v", err)
	}
	after, _ := os.ReadFile(filepath.Join(dir, "worker.token"))
	if string(before) != string(after) {
		t.Fatalf("second create rewrote the token file")
	}
	if !strings.Contains(out2, "converged") {
		t.Fatalf("second create did not report converged: %s", out2)
	}
}

func TestAdminWorkerCreateDryRunWritesNothing(t *testing.T) {
	f := newAdmBoard(t)
	dir := admEnv(t, f)
	out, _, err := runAdm(t, admCreateArgs(dir, "--dry-run")...)
	if err == nil || cli.ExitCode(err) != 2 {
		t.Fatalf("dry-run must exit 2, got err=%v", err)
	}
	if f.provisions != 0 {
		t.Fatalf("dry-run called the board")
	}
	if _, serr := os.Stat(filepath.Join(dir, "worker.token")); !os.IsNotExist(serr) {
		t.Fatalf("dry-run wrote a token file")
	}
	if !strings.Contains(out, "provisioned") {
		t.Fatalf("dry-run must show the pending diff: %s", out)
	}
}

func TestAdminWorkerCreateJSONEnvelope(t *testing.T) {
	f := newAdmBoard(t)
	dir := admEnv(t, f)
	out, _, err := runAdm(t, append([]string{"--json"}, admCreateArgs(dir)...)...)
	if err != nil {
		t.Fatalf("create --json failed: %v", err)
	}
	var env struct {
		Command string              `json:"command"`
		DryRun  bool                `json:"dry_run"`
		Diff    []map[string]string `json:"diff"`
		Result  map[string]any      `json:"result"`
	}
	if json.Unmarshal([]byte(out), &env) != nil {
		t.Fatalf("output is not the JSON envelope: %s", out)
	}
	if env.Command == "" || len(env.Diff) == 0 {
		t.Fatalf("envelope missing command/diff: %s", out)
	}
	tok, _ := os.ReadFile(filepath.Join(dir, "worker.token"))
	if strings.Contains(out, strings.TrimSpace(string(tok))) {
		t.Fatalf("secret leaked into --json output")
	}
}

func TestAdminWorkerCreateRefusesExistingFile(t *testing.T) {
	f := newAdmBoard(t)
	dir := admEnv(t, f)
	tokenPath := filepath.Join(dir, "worker.token")
	if err := os.WriteFile(tokenPath, []byte("existing"), 0600); err != nil {
		t.Fatal(err)
	}
	_, _, err := runAdm(t, admCreateArgs(dir)...)
	if err == nil || !strings.Contains(err.Error(), "--rotate") {
		t.Fatalf("must refuse existing file naming --rotate, got %v", err)
	}
	kept, _ := os.ReadFile(tokenPath)
	if string(kept) != "existing" {
		t.Fatalf("refusal must not touch the existing file")
	}
}

func TestAdminWorkerRotateReplacesToken(t *testing.T) {
	f := newAdmBoard(t)
	dir := admEnv(t, f)
	if _, _, err := runAdm(t, admCreateArgs(dir)...); err != nil {
		t.Fatalf("create failed: %v", err)
	}
	first, _ := os.ReadFile(filepath.Join(dir, "worker.token"))
	if _, _, err := runAdm(t, admCreateArgs(dir, "--rotate")...); err != nil {
		t.Fatalf("rotate failed: %v", err)
	}
	second, _ := os.ReadFile(filepath.Join(dir, "worker.token"))
	if string(first) == string(second) {
		t.Fatalf("rotate did not replace the token")
	}
}

func TestAdminWorkerRevokeTwiceConverges(t *testing.T) {
	f := newAdmBoard(t)
	dir := admEnv(t, f)
	if _, _, err := runAdm(t, admCreateArgs(dir)...); err != nil {
		t.Fatalf("create failed: %v", err)
	}
	out, _, err := runAdm(t, "admin", "worker", "revoke", "worker-a")
	if err != nil {
		t.Fatalf("revoke failed: %v", err)
	}
	if !strings.Contains(out, "revoked") {
		t.Fatalf("revoke must report the change: %s", out)
	}
	out2, _, err := runAdm(t, "admin", "worker", "revoke", "worker-a")
	if err != nil {
		t.Fatalf("second revoke failed: %v", err)
	}
	if !strings.Contains(out2, "converged") {
		t.Fatalf("second revoke must converge: %s", out2)
	}
}

func TestAdminWorkerRevokeUnknownConverges(t *testing.T) {
	f := newAdmBoard(t)
	admEnv(t, f)
	out, _, err := runAdm(t, "admin", "worker", "revoke", "ghost-worker")
	if err != nil {
		t.Fatalf("revoke of unknown worker must converge, got %v", err)
	}
	if !strings.Contains(out, "converged") {
		t.Fatalf("expected converged, got %s", out)
	}
}

func TestAdminConfigSetTwiceIsNoop(t *testing.T) {
	f := newAdmBoard(t)
	dir := admEnv(t, f)
	overlay := filepath.Join(dir, "kustomization.yaml")
	before := "configMapGenerator:\n- name: agentboard-config\n  behavior: merge\n  literals:\n  - AGENTBOARD_COORDINATOR_ID=old-id\n"
	if err := os.WriteFile(overlay, []byte(before), 0644); err != nil {
		t.Fatal(err)
	}
	set := []string{"admin", "config", "coordinator-id", "set", "new-id", "--overlay", overlay}
	if _, _, err := runAdm(t, set...); err != nil {
		t.Fatalf("set failed: %v", err)
	}
	raw, _ := os.ReadFile(overlay)
	if !strings.Contains(string(raw), "AGENTBOARD_COORDINATOR_ID=new-id") {
		t.Fatalf("overlay not converged:\n%s", raw)
	}
	out, _, err := runAdm(t, set...)
	if err != nil {
		t.Fatalf("second set failed: %v", err)
	}
	if !strings.Contains(out, "converged") {
		t.Fatalf("second set must converge: %s", out)
	}
	// Dry-run on a drifted value exits 2 and writes nothing.
	dreset := []string{"admin", "config", "coordinator-id", "set", "other-id", "--overlay", overlay, "--dry-run"}
	if _, _, err := runAdm(t, dreset...); err == nil || cli.ExitCode(err) != 2 {
		t.Fatalf("drifted dry-run must exit 2, got %v", err)
	}
	raw, _ = os.ReadFile(overlay)
	if !strings.Contains(string(raw), "AGENTBOARD_COORDINATOR_ID=new-id") {
		t.Fatalf("dry-run mutated the file")
	}
}

func TestAdminConfigPoliciesRejectsInvalidJSON(t *testing.T) {
	f := newAdmBoard(t)
	dir := admEnv(t, f)
	overlay := filepath.Join(dir, "kustomization.yaml")
	before := "configMapGenerator:\n- name: cfg\n  literals:\n  - FOO=bar\n"
	if err := os.WriteFile(overlay, []byte(before), 0644); err != nil {
		t.Fatal(err)
	}
	bad := filepath.Join(dir, "policies.json")
	if err := os.WriteFile(bad, []byte("{not json"), 0644); err != nil {
		t.Fatal(err)
	}
	_, _, err := runAdm(t, "admin", "config", "ci-policies", "set", "--file", bad, "--overlay", overlay)
	if err == nil || !strings.Contains(err.Error(), "valid JSON") {
		t.Fatalf("must refuse invalid JSON, got %v", err)
	}
	raw, _ := os.ReadFile(overlay)
	if string(raw) != before {
		t.Fatalf("refused write mutated the file")
	}
}

func TestAdminAgentRegisterConverges(t *testing.T) {
	f := newAdmBoard(t)
	admEnv(t, f)
	t.Setenv("AGENT_ID", "agent-one")
	if _, _, err := runAdm(t, "admin", "agent", "register", "agent-one", "--dry-run"); err == nil || cli.ExitCode(err) != 2 {
		t.Fatalf("unknown agent dry-run must exit 2, got %v", err)
	}
	out, _, err := runAdm(t, "admin", "agent", "register", "agent-one")
	if err != nil {
		t.Fatalf("register failed: %v", err)
	}
	if !strings.Contains(out, "agent-one") {
		t.Fatalf("register must report the agent: %s", out)
	}
	out2, _, err := runAdm(t, "admin", "agent", "register", "agent-one", "--dry-run")
	if err != nil {
		t.Fatalf("known agent dry-run must converge, got %v", err)
	}
	if !strings.Contains(out2, "converged") {
		t.Fatalf("expected converged, got %s", out2)
	}
	_, _, err = runAdm(t, "admin", "agent", "register", "someone-else")
	if err == nil || !strings.Contains(err.Error(), "wrong identity") {
		t.Fatalf("must refuse a mismatched identity, got %v", err)
	}
}

func TestAdminEnrollDryRunTouchesNothing(t *testing.T) {
	f := newAdmBoard(t)
	dir := admEnv(t, f)
	home := filepath.Join(dir, "home")
	cfg := filepath.Join(dir, "worker-config.json")
	_, _, err := runAdm(t, "admin", "worker", "enroll", "worker-a",
		"--repo", "owner/repo", "--host", "host-a", "--model", "m", "--harness", "h",
		"--home", home, "--config", cfg, "--platform", "linux", "--dry-run")
	if err == nil || cli.ExitCode(err) != 2 {
		t.Fatalf("enroll dry-run must exit 2, got %v", err)
	}
	if f.provisions != 0 {
		t.Fatalf("enroll dry-run called the board")
	}
	entries, _ := os.ReadDir(home)
	if len(entries) != 0 {
		t.Fatalf("enroll dry-run wrote supervision files")
	}
}

func TestAdminApplyTwiceConverges(t *testing.T) {
	f := newAdmBoard(t)
	dir := admEnv(t, f)
	overlay := filepath.Join(dir, "kustomization.yaml")
	if err := os.WriteFile(overlay, []byte("configMapGenerator:\n- name: cfg\n  literals:\n  - FOO=bar\n"), 0644); err != nil {
		t.Fatal(err)
	}
	apply := "apiVersion: agentboard.carverauto.dev/v1\nkind: AdminConfig\n" +
		"workers:\n- id: worker-a\n  action: create\n  host: host-a\n  repos:\n    - owner/repo\n  model: m\n  harness: h\n  token_file: " + filepath.Join(dir, "worker.token") + "\n" +
		"config:\n  overlay: " + overlay + "\n  coordinator_id: coord-one\n"
	applyPath := filepath.Join(dir, "admin.yaml")
	if err := os.WriteFile(applyPath, []byte(apply), 0644); err != nil {
		t.Fatal(err)
	}
	out, errb, err := runAdm(t, "admin", "apply", "-f", applyPath)
	if err != nil {
		t.Fatalf("apply failed: %v (stderr %s)", err, errb)
	}
	tok, _ := os.ReadFile(filepath.Join(dir, "worker.token"))
	secret := strings.TrimSpace(string(tok))
	if strings.Contains(out, secret) || strings.Contains(errb, secret) {
		t.Fatalf("secret leaked into apply output")
	}
	out2, _, err := runAdm(t, "admin", "apply", "-f", applyPath)
	if err != nil {
		t.Fatalf("second apply failed: %v", err)
	}
	if !strings.Contains(out2, "converged") {
		t.Fatalf("second apply must converge: %s", out2)
	}
}

func TestAdminApplyRejectsInlineSecret(t *testing.T) {
	f := newAdmBoard(t)
	dir := admEnv(t, f)
	overlay := filepath.Join(dir, "kustomization.yaml")
	before := "configMapGenerator:\n- name: cfg\n  literals:\n  - FOO=bar\n"
	if err := os.WriteFile(overlay, []byte(before), 0644); err != nil {
		t.Fatal(err)
	}
	applyPath := filepath.Join(dir, "admin.yaml")
	evil := "apiVersion: agentboard.carverauto.dev/v1\nkind: AdminConfig\n" +
		"workers:\n- id: worker-a\n  action: create\n  host: host-a\n  repos:\n    - owner/repo\n  token: s3cr3t-value\n"
	if err := os.WriteFile(applyPath, []byte(evil), 0644); err != nil {
		t.Fatal(err)
	}
	_, _, err := runAdm(t, "admin", "apply", "-f", applyPath)
	if err == nil || !strings.Contains(err.Error(), "inline secret") {
		t.Fatalf("must reject inline secrets, got %v", err)
	}
	if f.provisions != 0 {
		t.Fatalf("rejected file must not reach the board")
	}
	raw, _ := os.ReadFile(overlay)
	if string(raw) != before {
		t.Fatalf("rejected file mutated the target")
	}
}

func admBinStub(t *testing.T, dir, name, body string) {
	t.Helper()
	p := filepath.Join(dir, "bin", name)
	if err := os.MkdirAll(filepath.Join(dir, "bin"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(body), 0755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", filepath.Join(dir, "bin")+string(os.PathListSeparator)+os.Getenv("PATH"))
}

func admKubectlStub(t *testing.T, dir string) {
	t.Helper()
	admBinStub(t, dir, "kubectl", "#!/bin/sh\n"+
		"log=\"$ADMIN_STUB_LOG\"\n"+
		"echo \"ARGS: $@\" >> \"$log\"\n"+
		"input=$(cat)\n"+
		"if [ -n \"$input\" ]; then echo \"STDIN: $(printf '%s' \"$input\" | head -c 400)\" >> \"$log\"; fi\n"+
		"case \" $* \" in\n"+
		"  *\"rollout status\"*) [ \"$ADMIN_STUB_FAIL\" = rollout ] && { echo failing-status; exit 1; }; echo rolled; exit 0;;\n"+
		"  *\"get deployment\"*) echo \"old-registry/agentboard/dashboard@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"; exit 0;;\n"+
		"esac\n"+
		"exit 0\n")
	admBinStub(t, dir, "pg_dump", "#!/bin/sh\n"+
		"prev=\"\"\n"+
		"for a in \"$@\"; do if [ \"$prev\" = \"-f\" ]; then echo DUMP > \"$a\"; fi; prev=\"$a\"; done\n"+
		"exit 0\n")
}

func admOverlay(t *testing.T, dir, digest string) string {
	t.Helper()
	p := filepath.Join(dir, "kustomization.yaml")
	content := "configMapGenerator:\n- name: cfg\n  behavior: merge\n  literals:\n  - FOO=bar\nimages:\n- name: registry.example.com/agentboard/dashboard\n  digest: " + digest + "\n"
	if err := os.WriteFile(p, []byte(content), 0644); err != nil {
		t.Fatal(err)
	}
	return p
}

func admJobManifest(t *testing.T, dir string) string {
	t.Helper()
	p := filepath.Join(dir, "job.yaml")
	content := "apiVersion: batch/v1\nkind: Job\nmetadata:\n  name: agentboard-migrate\nspec:\n  template:\n    spec:\n      restartPolicy: Never\n      containers:\n      - name: migrate\n        image: registry.example.com/agentboard/dashboard@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n"
	if err := os.WriteFile(p, []byte(content), 0644); err != nil {
		t.Fatal(err)
	}
	return p
}

const admOldDigest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
const admNewDigest = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
const admNewPin = "registry.example.com/agentboard/dashboard@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

func admRolloutArgs(overlay, job, dump, record string, extra ...string) []string {
	base := []string{"admin", "rollout", admNewPin,
		"--overlay", overlay, "--image", "registry.example.com/agentboard/dashboard",
		"--deployment", "agentboard", "--namespace", "test-ns",
		"--migration-job", job, "--backup-path", dump, "--db-name", "board",
		"--soak-seconds", "0", "--timeout-seconds", "30"}
	if record != "" {
		base = append(base, "--record-out", record)
	}
	return append(base, extra...)
}

func TestAdminRolloutOrdersBackupBeforeMigration(t *testing.T) {
	f := newAdmBoard(t)
	dir := admEnv(t, f)
	admKubectlStub(t, dir)
	t.Setenv("ADMIN_STUB_LOG", filepath.Join(dir, "kubectl.log"))
	overlay := admOverlay(t, dir, admOldDigest)
	job := admJobManifest(t, dir)
	dump := filepath.Join(dir, "dump.sql")
	record := filepath.Join(dir, "rollout.json")
	if _, _, err := runAdm(t, admRolloutArgs(overlay, job, dump, record)...); err != nil {
		t.Fatalf("rollout failed: %v", err)
	}
	// Pin converged in the file.
	raw, _ := os.ReadFile(overlay)
	if !strings.Contains(string(raw), admNewDigest) {
		t.Fatalf("overlay pin not converged:\n%s", raw)
	}
	// Backup ran before any migration.
	if _, err := os.Stat(dump); err != nil {
		t.Fatalf("backup dump missing: %v", err)
	}
	log, _ := os.ReadFile(filepath.Join(dir, "kubectl.log"))
	lines := strings.Split(string(log), "\n")
	jobIdx, rollIdx, statusIdx := -1, -1, -1
	for i, l := range lines {
		switch {
		case strings.Contains(l, "kind: Job"):
			jobIdx = i
		case strings.Contains(l, "apply -k"):
			rollIdx = i
		case strings.Contains(l, "rollout status"):
			statusIdx = i
		}
	}
	if jobIdx < 0 || rollIdx < 0 || statusIdx < 0 {
		t.Fatalf("missing rollout steps in kubectl log:\n%s", log)
	}
	if !(jobIdx < rollIdx && rollIdx < statusIdx) {
		t.Fatalf("steps out of order (job=%d roll=%d status=%d)", jobIdx, rollIdx, statusIdx)
	}
	// Record shape.
	rec, err := os.ReadFile(record)
	if err != nil {
		t.Fatalf("record missing: %v", err)
	}
	var recm map[string]any
	if json.Unmarshal(rec, &recm) != nil {
		t.Fatalf("record is not JSON")
	}
	if recm["rollback_performed"] != false {
		t.Fatalf("record must mark no rollback: %s", rec)
	}
	steps, _ := json.Marshal(recm["steps"])
	for _, want := range []string{"backup:", "migration:", "roll:", "verify:"} {
		if !strings.Contains(string(steps), want) {
			t.Fatalf("record steps missing %q: %s", want, steps)
		}
	}
	// Same digest twice is a no-op.
	out, _, err := runAdm(t, admRolloutArgs(overlay, job, dump, "")...)
	if err != nil {
		t.Fatalf("second rollout failed: %v", err)
	}
	if !strings.Contains(out, "converged") {
		t.Fatalf("second rollout must converge: %s", out)
	}
}

func TestAdminRolloutCNPGBackupPrecedesMigration(t *testing.T) {
	f := newAdmBoard(t)
	dir := admEnv(t, f)
	admKubectlStub(t, dir)
	t.Setenv("ADMIN_STUB_LOG", filepath.Join(dir, "kubectl.log"))
	overlay := admOverlay(t, dir, admOldDigest)
	job := admJobManifest(t, dir)
	args := []string{"admin", "rollout", admNewPin,
		"--overlay", overlay, "--image", "registry.example.com/agentboard/dashboard",
		"--deployment", "agentboard", "--namespace", "test-ns",
		"--migration-job", job, "--cnpg-cluster", "agentboard-db",
		"--soak-seconds", "0", "--timeout-seconds", "30"}
	if _, _, err := runAdm(t, args...); err != nil {
		t.Fatalf("rollout failed: %v", err)
	}
	log, _ := os.ReadFile(filepath.Join(dir, "kubectl.log"))
	lines := strings.Split(string(log), "\n")
	backupIdx, jobIdx := -1, -1
	for i, l := range lines {
		if strings.Contains(l, "kind: Backup") {
			backupIdx = i
		}
		if strings.Contains(l, "kind: Job") {
			jobIdx = i
		}
	}
	if backupIdx < 0 || jobIdx < 0 {
		t.Fatalf("missing backup/migration steps:\n%s", log)
	}
	if !(backupIdx < jobIdx) {
		t.Fatalf("backup must precede migration (backup=%d job=%d)", backupIdx, jobIdx)
	}
}

func TestAdminRolloutFailedVerifyRollsBack(t *testing.T) {
	f := newAdmBoard(t)
	dir := admEnv(t, f)
	admKubectlStub(t, dir)
	t.Setenv("ADMIN_STUB_LOG", filepath.Join(dir, "kubectl.log"))
	t.Setenv("ADMIN_STUB_FAIL", "rollout")
	overlay := admOverlay(t, dir, admOldDigest)
	job := admJobManifest(t, dir)
	dump := filepath.Join(dir, "dump.sql")
	record := filepath.Join(dir, "rollout.json")
	_, _, err := runAdm(t, admRolloutArgs(overlay, job, dump, record)...)
	if err == nil || cli.ExitCode(err) != 3 {
		t.Fatalf("failed verification must exit 3, got %v", err)
	}
	raw, _ := os.ReadFile(overlay)
	if !strings.Contains(string(raw), admOldDigest) || strings.Contains(string(raw), admNewDigest[7:15]) {
		t.Fatalf("previous pin not restored:\n%s", raw)
	}
	rec, _ := os.ReadFile(record)
	if !strings.Contains(string(rec), `"rollback_performed": true`) {
		t.Fatalf("record must mark the rollback: %s", rec)
	}
}

func TestAdminRolloutDryRunWritesNothing(t *testing.T) {
	f := newAdmBoard(t)
	dir := admEnv(t, f)
	admKubectlStub(t, dir)
	t.Setenv("ADMIN_STUB_LOG", filepath.Join(dir, "kubectl.log"))
	overlay := admOverlay(t, dir, admOldDigest)
	job := admJobManifest(t, dir)
	dump := filepath.Join(dir, "dump.sql")
	_, _, err := runAdm(t, admRolloutArgs(overlay, job, dump, "", "--dry-run")...)
	if err == nil || cli.ExitCode(err) != 2 {
		t.Fatalf("drifted dry-run must exit 2, got %v", err)
	}
	raw, _ := os.ReadFile(overlay)
	if strings.Contains(string(raw), "bbbb") {
		t.Fatalf("dry-run mutated the overlay")
	}
	if _, serr := os.Stat(dump); !os.IsNotExist(serr) {
		t.Fatalf("dry-run ran the backup")
	}
	if _, serr := os.Stat(filepath.Join(dir, "kubectl.log")); !os.IsNotExist(serr) {
		t.Fatalf("dry-run invoked kubectl")
	}
	if f.provisions != 0 {
		t.Fatalf("dry-run touched the board")
	}
}

func TestAdminRolloutRejectsTags(t *testing.T) {
	f := newAdmBoard(t)
	dir := admEnv(t, f)
	_, _, err := runAdm(t, "admin", "rollout", "registry.example.com/agentboard/dashboard:0.1.0",
		"--overlay", "x", "--image", "y", "--deployment", "d", "--namespace", "n", "--migration-job", "j")
	if err == nil || !strings.Contains(err.Error(), "tags are rejected") {
		t.Fatalf("must reject tags, got %v", err)
	}
	taggedPin := "registry.example.com/agentboard/dashboard:v1@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	_, _, err = runAdm(t, "admin", "rollout", taggedPin,
		"--overlay", "x", "--image", "y", "--deployment", "d", "--namespace", "n", "--migration-job", "j")
	if err == nil || !strings.Contains(err.Error(), "tags are rejected") {
		t.Fatalf("must reject tag-qualified digests, got %v", err)
	}
	portOverlay := filepath.Join(dir, "kustomization.yaml")
	portContent := "images:\n- name: registry.example.com:5000/agentboard/dashboard\n  digest: sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n"
	if err := os.WriteFile(portOverlay, []byte(portContent), 0644); err != nil {
		t.Fatal(err)
	}
	portJob := filepath.Join(dir, "job.yaml")
	if err := os.WriteFile(portJob, []byte("apiVersion: batch/v1\nkind: Job\nmetadata:\n  name: m\n"), 0644); err != nil {
		t.Fatal(err)
	}
	portPin := "registry.example.com:5000/agentboard/dashboard@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	_, _, err = runAdm(t, "admin", "rollout", portPin,
		"--overlay", portOverlay, "--image", "registry.example.com:5000/agentboard/dashboard",
		"--deployment", "d", "--namespace", "n", "--migration-job", portJob,
		"--backup-path", filepath.Join(dir, "dump.sql"), "--db-name", "board", "--dry-run")
	if err == nil || cli.ExitCode(err) != 2 {
		t.Fatalf("registry ports must not count as tags, got %v", err)
	}
}

func TestAdminDoctorRejectsBothPinsTargets(t *testing.T) {
	f := newAdmBoard(t)
	dir := admEnv(t, f)
	overlay := filepath.Join(dir, "kustomization.yaml")
	if err := os.WriteFile(overlay, []byte("configMapGenerator:\n- name: cfg\n  literals:\n  - FOO=bar\n"), 0644); err != nil {
		t.Fatal(err)
	}
	compose := filepath.Join(dir, "compose.yaml")
	if err := os.WriteFile(compose, []byte("services:\n  app:\n    environment:\n    - FOO=bar\n"), 0644); err != nil {
		t.Fatal(err)
	}
	applyPath := filepath.Join(dir, "admin.yaml")
	apply := "apiVersion: agentboard.carverauto.dev/v1\nkind: AdminConfig\n" +
		"pins:\n  overlay: " + overlay + "\n  compose: " + compose + "\n"
	if err := os.WriteFile(applyPath, []byte(apply), 0644); err != nil {
		t.Fatal(err)
	}
	if _, _, err := runAdm(t, "admin", "doctor", "-f", applyPath); err == nil || !strings.Contains(err.Error(), "exactly one") {
		t.Fatalf("both pins targets must error, got %v", err)
	}
}

func TestAdminDoctorErrorsWithoutConfigTarget(t *testing.T) {
	f := newAdmBoard(t)
	dir := admEnv(t, f)
	applyPath := filepath.Join(dir, "admin.yaml")
	apply := "apiVersion: agentboard.carverauto.dev/v1\nkind: AdminConfig\n" +
		"config:\n  coordinator_id: coord-one\n"
	if err := os.WriteFile(applyPath, []byte(apply), 0644); err != nil {
		t.Fatal(err)
	}
	if _, _, err := runAdm(t, "admin", "doctor", "-f", applyPath); err == nil || !strings.Contains(err.Error(), "needs overlay or compose") {
		t.Fatalf("config without a target must error, got %v", err)
	}
}

func TestAdminApplyRejectsTaggedPinName(t *testing.T) {
	f := newAdmBoard(t)
	dir := admEnv(t, f)
	overlay := filepath.Join(dir, "kustomization.yaml")
	before := "configMapGenerator:\n- name: cfg\n  literals:\n  - FOO=bar\n"
	if err := os.WriteFile(overlay, []byte(before), 0644); err != nil {
		t.Fatal(err)
	}
	applyPath := filepath.Join(dir, "admin.yaml")
	apply := "apiVersion: agentboard.carverauto.dev/v1\nkind: AdminConfig\n" +
		"pins:\n  overlay: " + overlay + "\n  images:\n  - name: registry.example.com/agentboard/dashboard:v1\n    digest: sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n"
	if err := os.WriteFile(applyPath, []byte(apply), 0644); err != nil {
		t.Fatal(err)
	}
	_, _, err := runAdm(t, "admin", "apply", "-f", applyPath)
	if err == nil || !strings.Contains(err.Error(), "tags rejected") {
		t.Fatalf("must reject tag-qualified pin names, got %v", err)
	}
	raw, _ := os.ReadFile(overlay)
	if string(raw) != before {
		t.Fatalf("rejected file mutated the target")
	}
}

func TestAdminDoctorIsReadOnly(t *testing.T) {
	f := newAdmBoard(t)
	dir := admEnv(t, f)
	overlay := filepath.Join(dir, "kustomization.yaml")
	before := "configMapGenerator:\n- name: cfg\n  literals:\n  - AGENTBOARD_COORDINATOR_ID=old-id\nimages:\n- name: registry.example.com/agentboard/dashboard\n  digest: sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n"
	if err := os.WriteFile(overlay, []byte(before), 0644); err != nil {
		t.Fatal(err)
	}
	applyPath := filepath.Join(dir, "admin.yaml")
	apply := "apiVersion: agentboard.carverauto.dev/v1\nkind: AdminConfig\n" +
		"workers:\n- id: worker-a\n  action: create\n  host: host-a\n  repos:\n    - owner/repo\n  token_file: " + filepath.Join(dir, "missing.token") + "\n" +
		"config:\n  overlay: " + overlay + "\n  coordinator_id: new-id\n" +
		"pins:\n  overlay: " + overlay + "\n  images:\n  - name: registry.example.com/agentboard/dashboard\n    digest: sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n"
	if err := os.WriteFile(applyPath, []byte(apply), 0644); err != nil {
		t.Fatal(err)
	}
	out, _, err := runAdm(t, "admin", "doctor", "-f", applyPath, "--agent-id", "ghost-agent")
	if err != nil {
		t.Fatalf("doctor failed: %v", err)
	}
	for _, want := range []string{"worker-a", "AGENTBOARD_COORDINATOR_ID", "ghost-agent"} {
		if !strings.Contains(out, want) {
			t.Fatalf("doctor must report drift %q:\n%s", want, out)
		}
	}
	raw, _ := os.ReadFile(overlay)
	if string(raw) != before {
		t.Fatalf("doctor mutated the target")
	}
	if f.provisions != 0 {
		t.Fatalf("doctor called a mutating endpoint")
	}
}

func TestAdminConfigQuotedValueConverges(t *testing.T) {
	f := newAdmBoard(t)
	dir := admEnv(t, f)
	overlay := filepath.Join(dir, "kustomization.yaml")
	if err := os.WriteFile(overlay, []byte("configMapGenerator:\n- name: cfg\n  literals:\n  - FOO=bar\n"), 0644); err != nil {
		t.Fatal(err)
	}
	policies := filepath.Join(dir, "policies.json")
	if err := os.WriteFile(policies, []byte(`{"a": 1}`), 0644); err != nil {
		t.Fatal(err)
	}
	set := []string{"admin", "config", "ci-policies", "set", "--file", policies, "--overlay", overlay}
	if _, _, err := runAdm(t, set...); err != nil {
		t.Fatalf("set failed: %v", err)
	}
	out, _, err := runAdm(t, set...)
	if err != nil {
		t.Fatalf("second set failed: %v", err)
	}
	if !strings.Contains(out, "converged") {
		t.Fatalf("quoted value must converge on second run: %s", out)
	}
	spaced := []string{"admin", "config", "coordinator-id", "set", "id with space", "--overlay", overlay}
	if _, _, err := runAdm(t, spaced...); err != nil {
		t.Fatalf("spaced set failed: %v", err)
	}
	out2, _, err := runAdm(t, spaced...)
	if err != nil {
		t.Fatalf("second spaced set failed: %v", err)
	}
	if !strings.Contains(out2, "converged") {
		t.Fatalf("spaced value must converge on second run: %s", out2)
	}
}

func TestAdminDoctorSkipsWorkerAgentCheck(t *testing.T) {
	f := newAdmBoard(t)
	dir := admEnv(t, f)
	token := filepath.Join(dir, "worker.token")
	if err := os.WriteFile(token, []byte("x"), 0600); err != nil {
		t.Fatal(err)
	}
	overlay := filepath.Join(dir, "kustomization.yaml")
	if err := os.WriteFile(overlay, []byte("configMapGenerator:\n- name: cfg\n  literals:\n  - AGENTBOARD_COORDINATOR_ID=coord-one\n"), 0644); err != nil {
		t.Fatal(err)
	}
	applyPath := filepath.Join(dir, "admin.yaml")
	apply := "apiVersion: agentboard.carverauto.dev/v1\nkind: AdminConfig\n" +
		"workers:\n- id: worker-a\n  action: create\n  host: host-a\n  repos:\n    - owner/repo\n  token_file: " + token + "\n" +
		"config:\n  overlay: " + overlay + "\n  coordinator_id: coord-one\n"
	if err := os.WriteFile(applyPath, []byte(apply), 0644); err != nil {
		t.Fatal(err)
	}
	out, _, err := runAdm(t, "admin", "doctor", "-f", applyPath)
	if err != nil {
		t.Fatalf("doctor failed: %v", err)
	}
	if !strings.Contains(out, "converged") {
		t.Fatalf("doctor must converge when only the worker token file is present: %s", out)
	}
	if strings.Contains(out, "absent") {
		t.Fatalf("doctor must not report worker-a as an absent agent: %s", out)
	}
}

func TestAdminDoctorRejectsStrayTargetFlags(t *testing.T) {
	f := newAdmBoard(t)
	dir := admEnv(t, f)
	overlay := filepath.Join(dir, "kustomization.yaml")
	if err := os.WriteFile(overlay, []byte("configMapGenerator:\n- name: cfg\n  literals:\n  - FOO=bar\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if _, _, err := runAdm(t, "admin", "doctor", "--overlay", overlay); err == nil || !strings.Contains(err.Error(), "require -f") {
		t.Fatalf("stray --overlay must error, got %v", err)
	}
	compose := filepath.Join(dir, "compose.yaml")
	if err := os.WriteFile(compose, []byte("services:\n  app:\n    environment:\n    - FOO=bar\n"), 0644); err != nil {
		t.Fatal(err)
	}
	applyPath := filepath.Join(dir, "admin.yaml")
	apply := "apiVersion: agentboard.carverauto.dev/v1\nkind: AdminConfig\n" +
		"config:\n  overlay: " + overlay + "\n  compose: " + compose + "\n  coordinator_id: x\n"
	if err := os.WriteFile(applyPath, []byte(apply), 0644); err != nil {
		t.Fatal(err)
	}
	if _, _, err := runAdm(t, "admin", "doctor", "-f", applyPath); err == nil || !strings.Contains(err.Error(), "exactly one") {
		t.Fatalf("both config targets must error, got %v", err)
	}
}

func TestAdminRolloutMigrationRewritesMatchingRepo(t *testing.T) {
	f := newAdmBoard(t)
	dir := admEnv(t, f)
	admKubectlStub(t, dir)
	t.Setenv("ADMIN_STUB_LOG", filepath.Join(dir, "kubectl.log"))
	overlay := admOverlay(t, dir, admOldDigest)
	job := filepath.Join(dir, "job.yaml")
	content := "apiVersion: batch/v1\nkind: Job\nmetadata:\n  name: agentboard-migrate\nspec:\n  template:\n    spec:\n      restartPolicy: Never\n      containers:\n      - name: sidecar\n        image: busybox:1.36\n      - name: migrate\n        image: registry.example.com/agentboard/dashboard@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n"
	if err := os.WriteFile(job, []byte(content), 0644); err != nil {
		t.Fatal(err)
	}
	dump := filepath.Join(dir, "dump.sql")
	record := filepath.Join(dir, "rollout.json")
	if _, _, err := runAdm(t, admRolloutArgs(overlay, job, dump, record)...); err != nil {
		t.Fatalf("rollout failed: %v", err)
	}
	log, _ := os.ReadFile(filepath.Join(dir, "kubectl.log"))
	if !strings.Contains(string(log), "busybox:1.36") {
		t.Fatalf("sidecar image must be preserved:\n%s", log)
	}
	if !strings.Contains(string(log), admNewPin) {
		t.Fatalf("matching migrate image must be rewritten to the pin:\n%s", log)
	}
	if strings.Contains(string(log), "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") && !strings.Contains(string(log), "get deployment") {
		t.Fatalf("old migrate digest must not remain in the applied Job")
	}
}

func TestAdminRolloutDirectRejectsMultiImage(t *testing.T) {
	f := newAdmBoard(t)
	dir := admEnv(t, f)
	admBinStub(t, dir, "kubectl", "#!/bin/sh\n"+
		"case \" $* \" in\n"+
		"  *\"get deployment\"*) echo \"imgA imgB\"; exit 0;;\n"+
		"esac\n"+
		"exit 0\n")
	admBinStub(t, dir, "pg_dump", "#!/bin/sh\nexit 0\n")
	job := admJobManifest(t, dir)
	dump := filepath.Join(dir, "dump.sql")
	_, _, err := runAdm(t, "admin", "rollout", admNewPin,
		"--direct", "--deployment", "agentboard", "--namespace", "test-ns",
		"--container", "app", "--migration-job", job, "--backup-path", dump, "--db-name", "board",
		"--soak-seconds", "0", "--timeout-seconds", "30")
	if err == nil || !strings.Contains(err.Error(), "multiple container images") {
		t.Fatalf("multi-image live read must error, got %v", err)
	}
}

func TestAdminRolloutBackupRequiresDatabase(t *testing.T) {
	f := newAdmBoard(t)
	dir := admEnv(t, f)
	admKubectlStub(t, dir)
	t.Setenv("ADMIN_STUB_LOG", filepath.Join(dir, "kubectl.log"))
	overlay := admOverlay(t, dir, admOldDigest)
	job := admJobManifest(t, dir)
	dump := filepath.Join(dir, "dump.sql")
	os.Unsetenv("PGDATABASE")
	args := []string{"admin", "rollout", admNewPin,
		"--overlay", overlay, "--image", "registry.example.com/agentboard/dashboard",
		"--deployment", "agentboard", "--namespace", "test-ns",
		"--migration-job", job, "--backup-path", dump,
		"--soak-seconds", "0", "--timeout-seconds", "30"}
	if _, _, err := runAdm(t, args...); err == nil || !strings.Contains(err.Error(), "PGDATABASE") {
		t.Fatalf("missing database must error naming PGDATABASE, got %v", err)
	}
	record := filepath.Join(dir, "rollout.json")
	if _, _, err := runAdm(t, admRolloutArgs(overlay, job, dump, record)...); err != nil {
		t.Fatalf("rollout with --db-name failed: %v", err)
	}
	rec, _ := os.ReadFile(record)
	if !strings.Contains(string(rec), `"backup_database": "board"`) {
		t.Fatalf("record must carry the selected database: %s", rec)
	}
}
