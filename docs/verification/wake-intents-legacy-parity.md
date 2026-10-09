# Legacy nudger comparison: gaps retained

Read-only inspection of the maintainer nudger (SHA25685261cbbc3bca6cc3a27405b274f7d040498c9d2211759926f8da67d8516bc68) and execution of only extracted pure priority/card-selector functions against invented records found these differences. The nudger main loop and native input were never executed.

| Controlled source | Legacy selection | New canonical boundary |
| --- | --- | --- |
| Captain-authorized assigned P0 | Selected | Captured only with matching live assignment and availability |
| Unauthorized assigned P0 | Also selected by legacy selector | No wake occurrence without assignment_authorized |
| Expired in_progress claim | Selected as claimed P0 | Exact live-expiry warning cannot substitute stale-seat recovery |
| Captain-held card | No eligible selection | No automatic resumption |

The legacy signature is a truncated SHA1 of a combined reason list; the new reason hash identifies a versioned canonical occurrence. Legacy answer/body and availability-context heuristics cannot establish canonical DecisionWake identity or DB-effective availability. #150's full admission evaluator is absent. This is controlled selector evidence and a parity-gap inventory, not equivalent dry-run reason hashes or native parity. OpenSpec5.3 remains open. Keep the current nudger; only a separate captain decision can elect and activate its successor.
