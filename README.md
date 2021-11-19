# Yield Protocol Liquidator

Liquidates undercollateralized fyDAI-ETH positions using Uniswap V2 as a capital source.

This liquidator altruistically calls the `Witch.auction` function for any
position that is underwater, trigerring an auction for that position. It then tries
to participate in the auction by flashloaning funds from Uniswap, if there's enough
profit to be made.

## CLI

```
Usage: ./yield-liquidator [OPTIONS]

Optional arguments:
  -h, --help
  -c, --config CONFIG        path to json file with the contract addresses
  -u, --url URL              the Ethereum node endpoint (HTTP or WS) (default: http://localhost:8545)
  -C, --chain-id CHAIN-ID    chain id (default: 1)
  -p, --private-key PRIVATE-KEY
                             path to your private key
  -i, --interval INTERVAL    polling interval (ms) (default: 1000)
  -f, --file FILE            the file to be used for persistence (default: data.json)
  -m, --min-ratio MIN-RATIO  the minimum ratio (collateral/debt) to trigger liquidation, percents (default: 110)
  -s, --start-block START-BLOCK
                             the block to start watching from
```

Your contracts' `--config` file should be in the following format where:
 * `Witch` is the address of the Witch
 * `Flash` is the address of the PairFlash
 * `Multicall` is the address of the Multicall (https://github.com/makerdao/multicall)
```
{
  "Witch": "0xCA4c47Ed4E8f8DbD73ecEd82ac0d8999960Ed57b",
  "Flash": "0xB869908891b245E82C8EDb74af02f799b61deC97",
  "Multicall": "0xeefba1e63905ef1d7acba5a8513c70307c1ce441"
}
```

`Flash` is a deployment of `PairFlash` contract (https://github.com/sblOWPCKCR/vault-v2/blob/liquidation/contracts/liquidator/Flash.sol). Easy way to compile/deploy it:
```
solc --abi --overwrite --optimize --optimize-runs 5000 --bin -o /tmp/ external/vault-v2/contracts/liquidator/Flash.sol && ETH_GAS=3000000 seth send --create /tmp/PairFlash.bin "PairFlash(address,address,address,address,address) " $OWNER 0xE592427A0AEce92De3Edee1F18E0157C05861564 0x1F98431c8aD98523631AE4a59f267346ea31F984 0xd0a1e359811322d97991e03f863a0c30c2cf029c $WITCH_ADDRESS
```

The `--private-key` _must not_ have a `0x` prefix. Set the `interval` to 15s for mainnet.

## Building and Running

```
# Build in release mode
cargo build --release

# Run it with 
./target/release/yield-liquidator \
    --config ./addrs.json \
    --private-key ./private_key \
    --url http://localhost:8545 \
    --interval 7000 \
    --file state.json \
```

## How it Works

On each block:
1. Bumps the gas price of all of our pending transactions
2. Updates our dataset of borrowers debt health & liquidation auctions with the new block's data
3. Trigger the auction for any undercollateralized borrowers
4. Try participating in any auctions which are worth buying

Take this liquidator for a spin by [running it in a test environment](TESTNET.md).
