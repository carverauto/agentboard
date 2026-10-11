## ADDED Requirements

### Requirement: Safe diagnostic boundary

The CLI SHALL provide `coordinator selftest` using only public metadata GET
and one authenticated tick GET with a one-item, 4096-byte page budget. It SHALL
NOT send acknowledgment, heartbeat, source-consumption, contact, worker,
enrollment, schedule-installation or activation requests.

#### Scenario: Successful scoped sample

- **WHEN** metadata and the authenticated tick match supported versions,
  configured identity and response bounds
- **THEN** the report records those narrow checks as PASS and states that only
  a page sample, not complete traversal or native conformance, was tested

#### Scenario: Malformed or incompatible sample

- **WHEN** a required version, identity, response shape or response bound fails
- **THEN** the report records FAIL, does not perform dependent requests and exits
  nonzero without echoing remote content, secrets or credential paths

### Requirement: Honest synthetic and native evidence

The CLI SHALL run shared local ack parsing and normalization fixtures and label
them synthetic. Offline mode SHALL NOT load credentials or perform HTTP. Native
schedule, admission, delivery, received/handled evidence and activation SHALL
remain WARN unless a future contract actually obtains the corresponding proof.
No current run SHALL issue an overall PASS or persisted conformance badge.

#### Scenario: Offline success

- **WHEN** local fixtures pass in offline mode
- **THEN** the versioned report distinguishes local PASS from live unverified
  WARN and exits zero without claiming operational readiness
