# FCM Allowlist Module Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a reusable mapping-backed Solidity allowlist module (`IAllowlist` interface + `Allowlist` implementation) that FCM contracts can plug into via a swappable reference.

**Architecture:** Two files under `solidity/src/access/`. `IAllowlist` defines a narrow `isAllowed(address) → bool` interface plus events. `Allowlist` is an `Ownable` contract backed by `mapping(address => bool)`, with idempotent single-entry and batch admin functions. No vault integration in this plan — that is a separate work item.

**Tech Stack:** Solidity ^0.8.20, Foundry (`forge`), OpenZeppelin Contracts 5.x (already in `solidity/lib/openzeppelin-contracts`). Remapping `@openzeppelin/=lib/openzeppelin-contracts/` is configured in `solidity/foundry.toml`.

**Spec:** [docs/superpowers/specs/2026-05-19-fcm-allowlist-module-design.md](../specs/2026-05-19-fcm-allowlist-module-design.md)

---

## Project conventions (read before starting)

- Working directory for `forge` commands is `solidity/`. The repo `Makefile` exposes `make solidity-fmt`, `make solidity-build`, `make solidity-test`, and `make ci` which runs all three.
- Formatter must pass `forge fmt --check`. Default config in `solidity/foundry.toml`: 100-char lines, 4-space tabs.
- The CI build uses `FOUNDRY_PROFILE=ci forge build --sizes` and `FOUNDRY_PROFILE=ci forge test -vvv`.
- OpenZeppelin Contracts 5.x uses custom errors (e.g. `OwnableUnauthorizedAccount(address)`) — use them in test expectations rather than string-matching revert reasons.
- Use `pragma solidity ^0.8.20;` for all new files (matches OZ Ownable's pragma; the configured `solc_version = "0.8.35"` satisfies it).
- New files use `SPDX-License-Identifier: UNLICENSED` to match the existing `FCMVault.sol` convention.

---

## Task 1: Create the `IAllowlist` interface

**Files:**
- Create: `solidity/src/access/IAllowlist.sol`

Interfaces are not directly testable, so this task has no failing-test step. We create the interface, verify it compiles, and commit.

- [ ] **Step 1: Create the interface file**

Create `solidity/src/access/IAllowlist.sol`:

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/// @title IAllowlist
/// @notice Minimal interface that any allowlist implementation must satisfy.
/// @dev Consumer contracts depend only on `isAllowed`. Admin functions are
///      intentionally not part of this interface because different backings
///      (mapping, merkle root, signature) have different admin shapes.
interface IAllowlist {
    /// @notice Emitted when `account` is added to the allowlist.
    event AddressAllowed(address indexed account);

    /// @notice Emitted when `account` is removed from the allowlist.
    event AddressDisallowed(address indexed account);

    /// @notice Returns true if `account` is currently on the allowlist.
    function isAllowed(address account) external view returns (bool);
}
```

- [ ] **Step 2: Verify it compiles**

Run from the repo root:

```bash
cd solidity && forge build
```

Expected: build succeeds, output mentions `IAllowlist`.

- [ ] **Step 3: Verify formatting**

Run from the repo root:

```bash
cd solidity && forge fmt --check src/access/IAllowlist.sol
```

Expected: no output, exit code 0.

- [ ] **Step 4: Commit**

```bash
git add solidity/src/access/IAllowlist.sol
git commit -m "feat(access): add IAllowlist interface"
```

---

## Task 2: Scaffold `Allowlist` with `isAllowed` (TDD)

Drive the contract's existence with a test that asserts a freshly deployed allowlist returns `false` for arbitrary addresses.

**Files:**
- Create: `solidity/test/Allowlist.t.sol`
- Create: `solidity/src/access/Allowlist.sol`

- [ ] **Step 1: Write the failing test**

Create `solidity/test/Allowlist.t.sol`:

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Allowlist} from "../src/access/Allowlist.sol";
import {IAllowlist} from "../src/access/IAllowlist.sol";

contract AllowlistTest is Test {
    Allowlist internal allowlist;

    address internal owner = address(0xA11CE);
    address internal alice = address(0xA1);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA401);
    address internal attacker = address(0xBAD);

    function setUp() public {
        allowlist = new Allowlist(owner);
    }

    function test_NewAddressIsNotAllowed() public view {
        assertFalse(allowlist.isAllowed(alice));
        assertFalse(allowlist.isAllowed(address(0)));
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd solidity && forge test --match-path test/Allowlist.t.sol -vvv
```

Expected: build error — `Allowlist` does not exist.

- [ ] **Step 3: Implement the minimal contract**

Create `solidity/src/access/Allowlist.sol`:

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAllowlist} from "./IAllowlist.sol";

/// @title Allowlist
/// @notice Mapping-backed allowlist of addresses, administered by a single owner.
/// @dev Idempotent edits: re-adding an existing entry (or removing an absent
///      one) does not revert and does not emit. Matches OpenZeppelin
///      `_grantRole` semantics.
contract Allowlist is IAllowlist, Ownable {
    mapping(address account => bool) private _allowed;

    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @inheritdoc IAllowlist
    function isAllowed(address account) external view returns (bool) {
        return _allowed[account];
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd solidity && forge test --match-path test/Allowlist.t.sol -vvv
```

Expected: `test_NewAddressIsNotAllowed` passes.

- [ ] **Step 5: Commit**

```bash
git add solidity/src/access/Allowlist.sol solidity/test/Allowlist.t.sol
git commit -m "feat(access): scaffold Allowlist with isAllowed"
```

---

## Task 3: Implement `allow` / `disallow` with events (TDD)

Add single-entry admin functions. Tests cover state change and event emission for both add and remove.

**Files:**
- Modify: `solidity/test/Allowlist.t.sol` — add tests
- Modify: `solidity/src/access/Allowlist.sol` — add `allow` / `disallow` and internal helpers

- [ ] **Step 1: Write the failing tests**

Append to `solidity/test/Allowlist.t.sol`, inside `AllowlistTest`:

```solidity
function test_AllowAddsToList() public {
    vm.prank(owner);
    allowlist.allow(alice);
    assertTrue(allowlist.isAllowed(alice));
}

function test_AllowEmitsEvent() public {
    vm.expectEmit(true, true, true, true, address(allowlist));
    emit IAllowlist.AddressAllowed(alice);
    vm.prank(owner);
    allowlist.allow(alice);
}

function test_DisallowRemovesFromList() public {
    vm.startPrank(owner);
    allowlist.allow(alice);
    allowlist.disallow(alice);
    vm.stopPrank();
    assertFalse(allowlist.isAllowed(alice));
}

function test_DisallowEmitsEvent() public {
    vm.prank(owner);
    allowlist.allow(alice);

    vm.expectEmit(true, true, true, true, address(allowlist));
    emit IAllowlist.AddressDisallowed(alice);
    vm.prank(owner);
    allowlist.disallow(alice);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd solidity && forge test --match-path test/Allowlist.t.sol -vvv
```

Expected: build error — `allow` and `disallow` not defined.

- [ ] **Step 3: Implement `allow` / `disallow` and internal helpers**

Modify `solidity/src/access/Allowlist.sol` — after `isAllowed`, add:

```solidity
function allow(address account) external onlyOwner {
    _allow(account);
}

function disallow(address account) external onlyOwner {
    _disallow(account);
}

function _allow(address account) internal {
    if (!_allowed[account]) {
        _allowed[account] = true;
        emit AddressAllowed(account);
    }
}

function _disallow(address account) internal {
    if (_allowed[account]) {
        _allowed[account] = false;
        emit AddressDisallowed(account);
    }
}
```

Note: the zero-address guard is intentionally not in this task — it's driven by the next task's test.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd solidity && forge test --match-path test/Allowlist.t.sol -vvv
```

Expected: all five tests pass.

- [ ] **Step 5: Commit**

```bash
git add solidity/src/access/Allowlist.sol solidity/test/Allowlist.t.sol
git commit -m "feat(access): add allow/disallow with events"
```

---

## Task 4: Reject zero-address on `allow` (TDD)

Add the explicit `ZeroAddress` guard. Disallow stays a no-op for zero (it's never on the list).

**Files:**
- Modify: `solidity/test/Allowlist.t.sol` — add tests
- Modify: `solidity/src/access/Allowlist.sol` — add error and guard

- [ ] **Step 1: Write the failing tests**

Append to `solidity/test/Allowlist.t.sol`, inside `AllowlistTest`:

```solidity
function test_AllowZeroAddressReverts() public {
    vm.expectRevert(Allowlist.ZeroAddress.selector);
    vm.prank(owner);
    allowlist.allow(address(0));
}

function test_DisallowZeroAddressIsNoop() public {
    vm.recordLogs();
    vm.prank(owner);
    allowlist.disallow(address(0));
    Vm.Log[] memory logs = vm.getRecordedLogs();
    assertEq(logs.length, 0);
    assertFalse(allowlist.isAllowed(address(0)));
}
```

The `Vm.Log` type comes from `forge-std/Vm.sol`. Add the import at the top of the test file:

```solidity
import {Vm} from "forge-std/Vm.sol";
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd solidity && forge test --match-path test/Allowlist.t.sol -vvv
```

Expected: `test_AllowZeroAddressReverts` fails (no revert). `test_DisallowZeroAddressIsNoop` should already pass.

- [ ] **Step 3: Add the error and the guard**

In `solidity/src/access/Allowlist.sol`, add a custom error declaration above the constructor:

```solidity
error ZeroAddress();
```

In the same file, modify `_allow` so the very first line guards against zero:

```solidity
function _allow(address account) internal {
    if (account == address(0)) revert ZeroAddress();
    if (!_allowed[account]) {
        _allowed[account] = true;
        emit AddressAllowed(account);
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd solidity && forge test --match-path test/Allowlist.t.sol -vvv
```

Expected: both new tests pass; all prior tests still pass.

- [ ] **Step 5: Commit**

```bash
git add solidity/src/access/Allowlist.sol solidity/test/Allowlist.t.sol
git commit -m "feat(access): reject zero address on allow"
```

---

## Task 5: Verify idempotent edits (TDD)

The internal helpers already short-circuit on state-equal edits; add explicit tests that document the behavior.

**Files:**
- Modify: `solidity/test/Allowlist.t.sol` — add tests

- [ ] **Step 1: Write the tests**

Append to `solidity/test/Allowlist.t.sol`, inside `AllowlistTest`:

```solidity
function test_AllowIdempotent_NoEmitOnDuplicate() public {
    vm.prank(owner);
    allowlist.allow(alice);

    vm.recordLogs();
    vm.prank(owner);
    allowlist.allow(alice); // already allowed
    Vm.Log[] memory logs = vm.getRecordedLogs();
    assertEq(logs.length, 0);
    assertTrue(allowlist.isAllowed(alice));
}

function test_DisallowIdempotent_NoEmitOnAbsent() public {
    vm.recordLogs();
    vm.prank(owner);
    allowlist.disallow(alice); // never added
    Vm.Log[] memory logs = vm.getRecordedLogs();
    assertEq(logs.length, 0);
    assertFalse(allowlist.isAllowed(alice));
}
```

- [ ] **Step 2: Run the tests**

```bash
cd solidity && forge test --match-path test/Allowlist.t.sol -vvv
```

Expected: both tests pass (no implementation change required — the `if (!_allowed[account])` and `if (_allowed[account])` guards already enforce idempotency).

- [ ] **Step 3: Commit**

```bash
git add solidity/test/Allowlist.t.sol
git commit -m "test(access): cover idempotent allow/disallow"
```

---

## Task 6: Batch `allow` / `disallow` (TDD)

Add `allowBatch` and `disallowBatch`. Tests cover mixed new/existing and present/absent inputs.

**Files:**
- Modify: `solidity/test/Allowlist.t.sol` — add tests
- Modify: `solidity/src/access/Allowlist.sol` — add batch functions

- [ ] **Step 1: Write the failing tests**

Append to `solidity/test/Allowlist.t.sol`, inside `AllowlistTest`:

```solidity
function test_AllowBatch() public {
    // Pre-seed one address so the batch contains a mix of new and existing.
    vm.prank(owner);
    allowlist.allow(alice);

    address[] memory batch = new address[](3);
    batch[0] = alice; // already allowed
    batch[1] = bob;
    batch[2] = carol;

    vm.prank(owner);
    allowlist.allowBatch(batch);

    assertTrue(allowlist.isAllowed(alice));
    assertTrue(allowlist.isAllowed(bob));
    assertTrue(allowlist.isAllowed(carol));
}

function test_DisallowBatch() public {
    vm.startPrank(owner);
    allowlist.allow(alice);
    allowlist.allow(bob);
    vm.stopPrank();

    address[] memory batch = new address[](3);
    batch[0] = alice;
    batch[1] = bob;
    batch[2] = carol; // never added

    vm.prank(owner);
    allowlist.disallowBatch(batch);

    assertFalse(allowlist.isAllowed(alice));
    assertFalse(allowlist.isAllowed(bob));
    assertFalse(allowlist.isAllowed(carol));
}

function test_AllowBatchRevertsOnZeroAddress() public {
    address[] memory batch = new address[](2);
    batch[0] = alice;
    batch[1] = address(0);

    vm.expectRevert(Allowlist.ZeroAddress.selector);
    vm.prank(owner);
    allowlist.allowBatch(batch);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd solidity && forge test --match-path test/Allowlist.t.sol -vvv
```

Expected: build error — `allowBatch` and `disallowBatch` not defined.

- [ ] **Step 3: Implement batch functions**

In `solidity/src/access/Allowlist.sol`, add after `disallow`:

```solidity
function allowBatch(address[] calldata accounts) external onlyOwner {
    for (uint256 i = 0; i < accounts.length; ++i) {
        _allow(accounts[i]);
    }
}

function disallowBatch(address[] calldata accounts) external onlyOwner {
    for (uint256 i = 0; i < accounts.length; ++i) {
        _disallow(accounts[i]);
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd solidity && forge test --match-path test/Allowlist.t.sol -vvv
```

Expected: all three new tests pass; all prior tests still pass.

- [ ] **Step 5: Commit**

```bash
git add solidity/src/access/Allowlist.sol solidity/test/Allowlist.t.sol
git commit -m "feat(access): add allowBatch and disallowBatch"
```

---

## Task 7: Owner gating and ownership transfer tests (TDD)

The `onlyOwner` modifier is inherited from OpenZeppelin's `Ownable`, so these tests assert behavior that should already work. They protect against future regressions if the modifier is ever removed accidentally.

**Files:**
- Modify: `solidity/test/Allowlist.t.sol` — add tests

- [ ] **Step 1: Write the tests**

Add this import at the top of `solidity/test/Allowlist.t.sol` (alongside the existing imports):

```solidity
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
```

Append to `solidity/test/Allowlist.t.sol`, inside `AllowlistTest`:

```solidity
function test_OnlyOwnerCanAllow() public {
    vm.expectRevert(
        abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker)
    );
    vm.prank(attacker);
    allowlist.allow(alice);
}

function test_OnlyOwnerCanDisallow() public {
    vm.prank(owner);
    allowlist.allow(alice);

    vm.expectRevert(
        abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker)
    );
    vm.prank(attacker);
    allowlist.disallow(alice);
}

function test_OnlyOwnerCanAllowBatch() public {
    address[] memory batch = new address[](1);
    batch[0] = alice;

    vm.expectRevert(
        abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker)
    );
    vm.prank(attacker);
    allowlist.allowBatch(batch);
}

function test_OnlyOwnerCanDisallowBatch() public {
    address[] memory batch = new address[](1);
    batch[0] = alice;

    vm.expectRevert(
        abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker)
    );
    vm.prank(attacker);
    allowlist.disallowBatch(batch);
}

function test_TransferOwnershipMovesAdmin() public {
    address newOwner = address(0xCAFE);

    vm.prank(owner);
    allowlist.transferOwnership(newOwner);

    // Old owner can no longer admin.
    vm.expectRevert(
        abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner)
    );
    vm.prank(owner);
    allowlist.allow(alice);

    // New owner can.
    vm.prank(newOwner);
    allowlist.allow(alice);
    assertTrue(allowlist.isAllowed(alice));
}
```

- [ ] **Step 2: Run the tests**

```bash
cd solidity && forge test --match-path test/Allowlist.t.sol -vvv
```

Expected: all five new tests pass.

- [ ] **Step 3: Commit**

```bash
git add solidity/test/Allowlist.t.sol
git commit -m "test(access): cover owner gating and ownership transfer"
```

---

## Task 8: Fuzz test the allow/disallow roundtrip

Add a property-based test asserting that allow→disallow returns to the original state and repeats are idempotent.

**Files:**
- Modify: `solidity/test/Allowlist.t.sol` — add fuzz test

- [ ] **Step 1: Write the fuzz test**

Append to `solidity/test/Allowlist.t.sol`, inside `AllowlistTest`:

```solidity
function testFuzz_AllowDisallowRoundtrip(address account) public {
    vm.assume(account != address(0));

    assertFalse(allowlist.isAllowed(account));

    vm.startPrank(owner);

    allowlist.allow(account);
    assertTrue(allowlist.isAllowed(account));

    // Idempotent re-allow.
    allowlist.allow(account);
    assertTrue(allowlist.isAllowed(account));

    allowlist.disallow(account);
    assertFalse(allowlist.isAllowed(account));

    // Idempotent re-disallow.
    allowlist.disallow(account);
    assertFalse(allowlist.isAllowed(account));

    vm.stopPrank();
}
```

- [ ] **Step 2: Run the fuzz test**

```bash
cd solidity && forge test --match-test testFuzz_AllowDisallowRoundtrip -vvv
```

Expected: passes with the default 256 fuzz runs.

- [ ] **Step 3: Commit**

```bash
git add solidity/test/Allowlist.t.sol
git commit -m "test(access): add fuzz roundtrip for allow/disallow"
```

---

## Task 9: Full CI green-check

Run the full pipeline used by CI to catch any formatting, build, or test issue that a path-scoped run might have missed.

- [ ] **Step 1: Run formatter check**

```bash
make solidity-fmt
```

Expected: no diff. If `forge fmt --check` reports differences, run `cd solidity && forge fmt src/access/IAllowlist.sol src/access/Allowlist.sol test/Allowlist.t.sol` and commit the formatting fix as a separate commit:

```bash
git add -u
git commit -m "style: forge fmt"
```

- [ ] **Step 2: Run CI build**

```bash
make solidity-build
```

Expected: success, contracts listed under the size table including `Allowlist`.

- [ ] **Step 3: Run CI tests**

```bash
make solidity-test
```

Expected: all tests pass (including `FCMVaultTest` and `AllowlistTest`).

- [ ] **Step 4: Confirm `make ci` passes end-to-end**

```bash
make ci
```

Expected: all three stages pass with no errors.

---

## Final verification checklist

- [ ] `solidity/src/access/IAllowlist.sol` exists and exposes `isAllowed`, `AddressAllowed`, `AddressDisallowed`.
- [ ] `solidity/src/access/Allowlist.sol` inherits `Ownable` and `IAllowlist`, has `allow`, `disallow`, `allowBatch`, `disallowBatch`, custom `ZeroAddress` error, idempotent semantics.
- [ ] `solidity/test/Allowlist.t.sol` has the full test list from the spec.
- [ ] `make ci` is green.
- [ ] No changes to `FCMVault.sol` (integration is a future spec).
- [ ] Each task produced its own commit; history is linear on `claude/competent-feynman-005c18`.
