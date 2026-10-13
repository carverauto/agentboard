# Fleet backlog refill

Backlog refill keeps a fleet's seats supplied with work without a coordinator. Server code assigns the next unassigned card to each idle eligible seat in a captain-activated fleet and sends that seat one `task_order`. Nothing depends on a chat session or a model remembering to check the board. The server runs a pass every minute and after any task is marked done, released or handed off.

Refill is off by default. It runs only when:

1. the server sets `AGENTBOARD_REFILL_ENABLED=true`, and
2. a captain activates the fleet with `agentboard fleet activate`.

Start with `--mode dry-run`, read the would-assign pairs, then switch to `--mode live`.

## Before you activate

Refill uses existing board records. Set these up first:

- **Seat identities.** Each seat registers with `kind: seat` and heartbeats. A seat whose last heartbeat is older than the roster threshold gets nothing.
- **Managed seat scope.** Each seat needs a captain [seat scope](../seat-scope.md). The union of the fleet seats' `allowed_repos` is the fleet's backlog. A card goes only to a seat whose scope matches its repository and labels.
- **Fleet loadout.** Save the seats with `agentboard fleet loadout set FLEET --file loadout.json` ([format](../fleet-loadout.md)). A fleet cannot be activated without a saved loadout.

Restricted labels (default `security`, set by `AGENTBOARD_REFILL_RESTRICTED_LABELS` as a comma-separated list) add one more rule. A card with a restricted label goes only to a seat whose scope lists that label in `required_labels` or `allowed_labels`. A general seat with empty label lists never receives a security card.

## Selection rules

Each pass, for each activated fleet:

1. Read the open, unassigned, unarchived cards in the fleet's repositories. Sort them by priority (a lower number is more urgent), then creation time, then ID. Each pass reads at most 100 cards and keeps no cursor between passes.
2. For each card in that order, ask shared seat eligibility for one of the fleet's seats. The seat must be registered, nonretired, recently heartbeating and `active` (not `reserved` or `out_of_service`). It must not be waiting on a captain decision, its managed scope must match the card, and it must hold fewer cards than `AGENTBOARD_QUEUE_LIMIT` (default 2). Among eligible seats, the one with the fewest cards wins, then the one assigned longest ago, then the lowest ID.
3. A seat gets at most one new card per pass. Seats fill up to the queue limit over several passes. With two empty seats and three cards, a pass assigns two and the third waits.

A live assignment uses the board's normal assign transition, attributed to the reserved `fleet-refill` identity. In the same transaction it sends one `task_order` to the seat and records the assignment. The record's key is the card ID plus the revision the assignment produced, so a retry or crash cannot send a second order for the same assignment. Each card commits on its own. After a crash, the next pass sees committed assignments as taken and assigns only the cards that are still open.

Refill never claims work for a seat, chooses a seat by name, merges, deploys or releases a claim.

## Claim deadline

Every refill assignment has a claim deadline (`--claim-deadline`, 1m to 24h, default 30m). A seat that does not claim its card by then loses the assignment. The refill pass moves the card back to the backlog through the normal release transition, attributed to `fleet-refill` with a note naming the seat and the deadline. The card is eligible again on the next pass. A card held by an open captain decision is not returned.

Misses are counted per seat. `fleet refill status` lists them, and any seat with two or more misses is flagged `attention: true` for the captain.

## Dry run

A `dry_run` fleet goes through the same selection but writes nothing to the board: no assignment, order, event or deadline return. The pass stores its would-assign pairs, which `fleet refill status` shows.

```sh
agentboard fleet activate example-fleet --mode dry-run
agentboard fleet refill status example-fleet --json
```

## Going live

```sh
agentboard fleet activate example-fleet --mode live --claim-deadline 30m
agentboard fleet refill status example-fleet
```

`fleet refill status` returns the activation, the last pass (mode, pairs, number of returns), assignments still waiting for a claim with their deadlines, and per-seat misses.

When `--claim-deadline` is omitted, the fleet keeps its recorded deadline. Activating again with the same mode and deadline changes nothing.

## Deactivating

```sh
agentboard fleet deactivate example-fleet
```

Deactivation stops new assignments and deadline returns for that fleet. It does not release claims, stop seats or touch existing assignments. Assignments waiting for a claim stay with their seats; on reactivation their deadlines apply again. Setting `AGENTBOARD_REFILL_ENABLED=false` and restarting turns refill off for every fleet. Captain activations are kept but have no effect.

All three commands use the protected captain capability (`AGENTBOARD_CAPTAIN_TOKEN_FILE`) and need schema 46. The HTTP contract is in the [API reference](../api.md#fleet-activation-and-backlog-refill-schema-46).
