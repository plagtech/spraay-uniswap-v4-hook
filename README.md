# BatchDistributeHook — Uniswap V4

A Uniswap V4 hook that lets pool operators **push** tokens to up to 200 recipients in a single transaction by routing transfers through [Spraay](https://spraay.app)'s on-chain batch contract.

Port of the [PancakeSwap Infinity `BatchDistributeHook`](https://github.com/pancakeswap/infinity-hooks/pull/31) to V4's hook architecture. TypeScript SDK: [`@spraay/dex-adapters/uniswap-v4`](https://github.com/plagtech/spraay-dex-adapters).

## Push vs. pull distribution

Uniswap V4's native incentive flows are **pull-based**: LP fees accrue to positions and `donate()` credits in-range liquidity, and each LP has to collect. That works well for open, continuous incentives, but it is awkward for smaller, targeted programs:

- Every recipient pays gas to claim, so small rewards often go unclaimed.
- Recipients who are not LPs (contributors, market makers, community members, partner treasuries) cannot be paid through the pool at all.
- Every program needs a claim UI and someone to tell recipients to use it.

`BatchDistributeHook` adds a **push** model next to these flows. The pool operator works out the recipient list off-chain (for example from a liquidity snapshot, volume, or a contributor list) and delivers everything in one call. Recipients do nothing and pay no gas. Each distribution is tied on-chain to the V4 pool it belongs to.

|                     | Pull (LP fees / `donate`)     | Push (`BatchDistributeHook`)               |
| ------------------- | ----------------------------- | ------------------------------------------ |
| Who pays gas        | Each recipient, on collect    | The operator, once per batch               |
| Eligible recipients | Positions in the pool         | Any address                                |
| Allocation logic    | On-chain (pro-rata, in range) | Off-chain, decided by the operator         |
| Recipient action    | Collect                       | None                                       |
| Best for            | Open, continuous incentives   | Targeted payouts, airdrops, revenue shares |

## How it works

```
operator ──batchDistribute(poolId, token, recipients, amounts)──▶ BatchDistributeHook
                                                                    │ 1. check operator, pool, ≤200 recipients
                                                                    │ 2. quote amount + Spraay fee
                                                                    │ 3. pull exactly that from operator
                                                                    │ 4. approve Spraay for exactly that
                                                                    ▼
                                                   Spraay.sprayToken / sprayETH / sprayEqual
                                                                    │
                                              ┌──────────┬──────────┼──────────┬──────────┐
                                              ▼          ▼          ▼          ▼          ▼
                                          recipient₁ recipient₂    ...    recipient₂₀₀  fee recipient
```

- **Non-custodial.** The hook holds no funds between calls. Each call pulls exactly `amount + fee` from the operator, approves Spraay for exactly that amount, and Spraay uses all of it. Excess native currency is refunded in the same transaction.
- **Pool-attributed.** `afterInitialize` registers every pool created with this hook, and distributions must reference a registered `PoolId`. `afterDonate` emits `PoolDonation`, so indexers can see pull-side and push-side incentives for the same pool.
- **No effect on swaps or liquidity.** Only `afterInitialize` and `afterDonate` are enabled and neither returns a delta, so swaps and liquidity changes cost no extra gas. Distributions never touch PoolManager accounting.

### Hook permissions

V4 reads hook permissions from the low 14 bits of the hook's **address**, so the hook must be deployed to an address with exactly these bits set (`0x…1010`). The deploy script mines a CREATE2 salt with `HookMiner`.

| Callback          | Flag      | Enabled | Purpose                             |
| ----------------- | --------- | ------- | ----------------------------------- |
| `afterInitialize` | `1 << 12` | ✅      | Register the pool for distributions |
| `afterDonate`     | `1 << 4`  | ✅      | Emit `PoolDonation` for indexing    |
| everything else   |           | ❌      |                                     |

## Interface

```solidity
// token == address(0) distributes the native currency (ETH / BNB)
function batchDistribute(PoolId poolId, address token, address[] calldata recipients, uint256[] calldata amounts)
    external payable;                                   // → Spraay.sprayToken / sprayETH

function batchDistributeEqual(PoolId poolId, address token, address[] calldata recipients, uint256 amountEach)
    external payable;                                   // → Spraay.sprayEqual

function quoteTotalCost(uint256 totalAmount) external view returns (uint256); // amount + Spraay fee

// owner only
function setSpraayContract(address newSpraay) external;
function setOperator(address operator, bool allowed) external;
function rescueTokens(address token, address to, uint256 amount) external;
```

**Roles:**

- **Owner** (`Ownable2Step`) manages operators, can point the hook at a new Spraay deployment, and can recover tokens sent to the hook by mistake. The owner is not automatically an operator. The owner is a constructor argument because the CREATE2 deployer, not the caller, is `msg.sender` at deploy time.
- **Operators** trigger distributions and fund them.

**Funding a distribution:**

- **ERC-20:** `approve(hook, quoteTotalCost(sum(amounts)))`, then call `batchDistribute`.
- **Native:** send `msg.value >= quoteTotalCost(sum(amounts))`. The hook refunds any excess.

## Spraay fee

Spraay charges `feeBps` (currently **30 bps = 0.3%**) **on top of** the distributed amount. Recipients receive exactly the amounts specified, and the operator pays `total + total * feeBps / 10_000`. The hook reads the fee from Spraay at call time through `calculateTotalCost`, so a fee change on Spraay's side needs no change to the hook. Spraay caps `feeBps` at 500.

## Gas

Execution gas for one ERC-20 distribution to fresh addresses, from `test/BatchDistributeHook.gas.t.sol` (includes the 21k transaction base cost, excludes calldata):

| Recipients | Hook (1 tx) | Minimal loop contract (1 tx) | N separate transfers | Hook vs. N transfers |
| ---------: | ----------: | ---------------------------: | -------------------: | -------------------: |
|          5 |     316,347 |                      185,812 |              361,340 |                 −12% |
|         50 |   1,584,308 |                    1,380,385 |            3,614,000 |                 −56% |
|        100 |   2,993,781 |                    2,707,667 |            7,228,000 |                 −59% |
|        200 |   5,814,984 |                    5,362,392 |           14,456,000 |                 −60% |

Against one transfer per recipient, the hook saves more than half the gas from about 50 recipients up. A purpose-built loop contract without fee, pool attribution or access control is about 8–15% cheaper per batch; the hook trades that for non-custodial funding, operator roles, native-currency support with refunds, and on-chain attribution to a V4 pool. Reproduce with `forge test --match-contract BatchDistributeHookGasTest -vv`.

## Deployments

### BatchDistributeHook

| Chain        | Hook                                         | Deploy tx                                                                                                                         | Basescan                                                                                     |
| ------------ | -------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| Base (8453)  | `0xB9c1aB7BD023C784c19B8e9F10CE9CDEd9fF9010` | [`0x31b9f034…ebe9d`](https://basescan.org/tx/0x31b9f03443fd4ba57dea856f4e332b9f17a7a5a32b582213b185b51ea15ebe9d) | [verified source](https://basescan.org/address/0xB9c1aB7BD023C784c19B8e9F10CE9CDEd9fF9010#code) |

Full deploy tx hash: `0x31b9f03443fd4ba57dea856f4e332b9f17a7a5a32b582213b185b51ea15ebe9d` (block 52791101). Constructor arguments and salt are recorded in [`deployments/base.json`](deployments/base.json).

### Dependencies

| Chain     | Spraay (`SprayContract`)                     | V4 PoolManager                               |
| --------- | -------------------------------------------- | -------------------------------------------- |
| Base      | `0x1646452F98E36A3c9Cfc3eDD8868221E207B5eEC` | `0x498581fF718922c3f8e6A244956aF099B2652b2b` |
| BNB Chain | `0x3093a2951FB77b3beDfB8BA20De645F7413432C1` | `0x28e2Ea090877bF75740558f6BFB36A5ffeE9e9dF` |

Both Spraay contracts are verified on Sourcify (exact match) and have identical source. The addresses are also available in Solidity via `src/SpraayAddresses.sol`. Other V4 chains are supported as soon as Spraay is deployed there.

```sh
# set DEPLOYER_PRIVATE_KEY, HOOK_OWNER, HOOK_OPERATOR in .env (see .env.example)
forge script script/DeployBatchDistributeHook.s.sol:DeployBatchDistributeHookScript \
    --rpc-url base --broadcast
```

The script mines a salt for the `afterInitialize | afterDonate` flags, deploys through the deterministic CREATE2 deployer (`0x4e59b44847b379578588920cA78FbF26c0B4956C`), checks the resulting address, and prints the matching `forge verify-contract` command.

## Development

```sh
git clone --recursive https://github.com/plagtech/spraay-uniswap-v4-hook
forge build
forge test

# against the live Spraay + V4 PoolManager deployments
BASE_RPC_URL=https://mainnet.base.org BSC_RPC_URL=https://bsc-dataseed.binance.org \
    forge test --match-contract BatchDistributeHookForkTest
```

Built on [OpenZeppelin uniswap-hooks](https://github.com/OpenZeppelin/uniswap-hooks) (`BaseHook`) and [hookmate](https://github.com/akshatmittal/hookmate), matching [Uniswap/v4-template](https://github.com/Uniswap/v4-template). Unit tests place the hook at a flag-encoded address with `deployCodeTo` and run against a local PoolManager, including a real add-liquidity → `donate` → `settle` round trip. `test/mocks/MockSpraay.sol` is a copy of the verified Spraay source in which only the import paths and the contract name are changed.

## Limitations

- Fee-on-transfer and rebasing tokens are not supported, because Spraay pulls the exact gross amount.
- Each call is limited to 200 recipients (Spraay's `MAX_RECIPIENTS`). Larger lists must be split across several calls.
- In a native distribution, a recipient contract that rejects the payment makes the whole batch revert. Spraay does not skip failed recipients.
- Allocation is trusted to the operator. The hook enforces who can distribute, not who should receive.

## Related

- PancakeSwap Infinity: [pancakeswap/infinity-hooks#31](https://github.com/pancakeswap/infinity-hooks/pull/31)
- SushiSwap: [sushi-labs/sushiswap#2324](https://github.com/sushi-labs/sushiswap/pull/2324)
- Balancer v3: [balancer/scaffold-balancer-v3#138](https://github.com/balancer/scaffold-balancer-v3/pull/138)

## License

MIT
