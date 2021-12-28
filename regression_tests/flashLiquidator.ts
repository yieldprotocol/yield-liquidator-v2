import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { FlashLiquidator, FlashLiquidator__factory } from "../typechain";

import { expect } from "chai";
import { config, ethers, network, run } from "hardhat";
import { subtask } from "hardhat/config";
import { normalizeHardhatNetworkAccountsConfig } from "hardhat/internal/core/providers/util";

import { Logger } from "tslog";

import { Readable } from "stream";
import { createInterface } from "readline";
// import { readFile, mkdtemp, writeFile } from "fs/promises";
import { promises as fs } from 'fs';
import { tmpdir } from "os";
import { join } from "path";
import { promisify } from "util";
import { exec as exec_async } from "child_process";
import { HardhatNetworkAccountConfig } from "hardhat/types/config";
import { TransactionResponse } from "@ethersproject/abstract-provider";

const exec = promisify(exec_async);

const logger: Logger = new Logger();

const g_witch = "0x53C3760670f6091E1eC76B4dd27f73ba4CAd5061"
const g_uni_factory = "0x1F98431c8aD98523631AE4a59f267346ea31F984";
const g_uni_router = "0xE592427A0AEce92De3Edee1F18E0157C05861564";

async function fork(block_number: number) {
    const alchemy_key = (await fs.readFile(join(__dirname, "..", '.alchemyKey'))).toString().trim()

    await network.provider.request({
        method: "hardhat_reset",
        params: [
            {
                forking: {
                    jsonRpcUrl: `https://eth-mainnet.alchemyapi.io/v2/${alchemy_key}`,
                    blockNumber: block_number,
                },
            },
        ],
    });
}

async function deploy_flash_liquidator(): Promise<[SignerWithAddress, FlashLiquidator]> {
    const [owner] = await ethers.getSigners() as SignerWithAddress[];

    const flFactory = await ethers.getContractFactory("FlashLiquidator") as FlashLiquidator__factory;


    const liquidator = await flFactory.deploy(g_witch, g_uni_factory, g_uni_router) as FlashLiquidator
    return [owner, liquidator];
}

async function run_liquidator(tmp_root: string, liquidator: FlashLiquidator) {
    const config_path = join(tmp_root, "config.json")
    await fs.writeFile(config_path, JSON.stringify({
        "Witch": g_witch,
        "Flash": liquidator.address,
        "Multicall2": "0x5ba1e12693dc8f9c48aad8770482f4739beed696"
    }, undefined, 2))

    logger.info("Liquidator deployed: ", liquidator.address)
    const accounts = normalizeHardhatNetworkAccountsConfig(
        config.networks[network.name].accounts as HardhatNetworkAccountConfig[]
    );

    const private_key_path = join(tmp_root, "private_key")
    await fs.writeFile(private_key_path, accounts[0].privateKey.substr(2))
    const cmd = `cargo run -- -c ${config_path} -u http://127.0.0.1:8545/ -C ${network.config.chainId} -p ${private_key_path} --gas-boost 10 --one-shot --json-log --file /dev/null`

    let stdout: string;
    let stderr: string
    try {
        const results = await exec(cmd, {
            encoding: "utf-8", env: {
                "RUST_BACKTRACE": "1",
                "RUST_LOG": "liquidator,yield_liquidator=debug",
                ...process.env
            }
        })
        stdout = results.stdout
        stderr = results.stderr
    } catch (x) {
        stdout = (x as any).stdout;
        stderr = (x as any).stderr;
    }
    await fs.writeFile(join(tmp_root, "stdout"), stdout)
    await fs.writeFile(join(tmp_root, "stderr"), stderr)
    logger.info("tmp root", tmp_root)

    const rl = createInterface({
        input: Readable.from(stdout),
        crlfDelay: Infinity
    });

    const ret = new Array<any>();
    for await (const line of rl) {
        ret.push(JSON.parse(line));
    }
    return ret;
}

describe("flash liquidator", function () {
    let tmp_root: string;

    this.beforeAll(async function () {
        return new Promise((resolve, fail) => {
            run("node", { silent: true });

            // launch hardhat node so that external processes can access it
            subtask("node:server-ready", async function (args, _hre, runSuper) {
                try {
                    await runSuper(args);
                    logger.info("node launched");
                    resolve()
                } catch {
                    fail();
                }
            })
        })
    })
    this.beforeEach(async function () {
        tmp_root = await fs.mkdtemp(join(tmpdir(), "flash_liquidator_test"))
    })

    it("liquidates ENS vaults on Dec-04-2021 (block: 13738315)", async function () {
        this.timeout(900e3);

        await fork(13738315);
        const [_owner, liquidator] = await deploy_flash_liquidator();

        const starting_balance = await _owner.getBalance();

        const liquidator_logs = await run_liquidator(tmp_root, liquidator);

        let bought = 0;

        for (const log_record of liquidator_logs) {
            if (log_record["level"] == "INFO" && log_record["fields"]["message"] == "Submitted buy order") {
                bought++;
            }
            if (log_record["level"] == "ERROR") {
                expect(log_record["fields"]["message"]).to.be.equal("Failed to buy");
                expect(log_record["fields"]["error"]).to.contain("Too little received");
            }
        }
        // there are 7 vaults; 3 should be liquidated, the last 4 don't have enough collateral -> flash loan is not profitable
        expect(bought).to.be.equal(3)

        const final_balance = await _owner.getBalance();
        logger.warn("ETH used: ", starting_balance.sub(final_balance).div(1e12).toString(), "uETH")
    });

    it("has enough gas offset on Dec-04-2021 (txs issued: 13738305; txs executed: 13738315)", async function () {
        this.timeout(900e3);

        await fork(13738305)
        const [_owner, liquidator] = await deploy_flash_liquidator();

        const liquidator_logs = await run_liquidator(tmp_root, liquidator);

        // step 1: liquidate a bunch of vaults, memorize the successful transactions
        const buy_txs = new Array<any>() // should be Array<TransactionResponse> but npm is stupid
        for (const log_record of liquidator_logs) {
            if (log_record["level"] == "INFO" && log_record["fields"]["message"] == "Submitted buy order") {
                const tx_hash_txt = log_record["fields"]["tx_hash"];
                const tx_hash = tx_hash_txt.match(/tx_hash:\s+(\w+)/)[1]
                expect(tx_hash).to.not.be.undefined
                const tx = await ethers.provider.getTransaction(tx_hash)
                logger.info("TX hash found: ", tx.hash, `[${tx.nonce}]`)
                buy_txs.push(tx)
            }
        }
        // now, simulate transactions from step 1 not being minted immediately
        // step 2: restart fork from a later block, redeploy liquidator (will have the same address)
        logger.info("rewinding")
        await fork(13738315)
        await deploy_flash_liquidator();
        logger.info("rewound, replaing txs: ", buy_txs.length)
        // step 3: replay transactions from step 1 and check if they still succeed
        // If we don't have gas buffer, some of the txs will fail because they now cost a bit more
        for (const tx of buy_txs) {
            logger.info("Sending: ", tx.hash, `[${tx.nonce}]`)
            // this throws if the tx revers (runs out of gas)
            await _owner.sendTransaction({
                chainId: tx.chainId,
                data: tx.data,
                gasLimit: tx.gasLimit.toHexString(),
                to: tx.to,
                value: tx.value.toHexString()
            })
        }

        // await new Promise((r, _) => {
        //     setTimeout(r, 900e3)
        // })
    });
});
