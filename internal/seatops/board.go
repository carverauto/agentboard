package seatops

import (
	"context"
	"time"
)

// BoardAgent is the slice of an agent record the seat operations read.
type BoardAgent struct {
	ID              string     `json:"id"`
	Harness         string     `json:"harness"`
	Kind            string     `json:"kind"`
	RetiredAt       *time.Time `json:"retired_at"`
	RoutingEligible bool       `json:"routing_eligible"`
	Availability    struct {
		State string `json:"state"`
	} `json:"availability"`
}

// Task is the slice of a task record the seat operations read.
type Task struct {
	ID             string     `json:"id"`
	Status         string     `json:"status"`
	Priority       *int       `json:"priority"`
	AssigneeID     string     `json:"assignee_id"`
	ClaimedAt      *time.Time `json:"claimed_at"`
	ClaimExpired   bool       `json:"claim_expired"`
	CreatedAt      time.Time  `json:"created_at"`
	Revision       int64      `json:"revision"`
	HeldByDecision bool       `json:"held_by_decision"`
}

// Message is the slice of an inbox message the seat operations read.
type Message struct {
	ID        int64     `json:"id"`
	SenderID  string    `json:"sender_id"`
	TaskID    string    `json:"task_id"`
	CreatedAt time.Time `json:"created_at"`
}

// Board is the read-only board view. Implementations page fully.
type Board interface {
	Agents(ctx context.Context) ([]BoardAgent, error)
	// OwnedTasks returns the agent's assigned/open/in_progress/blocked/review tasks.
	OwnedTasks(ctx context.Context, agentID string) ([]Task, error)
	Unread(ctx context.Context, agentID string) ([]Message, error)
	// LastBody returns the newest non-empty event body of a task and its time.
	LastBody(ctx context.Context, taskID string) (string, time.Time, error)
}

// OpenStatuses are the task statuses a seat still owns work in.
var OpenStatuses = map[string]bool{"assigned": true, "open": true, "in_progress": true, "blocked": true, "review": true}

func priority(t Task) int {
	if t.Priority == nil {
		return 9
	}
	return *t.Priority
}

func claimed(t Task) bool {
	return t.Status == "in_progress" || (t.ClaimedAt != nil && !t.ClaimExpired)
}
