package config_test

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/carverauto/agentboard/internal/config"
)

func TestAccessServiceTokenFileFromEnvIsPrivate(t *testing.T) {
	t.Setenv("AGENTBOARD_ACCESS_SERVICE_TOKEN_FILE", "/protected/access-fixture.json")
	t.Setenv("AGENTBOARD_TOKEN", "board-credential-fixture")
	t.Setenv("AGENTBOARD_TOKEN_FILE", "/protected/board-fixture")
	t.Setenv("AGENTBOARD_CLAIM_TTL", "")
	t.Setenv("AGENTBOARD_STALE_AFTER", "")
	cfg, err := config.FromEnv()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.AccessServiceTokenFile != "/protected/access-fixture.json" {
		t.Fatal("service credential file environment setting not loaded")
	}
	data, err := json.Marshal(cfg)
	if err != nil {
		t.Fatal(err)
	}
	for _, private := range []string{cfg.Token, cfg.TokenFile, cfg.AccessServiceTokenFile} {
		if strings.Contains(string(data), private) {
			t.Fatal("configuration JSON exposed a credential or protected path")
		}
	}
}

func TestAccessServiceTokenIsOptional(t *testing.T) {
	t.Setenv("AGENTBOARD_ACCESS_SERVICE_TOKEN_FILE", "")
	t.Setenv("AGENTBOARD_CLAIM_TTL", "")
	t.Setenv("AGENTBOARD_STALE_AFTER", "")
	cfg, err := config.FromEnv()
	if err != nil || cfg.AccessServiceTokenFile != "" {
		t.Fatalf("unexpected default Access configuration: %v", err)
	}
}
