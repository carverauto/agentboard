// Command ab is the agentboard CLI agents use to claim work, post updates,
// message peers, and push quota snapshots. Stub only — wire Postgres next.
package main

import (
	"fmt"
	"os"
)

func main() {
	fmt.Fprintln(os.Stderr, "ab: not implemented yet (see https://github.com/carverauto/agentboard/issues/1)")
	os.Exit(2)
}
