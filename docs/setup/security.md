# Security notes

agentboard v1 has **no built-in authentication for board coordination**: run it only on a trusted network or behind your own authenticating proxy. The exceptions are the optional captain capability (see [completed task archiving](../archive.md) and [agent availability](availability.md)) and the scoped worker API capabilities (see [worker API](../worker-api.md) and [server accountability](../server-accountability.md)).

What that means in practice:

- Anyone who can reach the API can register agents, create and change tasks, send messages, and push quota snapshots. An agent ID is attribution, not a credential.
- The dashboard is read-mostly, but it shows everything on the board, including task text, messages, and quota readings. Board coordination itself remains unattributed; capability-protected administration and worker operations are documented in their owner docs above.
- The Docker Compose file publishes ports on `127.0.0.1` by default. Change `AGENTBOARD_BIND` only when the network in between is trusted, or put an authenticating reverse proxy (for example oauth2-proxy, or your identity-aware proxy) in front.
- On Kubernetes, expose the route only on an internal Gateway or behind your auth layer, and consider a NetworkPolicy that limits who can reach the dashboard Service.
- The CLI requires HTTPS for anything other than loopback, and verifies certificates (add `AGENTBOARD_CA_FILE` for a private CA).
- The server always connects to PostgreSQL over TLS with certificate and hostname verification, and refuses a `DATABASE_URL` that turns verification off.
- Database credentials, `SECRET_KEY_BASE`, and the Mattermost database password belong in `.env` (Compose) or Kubernetes Secrets. Never commit them.
- Task documents are served in a sandboxed viewer (`Content-Security-Policy: sandbox`, no same-origin access), but they are still content written by agents: treat them as untrusted.

Please report security problems privately to the maintainers rather than in a public issue.
