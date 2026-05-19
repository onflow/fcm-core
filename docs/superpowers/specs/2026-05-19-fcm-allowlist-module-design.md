# FCM Allowlist Module — Design

Status: Draft
Date: 2026-05-19
Owner: peterargue

## Summary

A small, reusable Solidity module that exposes an on-chain allowlist of
addresses. Consumer contracts (initially `FCMVault`) reference the allowlist
through a narrow interface and use it to gate sensitive actions.

The v1 scope is the module itself: an interface and a mapping-backed
implementation. Vault integration is deferred to a separate work item; this
spec includes a sketch of the intended integration but does not deliver it.

## Goals

- Provide a reusable allowlist primitive that any FCM contract can plug into.
- Keep the interface narrow enough that alternative implementations
  (merkle-backed, signature-backed, composite, mock) can be substituted
  without changing consumers.
- Stay on `lib/` dependencies already present (OpenZeppelin Contracts).
- Make the list and its administration auditable through events.

## Non-goals

- Vault integration (deferred — separate spec/plan).
- On-chain enumeration of the list (events suffice; indexers reconstruct).
- Upgradeability. If the implementation needs to change, deploy a new
  `Allowlist` and repoint consumers via the swappable reference pattern.
- Holder-gating (gating share transfers) — out of v1 scope; the same
  interface supports it later without module changes.
- Multi-list composition (`AND` / `OR` adapters) — possible later as another
  implementation of `IAllowlist`.

## Background and prior art

Every serious permissioned-vault design surveyed during research keeps the
allowlist in a separate contract behind a narrow interface. Examples:

- **Morpho Vault V2** — vault holds up to four optional "gate" contract
  references, each implementing a small `canDoX(address)` interface. Setting
  a gate to `address(0)` disables it.
- **Maple Finance** — pools delegate to a `PoolPermissionManager` contract.
- **Centrifuge** — tranche tokens delegate transfer checks to a
  `RestrictionManager`.
- **ERC-3643 / T-REX** — token contract delegates to an `IdentityRegistry`
  plus pluggable compliance modules.

There is no widely-adopted standalone allowlist library in the Solidity
ecosystem. OpenZeppelin ships primitives (`Ownable`, `AccessControl`,
`EnumerableSet`) but no `Allowlist.sol`; both candidates found in the wild
(`mintdrop-xyz/allowlist`, Saddle Finance's `Allowlist`) are unsuitable
(signature-based / abandoned, and tightly coupled to pool caps,
respectively). The implementation is small enough that everyone rolls
their own; the integration is where variance lives.

## Architecture

Two files under `solidity/src/access/`:

```
solidity/src/
└── access/
    ├── IAllowlist.sol
    └── Allowlist.sol
```

No new external dependencies. `Allowlist` inherits OpenZeppelin's `Ownable`.

The consumer-side pattern (to be implemented in a later spec):

- Consumer holds a swappable `IAllowlist` reference.
- `address(0)` in that slot means "no gating" — useful both for staged
  rollouts and as an off switch.
- Consumer is responsible for choosing *which* actions to gate (deposit,
  transfer, etc.) and *which* address to check (typically the recipient of
  shares, not `msg.sender`).

## Components

### `IAllowlist`

```solidity
interface IAllowlist {
    event AddressAllowed(address indexed account);
    event AddressDisallowed(address indexed account);

    function isAllowed(address account) external view returns (bool);
}
```

Rationale for keeping admin functions out of the interface: different
implementations have different admin shapes (mapping vs. merkle root vs.
signer key). Consumers only ever need `isAllowed`. Keeping the interface
this narrow means a vault written against `IAllowlist` can swap to any
backing implementation without code change.

### `Allowlist`

```solidity
contract Allowlist is IAllowlist, Ownable {
    mapping(address account => bool) private _allowed;

    error ZeroAddress();

    constructor(address initialOwner) Ownable(initialOwner) {}

    function isAllowed(address account) external view returns (bool) {
        return _allowed[account];
    }

    function allow(address account) external onlyOwner {
        _allow(account);
    }

    function disallow(address account) external onlyOwner {
        _disallow(account);
    }

    function allowBatch(address[] calldata accounts) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; ++i) _allow(accounts[i]);
    }

    function disallowBatch(address[] calldata accounts) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; ++i) _disallow(accounts[i]);
    }

    function _allow(address account) internal {
        if (account == address(0)) revert ZeroAddress();
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
}
```

Behavior:

- **Idempotent edits.** Re-adding an existing entry does not revert and
  does not emit. Same for removing an absent entry. Matches OpenZeppelin
  `_grantRole` semantics. Makes batch ops cleaner — partial overlap with
  the existing list is fine.
- **Zero-address rejected on `allow`.** Almost always a bug; cheap to
  reject. `disallow(address(0))` is a no-op (since 0 is never on the list).
- **Internal `_allow` / `_disallow` helpers** are `internal` so subclasses
  can add custom admin logic (timelocks, expiry, batched workflows) without
  duplicating the storage and emit semantics.
- **No `renounceOwnership` override.** Standard `Ownable` permits it.
  Renouncing freezes the list permanently. Recovery path is to deploy a
  new `Allowlist` and repoint consumers.
- **No on-chain enumeration.** Events only.

## Admin model

`Ownable` (single owner). Justification:

- For v1 there is no clear ops/governance split that would benefit from
  the additional role machinery in `AccessControl`.
- Migrating from `Ownable` to `AccessControl` later is straightforward —
  deploy a new `Allowlist`, repoint consumers via the swappable reference.
- `Ownable2Step` was considered but judged unnecessary: the swappable
  reference on consumers means a fat-fingered ownership transfer is
  recoverable by deploying a new list and repointing.

Production deployments should set the owner to a multisig or governance
contract.

## Testing

`solidity/test/Allowlist.t.sol`, using `forge-std/Test`.

Unit tests:

- `test_NewAddressIsNotAllowed`
- `test_AllowAddsToList` — asserts state change and `AddressAllowed` event.
- `test_DisallowRemovesFromList` — asserts state change and `AddressDisallowed` event.
- `test_AllowZeroAddressReverts` — reverts with `ZeroAddress`.
- `test_DisallowZeroAddressIsNoop` — no revert, no emit.
- `test_AllowIdempotent_NoEmitOnDuplicate` — second `allow` of same address does not emit.
- `test_DisallowIdempotent_NoEmitOnAbsent` — `disallow` of unknown address does not emit.
- `test_AllowBatch` — mixed new and existing entries.
- `test_DisallowBatch` — mixed present and absent entries.
- `test_OnlyOwnerCanAllow` — non-owner reverts with `OwnableUnauthorizedAccount`.
- `test_OnlyOwnerCanDisallow` — same.
- `test_TransferOwnershipMovesAdmin` — old owner loses rights, new owner gains them.

Fuzz tests:

- `testFuzz_AllowDisallowRoundtrip(address account)` — allow then disallow
  returns to `false`; repeated allows/disallows are idempotent.

No integration tests against `FCMVault` in this spec — vault wiring is
deferred.

## Future integration (sketch, not in scope)

When the vault wires the allowlist for deposit-gating, the consumer side
looks roughly like:

```solidity
contract FCMVault is ERC4626, Ownable {
    IAllowlist public allowlist;

    event AllowlistUpdated(address indexed previous, address indexed current);

    function setAllowlist(IAllowlist newAllowlist) external onlyOwner {
        emit AllowlistUpdated(address(allowlist), address(newAllowlist));
        allowlist = newAllowlist;
    }

    function maxDeposit(address receiver) public view override returns (uint256) {
        if (address(allowlist) != address(0) && !allowlist.isAllowed(receiver)) {
            return 0;
        }
        return super.maxDeposit(receiver);
    }

    // similar override for maxMint
    // _deposit override that checks allowlist.isAllowed(receiver)
}
```

Important details to preserve when the integration spec is written:

1. **`allowlist == address(0)` means "no gating."** Permissionless by
   default; allows staged rollout and provides an off switch.
2. **Gate the `receiver`, not `msg.sender`.** Anyone can call
   `deposit(amount, victim)` to put assets in someone else's name.
3. **Override `maxDeposit` / `maxMint` to return 0 for non-allowlisted
   receivers** — ERC-4626 spec compliance, so previews don't lie.
4. **Vault owner is separate from allowlist owner.** Different keys can
   manage "what the vault does" vs "who's on the list."

## Gas and cost

- Mapping read: ~2.1k gas warm.
- Mapping write: ~22.1k gas per new entry.
- 20-address batch seed: ~450k gas.
- Per-deposit allowlist check (when integrated): ~2.5k gas added to the
  vault path.

Acceptable for all expected use cases.

## Security considerations

- **Owner key compromise** = full control of who can deposit (once
  integrated). Production owner should be a multisig.
- **No reentrancy concerns.** Pure storage reads/writes, no external calls.
- **No DoS via batch size.** Caller pays gas; deploy scripts should chunk
  batches to stay under the block gas limit.
- **No upgradeability** — by design. Replace by deploying new and
  repointing.
- **Renounce is permitted.** Recovery path is repointing consumers to a
  fresh `Allowlist`. Document this in operational runbooks.

## Open questions

None at design time. Vault integration decisions deferred to a separate
spec.
