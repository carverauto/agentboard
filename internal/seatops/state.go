package seatops

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

// SeatState is the per-seat memory kept between runs, keyed by agent ID.
type SeatState struct {
	// Session is the native session the timestamps below belong to; a new
	// session in the same pane starts a fresh record.
	Session     string    `json:"session,omitempty"`
	IdleSince   time.Time `json:"idle_since,omitzero"`
	LastNudgeAt time.Time `json:"last_nudge_at,omitzero"`
	LastSig     string    `json:"last_sig,omitempty"`
	LastMode    string    `json:"last_mode,omitempty"`
}

// State is the whole state file.
type State struct {
	LastRun time.Time            `json:"last_run,omitzero"`
	Seats   map[string]SeatState `json:"seats"`
}

// Lock holds an exclusive advisory lock beside the state file so overlapping
// scheduled runs skip instead of double-nudging.
type Lock struct{ file *os.File }

// ErrLocked means another run holds the lock.
var ErrLocked = errors.New("another seat run holds the lock")

func AcquireLock(stateFile string) (*Lock, error) {
	if err := os.MkdirAll(filepath.Dir(stateFile), 0o700); err != nil {
		return nil, err
	}
	file, err := os.OpenFile(stateFile+".lock", os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		file.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, ErrLocked
		}
		return nil, err
	}
	return &Lock{file: file}, nil
}

func (l *Lock) Release() {
	_ = syscall.Flock(int(l.file.Fd()), syscall.LOCK_UN)
	_ = l.file.Close()
}

func LoadState(path string) (State, error) {
	state := State{Seats: map[string]SeatState{}}
	raw, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return state, nil
	}
	if err != nil {
		return state, err
	}
	if err := json.Unmarshal(raw, &state); err != nil {
		return State{Seats: map[string]SeatState{}}, fmt.Errorf("%s: %w", path, err)
	}
	if state.Seats == nil {
		state.Seats = map[string]SeatState{}
	}
	return state, nil
}

// Save writes atomically: temp file, fsync, rename.
func (s State) Save(path string) error { return saveJSON(path, s) }

// saveJSON writes value as indented JSON atomically: temp file, fsync, rename.
func saveJSON(path string, value any) error {
	raw, err := json.MarshalIndent(value, "", " ")
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".seat-ops-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(raw); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}
