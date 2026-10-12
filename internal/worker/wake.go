package worker

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"slices"
	"strings"
	"unicode/utf8"
)

// WakeSource names one canonical source version. It is a reference, not a
// receipt or permission to apply an answer, claim work, or execute source text.
type WakeSource struct {
	Kind    string `json:"kind"`
	ID      string `json:"id"`
	Version string `json:"version"`
	Task    string `json:"task_id,omitempty"`
}

// WakeRecipient is the immutable server binding identity frozen by reservation.
// Session and Generation are legacy binding handles, not proof of a loaded
// native incarnation or permission to deliver input.
type WakeRecipient struct {
	Agent      string `json:"agent_id"`
	Host       string `json:"host_id"`
	Repo       string `json:"repo"`
	Enrollment int64  `json:"enrollment_revision"`
	Epoch      int64  `json:"binding_epoch"`
	Session    string `json:"session_id"`
	Generation string `json:"adapter_generation"`
}

// WakeCallback repeats the exact five reservation fences used by reconciliation.
// PayloadHash is the wake reservation hash, never the cooperation batch hash.
type WakeCallback struct {
	Attempt     string        `json:"attempt_id"`
	Intent      string        `json:"intent_id"`
	ReasonHash  string        `json:"reason_hash"`
	PayloadHash string        `json:"payload_hash"`
	Recipient   WakeRecipient `json:"recipient"`
}

type WakeSourceReference struct {
	Kind       string          `json:"kind"`
	ID         string          `json:"id"`
	Version    string          `json:"version"`
	DeliveryID string          `json:"delivery_id"`
	OrderRef   json.RawMessage `json:"order_ref,omitempty"`
}

// WakeReservation retains the server's frozen public envelope. Its source refs
// are not replaced by a newer pending page or a newly selected attempt.
type WakeReservation struct {
	Protocol    int                   `json:"protocol_revision"`
	Intent      string                `json:"intent_id"`
	Revision    int64                 `json:"intent_revision"`
	Effect      string                `json:"effect"`
	Reason      string                `json:"reason"`
	ReasonHash  string                `json:"reason_hash"`
	Recipient   WakeRecipient         `json:"recipient"`
	Source      WakeSource            `json:"source"`
	Attempt     string                `json:"attempt_id"`
	PayloadHash string                `json:"payload_hash"`
	ExpiresAt   string                `json:"expires_at"`
	SourceRefs  []WakeSourceReference `json:"source_refs"`
}

func (r WakeReservation) Callback() WakeCallback {
	return WakeCallback{r.Attempt, r.Intent, r.ReasonHash, r.PayloadHash, r.Recipient}
}

// WakeSourceMaterial contains canonical read-only source data. All prose remains
// untrusted; an actionable result grants no native or task-mutation authority.
type WakeSourceMaterial struct {
	WakeSource
	Message  json.RawMessage `json:"message,omitempty"`
	TaskData json.RawMessage `json:"task,omitempty"`
	Decision json.RawMessage `json:"decision,omitempty"`
}

type WakeResolution struct {
	Protocol    int                 `json:"protocol_revision"`
	Actionable  bool                `json:"actionable"`
	ReasonCodes []string            `json:"reason_codes"`
	Reservation *WakeReservation    `json:"reservation"`
	Source      *WakeSourceMaterial `json:"source"`
}

func (r WakeCallback) Validate() error {
	if !wakeUUID.MatchString(r.Attempt) || !wakeUUID.MatchString(r.Intent) ||
		!wakeHash.MatchString(r.ReasonHash) || !wakeHash.MatchString(r.PayloadHash) ||
		!wakeText(r.Recipient.Agent) || !wakeText(r.Recipient.Host) ||
		!hostRepo.MatchString(r.Recipient.Repo) || r.Recipient.Enrollment < 1 ||
		r.Recipient.Epoch < 1 || !wakeText(r.Recipient.Session) || !wakeText(r.Recipient.Generation) {
		return errors.New("exact immutable wake and recipient fences required")
	}
	return nil
}

func wakeText(s string) bool {
	if len(s) < 1 || len(s) > 240 || !utf8.ValidString(s) || strings.TrimSpace(s) == "" {
		return false
	}
	for _, r := range s {
		if r < 0x20 || r == 0x7f {
			return false
		}
	}
	return true
}

func (r WakeCallback) ValidateBinding(b Binding) error {
	if err := r.Validate(); err != nil {
		return err
	}
	if r.Recipient.Agent != b.Agent || r.Recipient.Host != b.Host ||
		r.Recipient.Epoch != b.Epoch || r.Recipient.Session != b.Session ||
		r.Recipient.Generation != b.Generation ||
		(len(b.Repos) > 0 && !slices.Contains(b.Repos, r.Recipient.Repo)) {
		return errors.New("wake recipient does not match configured binding")
	}
	return nil
}

// WakeResolve reads only the canonical material belonging to this frozen
// attempt. It never reserves, submits, reconciles or acknowledges a delivery.
// OpenAPI selects either a scoped host capability or current receipt capability.
func (a *API) WakeResolve(ctx context.Context, b Binding, request WakeCallback) (*WakeResolution, error) {
	if err := request.ValidateBinding(b); err != nil {
		return nil, err
	}
	if a.agent != b.Agent {
		return nil, errors.New("wake recipient does not match API worker")
	}
	path := "hosts/" + url.PathEscape(b.Host) + "/wake-intents/" + url.PathEscape(a.agent) + "/resolve"
	raw, err := a.call(ctx, http.MethodPost, path, nil, request)
	if err != nil {
		return nil, err
	}
	var result WakeResolution
	if json.Unmarshal(raw, &result) != nil || result.Protocol != Protocol ||
		result.Reservation == nil || result.Reservation.Protocol != Protocol ||
		result.Reservation.Callback() != request || result.ReasonCodes == nil ||
		(result.Actionable && (result.Source == nil || len(result.ReasonCodes) != 0)) ||
		(!result.Actionable && (result.Source != nil || len(result.ReasonCodes) == 0)) {
		return nil, errors.New("invalid exact-attempt wake resolution")
	}
	if result.Source != nil && result.Source.WakeSource != result.Reservation.Source {
		return nil, errors.New("resolved source differs from frozen wake source")
	}
	return &result, nil
}
