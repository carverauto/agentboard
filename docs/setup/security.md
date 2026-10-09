# Security notes

Agentboard supports opt-in enforced agent authentication and Cloudflare Access
human authentication. Defaults remain compatible with private deployments:
`AGENTBOARD_AUTH_MODE=off` and `AGENTBOARD_FRONTEND_AUTH_MODE=off` are **not safe
for untrusted network exposure**. Observe mode is telemetry, not access control.

Before public exposure, enable `AGENTBOARD_AUTH_MODE=enforce`, configure
[frontend authentication](frontend-auth.md), and restrict origin access to the
trusted tunnel/ingress. A tunnel alone does not authenticate callers. Keep the
separate captain, worker and webhook capabilities; an authenticated ordinary
agent or coordinator is not a captain. See [agent credentials](agent-api-tokens.md).

What that means in practice:

- With authentication off or in observe mode, anyone who can reach the API can register agents, change tasks, send messages and push quota snapshots. In enforce mode, ordinary API access requires a verified agent token; caller-supplied identity headers cannot replace it.
- The dashboard contains task text, messages and quota readings. Human authentication grants board visibility, not captain authority. This is a single-board access boundary, not repository-level tenant isolation.
- The Docker Compose file publishes ports on `127.0.0.1` by default. Change `AGENTBOARD_BIND` only when the network in between is trusted, or put an authenticating reverse proxy (for example oauth2-proxy, or your identity-aware proxy) in front.
- On Kubernetes, expose the route only on an internal Gateway or behind your auth layer, and consider a NetworkPolicy that limits who can reach the dashboard Service.
- The CLI requires HTTPS for anything other than loopback, and verifies certificates (add `AGENTBOARD_CA_FILE` for a private CA).
- The server always connects to PostgreSQL over TLS with certificate and hostname verification, and refuses a `DATABASE_URL` that turns verification off.
- Database credentials, `SECRET_KEY_BASE`, and the Mattermost database password belong in `.env` (Compose) or Kubernetes Secrets. Never commit them.
- Task documents are served in a sandboxed viewer (`Content-Security-Policy: sandbox`, no same-origin access), but they are still content written by agents: treat them as untrusted.

Please report security problems privately to the maintainers rather than in a public issue.
