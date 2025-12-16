# ARCH_BREAK.md
## PRAXIS Stack — Adversarial Architecture Break Report

PRAXIS is architecturally sound but operationally fragile without enforced integrity.
Governance is enforced by contracts, not agents.

This document enumerates architectural failure paths that can break the PRAXIS stack
even when individual modules function as coded.

---

## Core Doctrine

- Offline
- File-driven
- Deterministic where declared
- Human-in-the-loop authority
- No autonomous execution
- Fail-closed behavior
- Full auditability

---

## CRITICAL BREAKPOINTS

### Artifact Injection
Attack: Forged or modified baseline artifacts  
Consequence: Planning on false reality  
Mitigation: Signed artifacts + verification  
Verification: Modified baseline must abort planning

### IPC Atomicity Failure
Attack: Partial or concurrent JSON writes  
Consequence: Corrupted queue / nondeterminism  
Mitigation: Write-temp + atomic rename  
Verification: Concurrent stress test passes cleanly

### Determinism Theater
Attack: Unpinned RNG or environment drift  
Consequence: Non-reproducible outputs  
Mitigation: Seed locking + run_meta.json  
Verification: Bitwise-identical reruns

### Narrative Authority Leakage
Attack: Explanation overrides data  
Consequence: Human rubber-stamping  
Mitigation: Quote-first reporting  
Verification: Raw data always precedes prose

### Stale Baselines
Attack: Old baseline used for planning  
Consequence: Correct plan, wrong world  
Mitigation: TTL + refusal  
Verification: Stale baseline aborts

---

## FINAL VERDICT

PRAXIS is safe only if integrity is enforced.
Trust must be proven, not assumed.

End of ARCH_BREAK.md
