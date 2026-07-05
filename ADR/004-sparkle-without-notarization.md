# ADR-004: Sparkle auto-update without Apple notarization / Developer ID

Status: Accepted
Date: 2026-07-05
Sources: `docs/prd.md` (ADR-CANDIDATE, FR12, Constraints, Risks, Open Questions); `docs/techspec.md` §6; `docs/architecture-draft.md` §3, §7

## Context

justStats ships unsigned and unnotarized: there is no Apple Developer Program membership backing this project, which rules out notarization, Mac App Store distribution, and its sandboxing requirements. The app is distributed via GitHub Releases to a small, technical audience that accepts Gatekeeper "right-click → Open" friction on first launch. Even so, the product still wants low-friction updates (FR12) rather than requiring users to manually re-download every release. Sparkle supports a self-managed EdDSA signing key that is independent of Apple's notarization pipeline, so update-payload integrity can be guaranteed without a Developer ID.

## Decision

Ship Sparkle-based auto-update, using a self-generated EdDSA key pair, independent of Apple notarization / Developer ID:

- **Update framework:** Sparkle. Key pair generated with Sparkle's `generate_keys` tool. The **public** key is embedded in `justStats/Info.plist`; the **private** key is kept entirely outside the repository and is never committed to git or its history.
- **Appcast hosting:** `appcast.xml` is committed to the repo and served over HTTPS via `https://raw.githubusercontent.com/zanybaka/justStats/main/appcast.xml`. It is updated as part of the release process (a manual step, documented in a release checklist).
- **Release artifact:** a `.zip` of the `.app` bundle, attached to a GitHub Release; Sparkle points at the GitHub Release asset URL.
- **Network surface:** no telemetry and no network calls beyond Sparkle's update check and the GitHub Release asset download.

## Alternatives considered

- **Notarized / Developer ID distribution (and/or Mac App Store):** rejected as unavailable. It would remove Gatekeeper friction and is the "correct" path, but requires a paid Apple Developer Program membership that this project does not have; the App Store path additionally forces sandboxing incompatible with the Full Disk Access / Spotlight design (ADR-003). Revisit if a paid Developer account is obtained later.
- **Manual-download-only updates (no Sparkle):** rejected as unnecessary friction. Simplest and avoids managing a signing key, but Sparkle does not require notarization, so there is no reason to make every update a manual re-download.

## Consequences

- Users get in-app update checks and installs without any Apple Developer ID / notarization dependency; update-payload integrity is protected by the EdDSA signature Sparkle verifies against the embedded public key.
- **Gatekeeper friction on first launch is accepted** and unchanged by Sparkle: an unsigned, unnotarized build still requires manual "right-click → Open" approval the first time, mitigated only by clear README install instructions. This may deter non-technical users from installing at all.
- **Unverified upgrade-flow risk (carried forward, open):** whether Sparkle-delivered updates to an already-approved unnotarized app re-trigger Gatekeeper blocks — versus a mere warning — is not yet verified. This must be spiked (build two versions, test the real upgrade path with real Gatekeeper behavior) before relying on it for a public release. If updates unexpectedly re-trigger full Gatekeeper blocks, the update UX degrades and needs a fallback message pointing users to manual download.
- **Private-key handling is a standing operational constraint:** the EdDSA private signing key must never enter the repo or git history and needs a documented out-of-band storage location (e.g., local Keychain / password manager), since there is no CI secrets vault in scope for this project.
- The appcast URL must remain HTTPS.

## Implementation references

- `justStats/Info.plist` — `SUFeedURL` (HTTPS raw.githubusercontent.com) and `SUPublicEDKey` (public EdDSA key only).
- `appcast.xml` (repo root) — the update feed, updated manually per release.
- Sparkle package dependency (added under Phase 6 / task UPD-001), per techspec §6.
