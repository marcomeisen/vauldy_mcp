# Vauldy private ChatGPT relay

Owner-private Sites MCP with managed ChatGPT sign-in. Never make this Site public
or share its service access token. The Mac's service credential is provisioned by
the owner deployment flow over stdin to the native Keychain, never typed by a user,
embedded in a binary or committed. Service access is NOT an SSO identity: only
Sites-authenticated browser confirmation binds a device to the caller's Site user.

This is an owner-private deployment, not a multi-tenant commercial auth service.
The fixed Site origin is compiled into the Mac software to prevent credential
forwarding. Changing it requires a software deployment and fresh pairing.

`POST /mcp` exposes only the four local read-only tools. The Mac uses outbound
HTTPS, no router changes, tunnel-runtime keys or public local listener. Requests
and results in D1 are P-256 ECDH/HKDF-SHA256/AES-256-GCM envelopes, bound to job ID
and direction. Per-call private keys exist only during the HTTP call. No document
archive, OCR or plaintext tool result is stored here. Expired envelopes cannot be
executed/decrypted; bounded request cleanup deletes them on subsequent traffic.

Pairing lasts ten minutes, uses a local PKCE-style verifier and separate 256-bit
device token, binds the authenticated browser identity exactly once. Device grants
expire after 30 days and can be revoked in the browser or on the Mac. Local profile
revision is checked before a request and immediately before result upload. Native
confirmation precedes browser pairing. New imports never enlarge a paired grant.

The Mac must stay awake and the connector process must run. Offline/revoked state
is a tool error, never a successful empty list. Sources remain untrusted data.

Build: `bash scripts/build.sh`; test: `node --test tests/*.mjs`.
