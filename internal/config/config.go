// Package config defines the shared CLI environment and write context.
package config

import (
	"errors"
	"os"
	"regexp"
	"strings"
	"time"
)

var slug = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{0,127}$`)

// Actor is a snapshot of the identity used for one mutation.
type Actor struct {
	ID      string `json:"agent_id"`
	Model   string `json:"model"`
	Harness string `json:"harness"`
}

func (a Actor) Validate() error {
	if !ValidID(a.ID) || strings.TrimSpace(a.Model) == "" || strings.TrimSpace(a.Harness) == "" {
		return errors.New("writes require a valid agent ID, model, and harness")
	}
	return nil
}

func ValidID(id string) bool { return slug.MatchString(id) }

type Config struct {
	Token                  string `json:"-"`
	TokenFile              string `json:"-"`
	AccessServiceTokenFile string `json:"-"`
	URL                    string
	CAFile                 string
	Actor                  Actor
	ClaimTTL               time.Duration
	StaleAfter             time.Duration
}

func FromEnv() (Config, error) {
	cfg := Config{
		Token: os.Getenv("AGENTBOARD_TOKEN"), TokenFile: os.Getenv("AGENTBOARD_TOKEN_FILE"),
		AccessServiceTokenFile: os.Getenv("AGENTBOARD_ACCESS_SERVICE_TOKEN_FILE"),
		URL:                    os.Getenv("AGENTBOARD_URL"), CAFile: os.Getenv("AGENTBOARD_CA_FILE"),
		Actor: Actor{
			ID: os.Getenv("AGENT_ID"), Model: os.Getenv("AGENTBOARD_MODEL"),
			Harness: os.Getenv("AGENTBOARD_HARNESS"),
		},
		ClaimTTL: 2 * time.Hour, StaleAfter: 10 * time.Minute,
	}
	if cfg.URL == "" {
		cfg.URL = "http://localhost:4000"
	}
	var err error
	if value := os.Getenv("AGENTBOARD_CLAIM_TTL"); value != "" {
		cfg.ClaimTTL, err = PositiveDuration(value)
		if err != nil {
			return cfg, errors.New("AGENTBOARD_CLAIM_TTL must be a positive duration")
		}
	}
	if value := os.Getenv("AGENTBOARD_STALE_AFTER"); value != "" {
		cfg.StaleAfter, err = PositiveDuration(value)
		if err != nil {
			return cfg, errors.New("AGENTBOARD_STALE_AFTER must be a positive duration")
		}
	}
	return cfg, nil
}

func PositiveDuration(value string) (time.Duration, error) {
	d, err := time.ParseDuration(value)
	if err != nil || d <= 0 {
		return 0, errors.New("duration must be positive")
	}
	return d, nil
}
