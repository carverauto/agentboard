package cli_test

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/carverauto/agentboard/internal/cli"
)

const intakeCaptain = "fixture-intake-captain-0123456789abcdef"

func intakeView(state string) string {
	return fmt.Sprintf(`{"intake":{"id":"11111111-1111-4111-8111-111111111111","request_key":"k1","filer_id":"captain","items":[{"id":"22222222-2222-4222-8222-222222222222","position":0,"task_id":"fix-it-222222222222","task_status":"open","repository":"acme/widgets","issue":true,"issue_state":%q,"issue_url":null,"reason":null,"last_error":null}]},"replayed":false}`, state)
}

// intakeServer serves meta plus one handler and records each intake request.
func intakeServer(t *testing.T, schema int, handler http.HandlerFunc) {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.Header.Get("Authorization") != "Bearer "+intakeCaptain {
			t.Errorf("intake must use the captain capability, got %q on %s", r.Header.Get("Authorization"), r.URL.Path)
		}
		if r.URL.Path == "/api/v1/meta" {
			fmt.Fprintf(w, `{"api_version":1,"schema_version":%d}`, schema)
			return
		}
		handler(w, r)
	}))
	t.Cleanup(server.Close)
	token := filepath.Join(t.TempDir(), "captain.token")
	if err := os.WriteFile(token, []byte(intakeCaptain+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("AGENTBOARD_URL", server.URL)
	// Intake needs no self-reported actor; an ordinary token must not leak in.
	t.Setenv("AGENT_ID", "")
	t.Setenv("AGENTBOARD_MODEL", "")
	t.Setenv("AGENTBOARD_HARNESS", "")
	t.Setenv("AGENTBOARD_TOKEN", "ordinary-not-captain")
	t.Setenv("AGENTBOARD_CAPTAIN_TOKEN_FILE", token)
}

func intakeCommand(args ...string) (string, error) {
	root := cli.NewRoot()
	var output bytes.Buffer
	root.SetOut(&output)
	root.SetErr(&bytes.Buffer{})
	root.SetArgs(append([]string{"intake"}, args...))
	err := root.Execute()
	return output.String(), err
}

func TestIntakeFileSendsOneItemFromFlags(t *testing.T) {
	var got map[string]any
	intakeServer(t, 45, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/api/v1/intake" {
			t.Errorf("unexpected %s %s", r.Method, r.URL.Path)
		}
		raw, _ := io.ReadAll(r.Body)
		if err := json.Unmarshal(raw, &got); err != nil {
			t.Error(err)
		}
		fmt.Fprint(w, intakeView("pending"))
	})
	out, err := intakeCommand("file", "--request-key", "k1", "--repo", "acme/widgets", "--title", "Fix it", "--body", "Details", "--priority", "1", "--label", "bug", "--label", "ui")
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]any{"request_key": "k1", "items": []any{map[string]any{"repository": "acme/widgets", "title": "Fix it", "body": "Details", "priority": float64(1), "labels": []any{"bug", "ui"}, "issue": true}}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("payload = %#v", got)
	}
	if !strings.Contains(out, "fix-it-222222222222") || !strings.Contains(out, "issue=pending") {
		t.Fatalf("human output = %q", out)
	}
}

func TestIntakeFileCardOnlyOmitsDefaults(t *testing.T) {
	var got map[string]any
	intakeServer(t, 45, func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &got)
		fmt.Fprint(w, intakeView("none"))
	})
	if _, err := intakeCommand("file", "--request-key", "k2", "--repo", "acme/widgets", "--title", "Card only", "--no-issue"); err != nil {
		t.Fatal(err)
	}
	item := got["items"].([]any)[0].(map[string]any)
	if item["issue"] != false || item["priority"] != nil || item["body"] != nil || item["labels"] != nil {
		t.Fatalf("item = %#v", item)
	}
}

func TestIntakeFileRefusesBeforeAnyRequest(t *testing.T) {
	intakeServer(t, 45, func(w http.ResponseWriter, r *http.Request) {
		t.Errorf("no request expected, got %s %s", r.Method, r.URL.Path)
	})
	items := filepath.Join(t.TempDir(), "items.json")
	if err := os.WriteFile(items, []byte(`[]`), 0600); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{
		{"file", "--repo", "acme/widgets", "--title", "No key"},
		{"file", "--request-key", "k", "--title", "No repo"},
		{"file", "--request-key", "k", "--file", items},
		{"file", "--request-key", "k", "--file", items, "--repo", "acme/widgets"},
		{"resolve", "11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222", "--action", "retry"},
	} {
		if _, err := intakeCommand(args...); err == nil {
			t.Errorf("%v: expected refusal", args)
		}
	}
}

func TestIntakeRequiresSchema45(t *testing.T) {
	intakeServer(t, 44, func(w http.ResponseWriter, r *http.Request) {
		t.Errorf("no intake request expected on schema 44")
	})
	_, err := intakeCommand("status", "11111111-1111-4111-8111-111111111111")
	if err == nil || cli.ExitCode(err) != 1 || !strings.Contains(err.Error(), "schema") {
		t.Fatalf("err = %v", err)
	}
}

func TestIntakeStatusSignalsUncertainty(t *testing.T) {
	state := "uncertain"
	intakeServer(t, 45, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/api/v1/intake/11111111-1111-4111-8111-111111111111" {
			t.Errorf("unexpected %s %s", r.Method, r.URL.Path)
		}
		fmt.Fprint(w, intakeView(state))
	})
	_, err := intakeCommand("status", "11111111-1111-4111-8111-111111111111")
	if cli.ExitCode(err) != 5 {
		t.Fatalf("uncertain exit = %d (%v)", cli.ExitCode(err), err)
	}
	state = "created"
	if _, err = intakeCommand("status", "11111111-1111-4111-8111-111111111111"); err != nil {
		t.Fatalf("created err = %v", err)
	}
}

func TestIntakeConflictExitsFour(t *testing.T) {
	intakeServer(t, 45, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusConflict)
		fmt.Fprint(w, `{"error":{"code":"conflict","message":"Request key was already used for a different intake payload"}}`)
	})
	_, err := intakeCommand("file", "--request-key", "k1", "--repo", "acme/widgets", "--title", "Changed")
	if cli.ExitCode(err) != 4 {
		t.Fatalf("exit = %d (%v)", cli.ExitCode(err), err)
	}
}

func TestIntakeCancelAndResolveRoutes(t *testing.T) {
	var paths []string
	var bodies []string
	intakeServer(t, 45, func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		paths = append(paths, r.Method+" "+r.URL.Path)
		bodies = append(bodies, string(raw))
		fmt.Fprint(w, intakeView("abandoned"))
	})
	request, item := "11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"
	if _, err := intakeCommand("--json", "cancel", request, "--item", item); err != nil {
		t.Fatal(err)
	}
	if _, err := intakeCommand("--json", "resolve", request, item, "--action", "abandon"); err != nil {
		t.Fatal(err)
	}
	wantPaths := []string{"POST /api/v1/intake/" + request + "/cancel", "POST /api/v1/intake/" + request + "/items/" + item + "/abandon"}
	if !reflect.DeepEqual(paths, wantPaths) || bodies[0] != `{"items":["`+item+`"]}` || bodies[1] != `{}` {
		t.Fatalf("paths=%v bodies=%v", paths, bodies)
	}
}

func TestIntakeImportSendsSelection(t *testing.T) {
	var got []map[string]any
	intakeServer(t, 45, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/api/v1/intake/import" {
			t.Errorf("unexpected %s %s", r.Method, r.URL.Path)
		}
		raw, _ := io.ReadAll(r.Body)
		var body map[string]any
		_ = json.Unmarshal(raw, &body)
		got = append(got, body)
		fmt.Fprint(w, `{"intake":{"id":"11111111-1111-4111-8111-111111111111","request_key":"burn-1","items":[],"import":{"bounded":true,"next_page":21,"skipped":[{"issue_number":7,"reason":"closed"},{"issue_number":9,"reason":"already_linked","task_id":"fix-9-abc"}]}},"replayed":false}`)
	})
	out, err := intakeCommand("import", "--request-key", "burn-1", "--repo", "acme/widgets", "--issue", "12", "--issue", "7", "--priority", "1")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := intakeCommand("--json", "import", "--request-key", "burn-2", "--repo", "acme/widgets", "--label", "bug", "--limit", "5"); err != nil {
		t.Fatal(err)
	}
	if _, err := intakeCommand("--json", "import", "--request-key", "burn-3", "--repo", "acme/widgets"); err != nil {
		t.Fatal(err)
	}
	if _, err := intakeCommand("--json", "import", "--request-key", "burn-4", "--repo", "acme/widgets", "--start-page", "21"); err != nil {
		t.Fatal(err)
	}
	want := []map[string]any{
		{"request_key": "burn-1", "repository": "acme/widgets", "issues": []any{float64(12), float64(7)}, "priority": float64(1)},
		{"request_key": "burn-2", "repository": "acme/widgets", "labels": []any{"bug"}, "limit": float64(5)},
		{"request_key": "burn-3", "repository": "acme/widgets"},
		{"request_key": "burn-4", "repository": "acme/widgets", "start_page": float64(21)},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("payloads = %#v", got)
	}
	for _, line := range []string{"#7", "closed", "#9", "already_linked", "fix-9-abc", "page bound", "--start-page 21"} {
		if !strings.Contains(out, line) {
			t.Fatalf("human output lacks %q: %q", line, out)
		}
	}
}

func TestIntakeImportRefusesBeforeAnyRequest(t *testing.T) {
	intakeServer(t, 45, func(w http.ResponseWriter, r *http.Request) {
		t.Errorf("no request expected, got %s %s", r.Method, r.URL.Path)
	})
	for _, args := range [][]string{
		{"import", "--repo", "acme/widgets"},
		{"import", "--request-key", "k"},
		{"import", "--request-key", "k", "--repo", "acme/widgets", "--issue", "3", "--label", "bug"},
		{"import", "--request-key", "k", "--repo", "acme/widgets", "--issue", "3", "--limit", "2"},
		{"import", "--request-key", "k", "--repo", "acme/widgets", "--issue", "3", "--start-page", "2"},
		{"import", "--request-key", "k", "--repo", "acme/widgets", "--start-page", "0"},
	} {
		if _, err := intakeCommand(args...); err == nil {
			t.Errorf("%v: expected refusal", args)
		}
	}
}

func TestIntakeHelperTokenRequiresSchema48WhileResolveRequiresCaptain(t *testing.T) {
	helperToken := "abt_" + strings.Repeat("h", 43)
	schema := 48
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path == "/api/v1/meta" {
			fmt.Fprintf(w, `{"api_version":1,"schema_version":%d}`, schema)
			return
		}
		if r.Header.Get("Authorization") != "Bearer "+helperToken {
			t.Errorf("expected helper bearer, got %q", r.Header.Get("Authorization"))
		}
		fmt.Fprint(w, intakeView("none"))
	}))
	defer server.Close()
	t.Setenv("AGENTBOARD_URL", server.URL)
	t.Setenv("AGENT_ID", "")
	t.Setenv("AGENTBOARD_MODEL", "")
	t.Setenv("AGENTBOARD_HARNESS", "")
	t.Setenv("AGENTBOARD_CAPTAIN_TOKEN_FILE", "")
	t.Setenv("AGENTBOARD_TOKEN", helperToken)

	if _, err := intakeCommand("file", "--request-key", "h1", "--repo", "acme/widgets", "--title", "Helper card", "--no-issue"); err != nil {
		t.Fatalf("helper file err = %v", err)
	}
	if _, err := intakeCommand("resolve", "11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222", "--action", "abandon"); err == nil || !strings.Contains(err.Error(), "protected captain") {
		t.Fatalf("expected captain requirement on resolve, got %v", err)
	}
	schema = 47
	if _, err := intakeCommand("status", "11111111-1111-4111-8111-111111111111"); err == nil || !strings.Contains(err.Error(), "schema") {
		t.Fatalf("expected schema 48 error for helper intake, got %v", err)
	}
}
