package client

import (
	"context"
	"encoding/json"
	"errors"
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
