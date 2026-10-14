package seatops

import (
	"context"
	"strings"
	"testing"
)

// The work nudge restates the whole check-in, including the coordination
// channel and Context, so a seat that skipped them is pointed back each time.
func TestNudgeWorkPromptIncludesPeerCoordination(t *testing.T) {
	cfg := testConfig(t)
	board, host := oneIdleSeat()
	if _, err := Nudge(context.Background(), board, host, cfg, t0, true); err != nil {
		t.Fatal(err)
	}
	if len(host.prompts) != 1 {
		t.Fatalf("prompts = %q", host.prompts)
	}
	for _, want := range []string{"agentboard msg list --unread", "agentboard chat read --coordination", "agentboard context feed", "reply where it concerns you"} {
		if !strings.Contains(host.prompts[0], want) {
			t.Fatalf("work nudge lacks %q: %q", want, host.prompts[0])
		}
	}
}
