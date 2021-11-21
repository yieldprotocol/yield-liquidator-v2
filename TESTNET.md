## Testing

In this guide, you will:
1. Deploy the yield contracts
2. Run the liquidator 
3. See the liquidator trigger the liquidation 
4. After some time, see the liquidator participate in the auction

### Deploy the contracts

First we must clone the contracts and install the deps:

```
git clone git@github.com:sblOWPCKCR/vault-v2.git
git checkout liquidation
yarn
```

In one terminal, run hardhat node with mainnet fork: `yarn hardhat node --network hardhat`

In another terminal, deploy the contracts: `yarn hardhat run --network localhost scripts/deploy.ts`
It deploys Yield-V2 and prints out 3 important pieces of information:
* block number at the time of deployment
* owner's address and private key
* a json snippet with addresses of the deployed contracts

Store the private key in a file (/tmp/pk) without the '0x' prefix, store the json snippet in another file (config.json)

### Run the liquidator

In a new terminal, navigate back to the `yield-liquidator` directory and run:
```
RUST_BACKTRACE=1 RUST_LOG="liquidator,yield_liquidator=debug" cargo run -- --chain_id 31337 -c config.json -p /tmp/pk -s BLOCK_NUMBER_AT_TIME_OF_DEPLOYMENT --min-ratio 50
```


```
Sep 15 11:02:14.493  INFO yield_liquidator: Starting Yield-v2 Liquidator.
Sep 15 11:02:14.497  INFO yield_liquidator: Profits will be sent to 0xf364fdfe5706c4c274851765c00716ebad06eb6a
Sep 15 11:02:14.497  INFO yield_liquidator: Node: http://localhost:8545
Sep 15 11:02:14.498  INFO yield_liquidator: Cauldron: 0xc7309e5cda6e25a50ea71c5d4f27c5538182ca65
Sep 15 11:02:14.498  INFO yield_liquidator: Witch: 0x2dc74a1349670aa2dedf81daa5f8cfabc7d6e4e6
Sep 15 11:02:14.498  INFO yield_liquidator: Multicall: Some(0xeefba1e63905ef1d7acba5a8513c70307c1ce441)
Sep 15 11:02:14.498  INFO yield_liquidator: FlashLiquidator 0x955dcdb2d59f0b4bf1e97bb8187c6dfe02b3ab03
Sep 15 11:02:14.498  INFO yield_liquidator: Persistent data will be stored at: "data.json"
Sep 15 11:02:15.532 DEBUG eloop{block=13228001}:monitoring: yield_liquidator::borrowers: New vaults: 1
Sep 15 11:02:15.577 DEBUG eloop{block=13228001}:monitoring: yield_liquidator::borrowers: new_vault=[189, 42, 16, 43, 22, 126, 95, 211, 104, 131, 167, 65] details=Vault { is_collateralized: true, under_auction: false, level: 500000000000000000, ink: [69, 84, 72, 0, 0, 0], art: [107, 137, 103, 254, 149, 15] }
Sep 15 11:02:15.577 DEBUG eloop{block=13228001}: yield_liquidator::liquidations: checking for undercollateralized positions...
Sep 15 11:02:15.577 DEBUG eloop{block=13228001}: yield_liquidator::liquidations: Checking vault vault_id=[189, 42, 16, 43, 22, 126, 95, 211, 104, 131, 167, 65]
Sep 15 11:02:15.577 DEBUG eloop{block=13228001}: yield_liquidator::liquidations: Vault is collateralized vault_id=[189, 42, 16, 43, 22, 126, 95, 211, 104, 131, 167, 65]
```

The vault is fully collaterized, everything is happy

### Create a liquidation opportunity

Let's drop the collateral price
```
seth send SPOT_SOURCE_ADDRESS "set(uint)" "1000000000000000000"
```

This drops the collateral price to 1 (denominated in debt). Our vault is set up with 150% collaterization rate, so it should be under water now:
```
Sep 15 11:05:33.812 DEBUG eloop{block=13228002}: yield_liquidator::liquidations: checking for undercollateralized positions...
Sep 15 11:05:33.812 DEBUG eloop{block=13228002}: yield_liquidator::liquidations: Checking vault vault_id=[189, 42, 16, 43, 22, 126, 95, 211, 104, 131, 167, 65]
Sep 15 11:05:33.812  INFO eloop{block=13228002}: yield_liquidator::liquidations: found undercollateralized vault. starting an auction vault_id=[189, 42, 16, 43, 22, 126, 95, 211, 104, 131, 167, 65] details=Vault { is_collateralized: false, under_auction: false, level: -500000000000000000, ink: [69, 84, 72, 0, 0, 0], art: [107, 137, 103, 254, 149, 15] }
Sep 15 11:05:33.898 TRACE eloop{block=13228002}: yield_liquidator::liquidations: Submitted liquidation tx_hash=PendingTransaction { tx_hash: 0xb3f0aaeec92e7b10b30e5dcdea4d06428e9b2a83bd785becf487ed390206c710, confirmations: 1, state: PendingTxState { state: "InitialDelay" } } vault_id=[189, 42, 16, 43, 22, 126, 95, 211, 104, 131, 167, 65]
Sep 15 11:05:34.911 TRACE eloop{block=13228003}: yield_liquidator::liquidations: confirmed tx_hash=0xb3f0aaeec92e7b10b30e5dcdea4d06428e9b2a83bd785becf487ed390206c710 gas_used=83518 user=[189, 42, 16, 43, 22, 126, 95, 211, 104, 131, 167, 65] status="success" tx_type="liquidations"
Sep 15 11:05:34.913 DEBUG eloop{block=13228003}:monitoring: yield_liquidator::borrowers: New vaults: 0
Sep 15 11:05:34.946 DEBUG eloop{block=13228003}: yield_liquidator::liquidations: checking for undercollateralized positions...
Sep 15 11:05:34.947 DEBUG eloop{block=13228003}: yield_liquidator::liquidations: Checking vault vault_id=[189, 42, 16, 43, 22, 126, 95, 211, 104, 131, 167, 65]
Sep 15 11:05:34.947 DEBUG eloop{block=13228003}: yield_liquidator::liquidations: found vault under auction, ignoring it vault_id=[189, 42, 16, 43, 22, 126, 95, 211, 104, 131, 167, 65] details=Vault { is_collateralized: false, under_auction: true, level: -500000000000000000, ink: [69, 84, 72, 0, 0, 0], art: [107, 137, 103, 254, 149, 15] }
Sep 15 11:05:35.033 DEBUG eloop{block=13228003}: yield_liquidator::liquidations: Not time to buy yet vault_id=[189, 42, 16, 43, 22, 126, 95, 211, 104, 131, 167, 65] auction=Auction { started: 1631729706, under_auction: true, debt: 1000000000000000000, collateral: 1000000000000000000, ratio_pct: 100, is_at_minimal_price: false, debt_id: [68, 65, 73, 0, 0, 0], collateral_id: [69, 84, 72, 0, 0, 0], debt_address: 0x6b175474e89094c44da98b954eedeac495271d0f, collateral_address: 0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2 }
```

`Not time to buy yet` part is important here - the bot doesn't buy the debt right away. It either waits until collateral/debt ratio drops under the minimum specified, or the auction reaches the point when all of collateral is released.
In our exercise, we set the minimal collateral/debt ratio to 50% (`--min-ratio 50`) which is impractical, but good enough for demo purposes.

### Buying debt: auction releases all collateral

Skip some time and see what happens. Skip 10h:
```
curl -H "Content-Type: application/json" -X POST --data '{"id":1337,"jsonrpc":"2.0","method":"evm_increaseTime","params":[36000]}' http://localhost:8545

curl -H "Content-Type: application/json" -X POST --data '{"id":1337,"jsonrpc":"2.0","method":"evm_mine","params":[]}' http://localhost:8545

```

And the bot says:
```
Sep 15 11:21:03.042 DEBUG eloop{block=13228004}: yield_liquidator::liquidations: Is at minimal price, buying vault_id=[189, 42, 16, 43, 22, 126, 95, 211, 104, 131, 167, 65] auction=Auction { started: 1631729706, under_auction: true, debt: 1000000000000000000, collateral: 1000000000000000000, ratio_pct: 100, is_at_minimal_price: true, debt_id: [68, 65, 73, 0, 0, 0], collateral_id: [69, 84, 72, 0, 0, 0], debt_address: 0x6b175474e89094c44da98b954eedeac495271d0f, collateral_address: 0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2 } ratio=100 ratio_threshold=50
Sep 15 11:21:03.042 DEBUG eloop{block=13228004}: yield_liquidator::liquidations: new auction vault_id=[189, 42, 16, 43, 22, 126, 95, 211, 104, 131, 167, 65] auction=Auction { started: 1631729706, under_auction: true, debt: 1000000000000000000, collateral: 1000000000000000000, ratio_pct: 100, is_at_minimal_price: true, debt_id: [68, 65, 73, 0, 0, 0], collateral_id: [69, 84, 72, 0, 0, 0], debt_address: 0x6b175474e89094c44da98b954eedeac495271d0f, collateral_address: 0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2 }


Sep 15 11:21:07.587 TRACE eloop{block=13228004}:buying{vault_id=[189, 42, 16, 43, 22, 126, 95, 211, 104, 131, 167, 65] auction=Auction { started: 1631729706, under_auction: true, debt: 1000000000000000000, collateral: 1000000000000000000, ratio_pct: 100, is_at_minimal_price: true, debt_id: [68, 65, 73, 0, 0, 0], collateral_id: [69, 84, 72, 0, 0, 0], debt_address: 0x6b175474e89094c44da98b954eedeac495271d0f, collateral_address: 0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2 }}: yield_liquidator::liquidations: Submitted buy order tx_hash=PendingTransaction { tx_hash: 0x1406645b2fa56e6c36d053394e32d68905614b84ccc812a03a61c85bcaa46910, confirmations: 1, state: PendingTxState { state: "InitialDelay" } }
Sep 15 11:21:08.599 TRACE eloop{block=13228005}: yield_liquidator::liquidations: confirmed tx_hash=0x1406645b2fa56e6c36d053394e32d68905614b84ccc812a03a61c85bcaa46910 gas_used=365632 user=[189, 42, 16, 43, 22, 126, 95, 211, 104, 131, 167, 65] status="success" tx_type="auctions"
```

`Is at minimal price` followed by `Submitted buy order`

### Buying debt: debt ratio drops below threshold

Let's re-deploy our vault and go back to 1:1 collateral:debt price:

```
...
Sep 15 12:19:23.927 DEBUG eloop{block=13228076}: yield_liquidator::liquidations: checking for undercollateralized positions...
Sep 15 12:19:23.927 DEBUG eloop{block=13228076}: yield_liquidator::liquidations: Checking vault vault_id=[110, 161, 232, 101, 55, 96, 244, 173, 106, 64, 29, 210]
Sep 15 12:19:23.927 DEBUG eloop{block=13228076}: yield_liquidator::liquidations: Vault is collateralized vault_id=[110, 161, 232, 101, 55, 96, 244, 173, 106, 64, 29, 210]
...
Sep 15 12:20:52.890 DEBUG eloop{block=13228078}: yield_liquidator::liquidations: Not time to buy yet vault_id=[110, 161, 232, 101, 55, 96, 244, 173, 106, 64, 29, 210] auction=Auction { started: 1631770267, under_auction: true, debt: 1000000000000000000, collateral: 1000000000000000000, ratio_pct: 100, is_at_minimal_price: false, debt_id: [68, 65, 73, 0, 0, 0], collateral_id: [69, 84, 72, 0, 0, 0], debt_address: 0x6b175474e89094c44da98b954eedeac495271d0f, collateral_address: 0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2 }
```

And drop the collateral price to 1/1.6 of debt:
```
seth send SPOT_SOURCE_ADDRESS "set(uint)" "1600000000000000000"
```

The bot says:
```
Sep 15 12:21:39.318 DEBUG eloop{block=13228079}: yield_liquidator::liquidations: Ratio threshold is reached, buying vault_id=[110, 161, 232, 101, 55, 96, 244, 173, 106, 64, 29, 210] auction=Auction { started: 1631770267, under_auction: true, debt: 1000000000000000000, collateral: 1000000000000000000, ratio_pct: 50, is_at_minimal_price: false, debt_id: [68, 65, 73, 0, 0, 0], collateral_id: [69, 84, 72, 0, 0, 0], debt_address: 0x6b175474e89094c44da98b954eedeac495271d0f, collateral_address: 0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2 } ratio=50 ratio_threshold=50
Sep 15 12:21:41.109 TRACE eloop{block=13228079}:buying{vault_id=[110, 161, 232, 101, 55, 96, 244, 173, 106, 64, 29, 210] auction=Auction { started: 1631770267, under_auction: true, debt: 1000000000000000000, collateral: 1000000000000000000, ratio_pct: 50, is_at_minimal_price: false, debt_id: [68, 65, 73, 0, 0, 0], collateral_id: [69, 84, 72, 0, 0, 0], debt_address: 0x6b175474e89094c44da98b954eedeac495271d0f, collateral_address: 0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2 }}: yield_liquidator::liquidations: Submitted buy order tx_hash=PendingTransaction { tx_hash: 0xa64535a1ee15cfac46ba360461060b487d7f06ebe5f92164816650403f394b4e, confirmations: 1, state: PendingTxState { state: "InitialDelay" } }
Sep 15 12:21:41.118 TRACE eloop{block=13228080}: yield_liquidator::liquidations: confirmed tx_hash=0xa64535a1ee15cfac46ba360461060b487d7f06ebe5f92164816650403f394b4e gas_used=364932 user=[110, 161, 232, 101, 55, 96, 244, 173, 106, 64, 29, 210] status="success" tx_type="auctions"
Sep 15 12:21:41.120 DEBUG eloop{block=13228080}:monitoring: yield_liquidator::borrowers: New vaults: 1
Sep 15 12:21:41.153 DEBUG eloop{block=13228080}:monitoring: yield_liquidator::borrowers: Data fetched vault_id=[110, 161, 232, 101, 55, 96, 244, 173, 106, 64, 29, 210] details=Vault { is_collateralized: true, under_auction: false, level: 248958333333333333, ink: [69, 84, 72, 0, 0, 0], art: [73, 143, 171, 153, 67, 168] }
Sep 15 12:21:41.153 DEBUG eloop{block=13228080}: yield_liquidator::liquidations: checking for undercollateralized positions...
Sep 15 12:21:41.153 DEBUG eloop{block=13228080}: yield_liquidator::liquidations: Checking vault vault_id=[110, 161, 232, 101, 55, 96, 244, 173, 106, 64, 29, 210]
Sep 15 12:21:41.153 DEBUG eloop{block=13228080}: yield_liquidator::liquidations: Vault is collateralized vault_id=[110, 161, 232, 101, 55, 96, 244, 173, 106, 64, 29, 210]
Sep 15 12:21:41.204 DEBUG eloop{block=13228080}: yield_liquidator::liquidations: Auction is no longer active vault_id=[110, 161, 232, 101, 55, 96, 244, 173, 106, 64, 29, 210] auction=Auction { started: 0, under_auction: false, debt: 0, collateral: 497916666666666667, ratio_pct: 0, is_at_minimal_price: true, debt_id: [68, 65, 73, 0, 0, 0], collateral_id: [69, 84, 72, 0, 0, 0], debt_address: 0x6b175474e89094c44da98b954eedeac495271d0f, collateral_address: 0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2 }
```

`Ratio threshold is reached` -> `Submitted buy order` -> `Auction is no longer active`