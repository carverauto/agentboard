package cli

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/carverauto/agentboard/internal/seatops"
)

// TestTreehouseLeasesListsEachPoolFromItsOwnWorktree runs a treehouse stand-in
// that, like the real one, fails outside a repository (a launchd job runs in
// /) and lists only the pool of the repository it runs in.
func TestTreehouseLeasesListsEachPoolFromItsOwnWorktree(t *testing.T) {
	dir := t.TempDir()
	bin := filepath.Join(dir, "treehouse")
	script := `#!/bin/sh
here=$(pwd -P)
case "$here" in */.treehouse/*) ;; *) echo "not in a git or jj repository" >&2; exit 1 ;; esac
pool=$(basename "$(dirname "$(dirname "$here")")")
printf '[{"path":"%s","status":"leased","lease_holder":"holder-%s"},{"path":"/elsewhere","status":"available"}]\n' "$here" "$pool"
`
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	root := filepath.Join(dir, "pool-root")
	for _, wt := range []string{"repoa-111/2/repoa", "repoa-111/1/repoa", "repob-222/1/repob"} {
		path := filepath.Join(root, ".treehouse", wt)
		if err := os.MkdirAll(path, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(path, ".git"), []byte("gitdir: elsewhere\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	// A pool without worktrees and a stray file hold no leases.
	if err := os.MkdirAll(filepath.Join(root, ".treehouse", "empty-333", "1"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, ".treehouse", "state.json"), []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Chdir("/")
	leases, err := treehouseLeases{binary: bin}.List(context.Background(), root)
	if err != nil {
		t.Fatal(err)
	}
	real, err := filepath.EvalSymlinks(root)
	if err != nil {
		t.Fatal(err)
	}
	want := []seatops.Lease{
		{Path: filepath.Join(real, ".treehouse", "repoa-111/1/repoa"), Holder: "holder-repoa-111"},
		{Path: filepath.Join(real, ".treehouse", "repob-222/1/repob"), Holder: "holder-repob-222"},
	}
	if !reflect.DeepEqual(leases, want) {
		t.Fatalf("leases %+v, want %+v", leases, want)
	}
	if leases, err := (treehouseLeases{binary: bin}).List(context.Background(), filepath.Join(dir, "missing")); err != nil || leases != nil {
		t.Fatalf("missing root: %+v %v", leases, err)
	}
}
