# Audited by [V12](https://zellic.ai/)

The only autonomous Solidity auditor that finds critical bugs. Not all audits are equal, so stop paying for bad ones. Just use V12. No calls, demos, or intros.


---

# Reentrancy corrupts `staked` via snapshots
**#1**
- Severity: High
- Validity: Invalid

## Targets
- deposit (LidoHarvester)
- harvest (LidoHarvester)

## Affected Locations
- **LidoHarvester.deposit**: `deposit` snapshots the stETH balance and then calls `transferFrom` before updating `staked` from the balance delta, so reentrancy can change the balance/state mid-flight; adding reentrancy protection and/or restructuring accounting to avoid stale snapshots here prevents double-counting.
- **LidoHarvester.harvest**: `harvest` caches `_staked` and then performs an unguarded external call to `target`, so `staked` can be reentrantly increased without being reflected in the cached value; adding reentrancy protection and/or forbidding reentrant `deposit` mutations during this call remediates the desynchronization.

## Description

`LidoHarvester` relies on pre-call snapshots (`balanceOf` in `deposit`, cached `_staked` in `harvest`) and then performs external calls that can reenter and mutate `staked` before the outer frame finishes its accounting. In `deposit`, a callback during `transferFrom` can invoke `deposit` again, so the outer call still uses the original balance snapshot and double-counts the inner deposit when it later applies the balance delta. In `harvest`, the contract makes an unguarded external call to a configurable `target` with arbitrary calldata while caching `_staked`, allowing the `target` to reenter `deposit` to inflate `staked` and then restore balances so the post-call checks still pass. Both paths can permanently desynchronize `staked` from the real stETH balance, breaking the intended “principal vs yield” accounting. The underlying issue is reentrancy across external calls combined with cached values that become stale inside the same transaction.

## Root cause

State/accounting (`staked`) is derived from cached snapshots across external calls without reentrancy protection, allowing reentrant updates that make the cached values stale and the final accounting incorrect.

## Impact

An attacker can inflate `staked` beyond the contract’s actual stETH balance, causing future `harvest` operations to return early, revert, or treat real yield as principal. This effectively denies yield conversion and can block protocol revenue until enough positive rebases accrue to offset the artificial deficit, which may take a long time or never occur.

## Remediation

**Status:** Incomplete

### Explanation

Add a reentrancy guard to `deposit` (and any other entry points that touch `staked`) and avoid using cached snapshot values across external calls by recomputing `staked` from the current stETH balance after all interactions. This prevents reentrant updates from making intermediate snapshots stale and ensures accounting always reflects the latest on-chain state.

## Comments

- Invalid. The finding treats stETH as if it has ERC-777 transfer hooks (it doesn't) and treats owner-controlled configuration as attacker-controlled input. Both premises are wrong. *(Mar 5, 2026, 02:44 PM)*