// Command agentboard is the agentboard CLI.
package main

import (
	"context"
	"os"
	"os/signal"
	"syscall"

	"github.com/carverauto/agentboard/internal/cli"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	root := cli.NewRoot()
	err := root.ExecuteContext(ctx)
	if err != nil {
		cli.PrintError(root, os.Stderr, err)
	}
	os.Exit(cli.ExitCode(err))
}
