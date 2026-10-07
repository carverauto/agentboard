package worker

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
)

type Journal struct {
	Version int     `json:"version"`
	Key     string  `json:"reservation_key"`
	Phase   string  `json:"phase"`
	Batch   *Batch  `json:"batch,omitempty"`
	Outcome string  `json:"outcome,omitempty"`
	Reason  string  `json:"reason,omitempty"`
	Binding Binding `json:"binding"`
}

func NewKey() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic("cryptographic randomness unavailable")
	}
	return hex.EncodeToString(b[:])
}
func JournalPath(cfg Config, b Binding) string { return filepath.Join(cfg.JournalDir, b.Agent+".json") }
func LoadJournal(cfg Config, b Binding) (*Journal, error) {
	path := JournalPath(cfg, b)
	if _, err := os.Lstat(path); os.IsNotExist(err) {
		return nil, nil
	}
	data, err := ReadProtected(path, 1<<20)
	if err != nil {
		return nil, err
	}
	var j Journal
	if json.Unmarshal(data, &j) != nil || j.Version != Protocol || j.Key == "" || j.Binding.Agent != b.Agent {
		return nil, errors.New("invalid crash journal; dispatch disabled")
	}
	return &j, nil
}
