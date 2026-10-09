# Authenticated Internet access

Use two distinct boundaries: application authentication and a protected network
path. This guide describes an operator-enabled rollout, not a deployment performed
by installing the release. Keep the origin private until the acceptance checks pass.

## Human dashboard

Create a Cloudflare Access self-hosted application covering the **entire** public
frontend hostname, including `/live`, `/documents`, `/settings` and `/auth`. Use a
named-user/group allowlist and an identity provider with MFA. A service-token
policy is not a human login policy.

Set these application environment variables (generic placeholders):

```sh
AGENTBOARD_AUTH_MODE=enforce
AGENTBOARD_FRONTEND_AUTH_MODE=cloudflare_access
AGENTBOARD_ACCESS_ISSUER=https://your-team.cloudflareaccess.com
AGENTBOARD_ACCESS_AUDIENCE=your-frontend-application-audience
AGENTBOARD_ACCESS_JWKS_FILE=/etc/agentboard/access-jwks.json
AGENTBOARD_FRONTEND_ALLOWED_EMAILS=operator@example.com
AGENTBOARD_FRONTEND_ALLOWED_SUBJECTS=
AGENTBOARD_FRONTEND_SESSION_TTL_SECONDS=300
PHX_HOST=board.example.com
```

Enable or disable authentication modes with an application restart and drain old
instances; do not rely on hot-toggling a mode for already-mounted unauthenticated
sockets. At least one allowed email or subject is mandatory. Matching either list permits
ordinary dashboard access; subjects are case-sensitive and emails are normalized
to lowercase. Login never grants captain permission. Captain controls still
require the separate captain capability.

The issuer, audience, public JWKS, allowed identities and session lifetime are
validated. Unknown modes, invalid settings or unavailable keys fail closed.
Only an RS256-signed Access application assertion is accepted, with expected
issuer/audience and valid human identity/time claims. Identity forwarding headers
without a valid signed assertion do not authenticate a user.

### Public verification keys

Obtain the public JWKS from the configured team's verified HTTPS
`/cdn-cgi/access/certs` endpoint. Mount it read-only at the configured path. It is
public verification material, **not** a service token or private signing key.
Do not configure a key URL supplied by an incoming JWT.

This first implementation deliberately uses an operator-managed local JWKS file.
Cloudflare rotates signing keys: update the file atomically from the pinned issuer,
retaining the appropriate rotation overlap, and test login after rotation. Unknown
keys or unreadable/malformed files deny access rather than using stale cached keys.
Monitor authentication failures. Automatic network key refresh is not implemented.

Compose users must add an explicit read-only bind mount for this file; an
`AGENTBOARD_ACCESS_JWKS_FILE` environment value alone does not mount it. Kubernetes
users can mount the public keys from an operator-managed ConfigMap. Real service
credentials belong in protected secret storage, never this public key file.

### LiveView and browser sessions

HTTP requests verify the Access assertion. The signed Phoenix session carries a
minimal, revocable handle for LiveView, never the raw Access JWT. Mounts, reconnects,
events and subscription updates revalidate the handle and policy. A session is
bounded by the JWT expiry and at most five minutes after HTTP verification; socket
activity does not extend it. Expiry forces a full HTTP refresh through Access.

Logout revokes the handle and redirects mounted sessions through their lifecycle
guard; subsequent data-bearing callbacks cannot pass. Captain lock/unlock
rotates the browser handle so older tabs cannot retain the old capability. A
change of verified human identity clears captain state.

The active-session registry is process-local: initially run **one Agentboard
application replica**. Restart invalidates sessions and requires reauthentication.
Do not assume seamless multi-replica sessions without a shared registry or a
reviewed routing design. Multiple `cloudflared` connector replicas are independent
of this application-replica constraint.

Cloudflare-side revocation is enforced by the edge for new requests. Local
verification cannot observe revocation of a still-valid JWT immediately; existing
sockets have the bounded session lifetime above. Preserve Access protection and
origin restrictions. Retain Phoenix CSRF and WebSocket origin checks; configure
`PHX_HOST` to the actual frontend hostname rather than disabling those checks.

## Agent and coordinator API

Use a separate Access application/policy for machines. A dedicated Access service
identity controls admission through the edge. An Agentboard bearer independently
controls the application's agent identity and scope. Keep these credentials
separate; do not replace Agentboard's Authorization header with an edge token.

The coordinator's `coordinator` scope is an explicit read-only operation allowlist.
It can inspect tasks, PRs, agents, decisions and its configured inbox. It cannot
acknowledge, send chat, dispatch workers, answer decisions or administer credentials.
See [agent credentials and enrollment](agent-api-tokens.md). Other agents retain
normal authenticated operations plus existing ownership/lease restrictions. This
is not repository-level multitenancy.

The CLI optionally reads `AGENTBOARD_ACCESS_SERVICE_TOKEN_FILE`, a protected local
JSON file containing `client_id` and `client_secret`. It sends them in
`CF-Access-Client-Id` and `CF-Access-Client-Secret`, preserving the application
bearer. This requires HTTPS and a regular, owner-only credential file. Provision
and rotate the real service token through an operator-approved secure flow; never
paste its contents into chat, source control, logs or command arguments.

Supervised worker configurations can set an absolute `access_service_token_file`
path. The environment variable is a fallback; if both are set, they must resolve
to the same normalized absolute path. Conflicts fail closed. Host and receipt
capabilities retain their own Authorization header and worker protocol, while the
Access headers are carried separately.

Client support does not establish that any particular hosted assistant can store
and inject credentials. Prove the intended runtime's secure credential path and
unattended renewal before switching routines away from their existing access path.

## Tunnel, origin and rollout

- Route a named Tunnel only to the intended ClusterIP service, not arbitrary
  internal services. Restrict origin access with the cluster's network policy.
- Configure `cloudflared` Access validation (team/audience) and retain application
  JWT validation for frontend requests. Protect alternate ingress routes too.
- The pre-auth IP limiter uses the actual peer address, not untrusted forwarded
  headers. Tunnel traffic may share a connector IP; size its aggregate budget
  for the fleet and retain edge abuse controls. Enforced per-agent limits use
  the verified application identity. Trusted forwarded-IP support is not added.
- Avoid wildcard public bypass rules. A GitHub webhook requires a narrowly scoped
  path/application policy and must still pass Agentboard's HMAC verifier.
- Health probes and minimal `/api/v1/meta` remain unauthenticated application-level
  compatibility endpoints. Do not add sensitive board data to them.
- Token and JWKS provisioning, changing Access policies and enabling public routing
  are separate operator actions. This patch does not perform them.

Before exposure, prove anonymous API/browser/document reads fail; forged agent
headers cannot impersonate another agent; coordinator writes fail across every
route; revoked credentials stop subsequent reads/watches; expired/bad-signature/
wrong-audience Access assertions fail; logout and captain lock invalidate old
sockets; legitimate agent/captain/worker/webhook flows still work; and direct-origin
access is blocked. Exercise LiveView login, reconnect and key rotation.

For rollback, remove public exposure first. Only then return API/frontend modes to
private-network defaults. Never leave an Internet route pointing at off/observe.

References: [Cloudflare JWT validation](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/authorization-cookie/validating-json/),
[service tokens](https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/),
[Phoenix LiveView security](https://hexdocs.pm/phoenix_live_view/security-model.html).
