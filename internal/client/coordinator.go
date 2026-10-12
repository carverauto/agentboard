package client

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
)

var coordinatorDecisionID = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

// CoordinatorJSON advertises revision 1 only for the closed runner operation
// set. It never accepts a captain capability or worker runtime credential.
// The request-local copy cannot change headers on concurrent ordinary calls.
// Compatibility bootstrap remains the existing public JSON GET of "meta".
func (c *Client) CoordinatorJSON(ctx context.Context, method, path string, query url.Values, payload any) (json.RawMessage, error) {
	if c.token == "" || c.captain || c.workerCaptain || c.workerProtocol != "" {
		return nil, errors.New("coordinator operations require an ordinary coordinator_runner bearer")
	}
	decision, exact := strings.CutPrefix(path, "coordinator/decisions/")
	allowed := method == http.MethodGet && (path == "coordinator/tick" || exact && coordinatorDecisionID.MatchString(decision)) ||
		method == http.MethodPost && (path == "coordinator/ack" || path == "coordinator/heartbeat")
	if !allowed {
		return nil, errors.New("unsupported coordinator operation")
	}
	request := *c
	request.coordinatorProtocol = "1"
	return request.JSON(ctx, method, path, query, payload)
}

// CoordinatorSelftestRead is a closed, read-only diagnostic transport. Wire
// budgets are enforced before redaction, including on error responses.
func (c *Client) CoordinatorSelftestRead(ctx context.Context, path string) (json.RawMessage, error) {
	if c.token == "" || c.captain || c.workerCaptain || c.workerProtocol != "" {
		return nil, errors.New("coordinator selftest requires an ordinary runner bearer")
	}
	request := *c
	var query url.Values
	maxBytes := 16384
	switch path {
	case "meta":
	case "coordinator/tick":
		request.coordinatorProtocol = "1"
		maxBytes = 4096
		query = url.Values{"limit": {"1"}, "max_bytes": {"4096"}}
	default:
		return nil, errors.New("unsupported coordinator selftest read")
	}
	ctx, cancel := context.WithTimeout(ctx, requestBudget)
	defer cancel()
	resp, err := request.open(ctx, http.MethodGet, path, query, nil, "application/json")
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, int64(maxBytes+1)))
	if err != nil || len(data) > maxBytes {
		return nil, failure("response_failed", "Coordinator selftest response exceeds its wire budget or could not be read")
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, &Error{Code: "selftest_request_failed", Message: "Coordinator selftest request failed", Status: resp.StatusCode}
	}
	if !json.Valid(data) {
		return nil, failure("invalid_response", "Coordinator selftest response is not JSON")
	}
	// A diagnostic never needs reflected credentials. Reject instead of
	// accepting redaction's JSON re-encoding, which can repair malformed Unicode.
	redacted := c.redactData(data)
	if !bytes.Equal(data, redacted) {
		return nil, failure("invalid_response", "Coordinator selftest response contains reflected credentials")
	}
	return json.RawMessage(data), nil
}
