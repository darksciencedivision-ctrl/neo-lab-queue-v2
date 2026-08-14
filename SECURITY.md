# Security Notice

## Retired authorization keypair (2026-08-14)

An RSA keypair (`keys/human_auth_priv.xml` / `human_auth_pub.xml`) used by the
phase-4 human-authorization envelope was committed to this repository's history
and must be considered compromised. The repository history has been rewritten to
remove the key material, and the keypair is permanently retired.

- Do **not** trust any authorization envelope signed with the retired keypair.
- No currently valid key material is stored in this repository.
