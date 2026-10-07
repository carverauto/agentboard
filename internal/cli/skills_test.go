package cli_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/carverauto/agentboard/internal/cli"
)

func runSkillInstall(t *testing.T, dir string) ([]byte, error) {
	t.Helper()
	cmd := cli.NewRoot()
	var output bytes.Buffer
	cmd.SetOut(&output)
	cmd.SetArgs([]string{"skills", "install", "--dir", dir, "--json"})
	err := cmd.Execute()
	return output.Bytes(), err
}

// Protects the offline filesystem contract through the real command, including
// documentation links consumed from the emitted, installed Markdown payload.
func TestSkillsInstallOfflineAndRepeat(t *testing.T) {
	var calls atomic.Int32
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { calls.Add(1); w.WriteHeader(500) }))
	defer api.Close()
	t.Setenv("AGENTBOARD_URL", api.URL)
	t.Setenv("AGENT_ID", "")
	t.Setenv("AGENTBOARD_MODEL", "")
	t.Setenv("AGENTBOARD_HARNESS", "")
	t.Setenv("XDG_DATA_HOME", t.TempDir())
	dir := filepath.Join(t.TempDir(), "skills")
	var first []byte
	for n := 0; n < 2; n++ {
		output, err := runSkillInstall(t, dir)
		if err != nil {
			t.Fatal(err)
		}
		var result struct {
			Directory string   `json:"directory"`
			Bundle    string   `json:"bundle"`
			Skills    []string `json:"skills"`
		}
		if err := json.Unmarshal(output, &result); err != nil {
			t.Fatal(err)
		}
		if len(result.Skills) != 12 || result.Directory != dir {
			t.Fatalf("unexpected installation: %s", output)
		}
		if n == 0 {
			first = append([]byte(nil), output...)
		} else if !bytes.Equal(first, output) {
			t.Fatal("repeat install did not retain the same bundle")
		}
		for _, name := range result.Skills {
			link, err := os.Readlink(filepath.Join(dir, name))
			if err != nil {
				t.Fatal(err)
			}
			if link != filepath.Join(result.Bundle, "skills", name) {
				t.Fatalf("skill points outside reported bundle: %s", link)
			}
			body, err := os.ReadFile(filepath.Join(dir, name, "SKILL.md"))
			if err != nil || len(body) == 0 {
				t.Fatalf("skill not readable: %s: %v", name, err)
			}
			// Relative file references are an intentional installed-output contract;
			// resolve the emitted Markdown links rather than asserting source tokens.
			text := string(body)
			for _, fragment := range strings.Split(text, "](")[1:] {
				link := strings.SplitN(fragment, ")", 2)[0]
				if strings.HasPrefix(link, "https:") {
					continue
				}
				if _, err := os.Stat(filepath.Join(dir, name, link)); err != nil {
					t.Fatalf("broken installed documentation link %s/%s: %v", name, link, err)
				}
			}
		}
	}
	if calls.Load() != 0 {
		t.Fatalf("offline installation made %d API requests", calls.Load())
	}
}

func TestSkillsInstallPreservesConflictingOrEditedContent(t *testing.T) {
	for _, scenario := range []string{"foreign-directory", "foreign-link", "edited-bundle"} {
		t.Run(scenario, func(t *testing.T) {
			t.Setenv("XDG_DATA_HOME", t.TempDir())
			dir := filepath.Join(t.TempDir(), "skills")
			if err := os.MkdirAll(dir, 0755); err != nil {
				t.Fatal(err)
			}
			target := filepath.Join(dir, "agentboard")
			if scenario == "edited-bundle" {
				if _, err := runSkillInstall(t, dir); err != nil {
					t.Fatal(err)
				}
			} else if scenario == "foreign-link" {
				foreign := t.TempDir()
				if err := os.Symlink(foreign, target); err != nil {
					t.Fatal(err)
				}
			} else {
				if err := os.Mkdir(target, 0755); err != nil {
					t.Fatal(err)
				}
			}
			path := filepath.Join(target, "SKILL.md")
			original := []byte("user-maintained workflow\n")
			if err := os.WriteFile(path, original, 0644); err != nil {
				t.Fatal(err)
			}
			output, err := runSkillInstall(t, dir)
			if err == nil || len(output) != 0 {
				t.Fatalf("conflict accepted: %s, %v", output, err)
			}
			got, err := os.ReadFile(path)
			if err != nil || !bytes.Equal(got, original) {
				t.Fatalf("user workflow was changed: %s, %v", got, err)
			}
			if scenario != "edited-bundle" {
				if _, err := os.Lstat(filepath.Join(dir, "agentboard-captain")); !os.IsNotExist(err) {
					t.Fatal("preflight conflict partially installed other skills")
				}
			}
		})
	}
}
