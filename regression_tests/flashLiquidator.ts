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
const g_uni_router_02 = "0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45";
const g_flash_loaner = '0xBA12222222228d8Ba445958a75a0704d566BF2C8'

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


    const liquidator = await flFactory.deploy(g_witch, g_uni_router_02, g_flash_loaner) as FlashLiquidator
    return [owner, liquidator];
}

async function run_liquidator(tmp_root: string, liquidator: FlashLiquidator,
    base_to_debt_threshold: { [name: string]: string } = {}) {

    const config_path = join(tmp_root, "config.json")
    await fs.writeFile(config_path, JSON.stringify({
        "Witch": g_witch,
        "Flash": liquidator.address,
        "Multicall2": "0x5ba1e12693dc8f9c48aad8770482f4739beed696",
        "BaseToDebtThreshold": base_to_debt_threshold,
        "SwapRouter02": g_uni_router_02
    }, undefined, 2))

    logger.info("Liquidator deployed: ", liquidator.address)
    const accounts = normalizeHardhatNetworkAccountsConfig(
        config.networks[network.name].accounts as HardhatNetworkAccountConfig[]
    );

    const private_key_path = join(tmp_root, "private_key")
    await fs.writeFile(private_key_path, accounts[0].privateKey.substring(2))
    const cmd = `cargo run -- -c ${config_path} -u http://127.0.0.1:8545/ -C ${network.config.chainId} \
        -p ${private_key_path} \
        --gas-boost 10 \
        --swap-router-binary build/bin/router \
        --one-shot \
        --json-log \
        --file /dev/null`

    let stdout: string;
    let stderr: string
    try {
        const results = await exec(cmd, {
            encoding: "utf-8", env: {
                "RUST_BACKTRACE": "1",
                "RUST_LOG": "liquidator,yield_liquidator=debug",
                ...process.env
            },
            maxBuffer: 1024 * 1024 * 10
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

    it("liquidates ENS vaults on Dec-14-2021 (block: 13804681)", async function () {
        this.timeout(1800e3);

        await fork(13804681);
        const [_owner, liquidator] = await deploy_flash_liquidator();

        const starting_balance = await _owner.getBalance();

        const liquidator_logs = await run_liquidator(tmp_root, liquidator);

        let bought = 0;

        for (const log_record of liquidator_logs) {
            if (log_record["level"] == "INFO" && log_record["fields"]["message"] == "Submitted buy order") {
                bought++;
            }
            expect(log_record["level"]).to.not.equal("ERROR"); // no errors allowed
        }
        expect(bought).to.be.equal(5)

        const final_balance = await _owner.getBalance();
        logger.warn("ETH used: ", starting_balance.sub(final_balance).div(1e12).toString(), "uETH")
    });

    it("does not liquidate base==collateral vaults Dec-30-2021 (block: 13911677)", async function () {
        this.timeout(1800e3);

        await fork(13911677)
        const [_owner, liquidator] = await deploy_flash_liquidator();

        const liquidator_logs = await run_liquidator(tmp_root, liquidator);

        const vault_not_to_be_auctioned = "00cbb039b7b8103611a9717f";

        let new_vaults_message;

        for (const log_record of liquidator_logs) {
            if (log_record["level"] == "INFO" && log_record["fields"]["message"] == "Submitted liquidation") {
                const vault_id = log_record["fields"]["vault_id"];
                expect(vault_id).to.not.equal(`"${vault_not_to_be_auctioned}"`);
            }
            if (log_record["fields"]["message"] && log_record["fields"]["message"].startsWith("New vaults: ")) {
                new_vaults_message = log_record["fields"]["message"];
            }
        }
        // to make sure the bot did something and did not just crash
        expect(new_vaults_message).to.be.equal("New vaults: 1086");
    });

    it("does not liquidate <1000 USDC vaults Jan-24-2022 (block: 14070324)", async function () {
        this.timeout(1800e3);

        await fork(14070324)
        const [_owner, liquidator] = await deploy_flash_liquidator();

        const liquidator_logs = await run_liquidator(tmp_root, liquidator, {
            "303200000000": "1000000000"
        });

        const vault_not_to_be_auctioned = "468ff2cb1b8bb57bf932ab3f";

        let new_vaults_message;

        for (const log_record of liquidator_logs) {
            if (log_record["level"] == "INFO" && log_record["fields"]["message"] == "Submitted buy order") {
                const vault_id = log_record["fields"]["vault_id"];
                expect(vault_id).to.not.equal(`"${vault_not_to_be_auctioned}"`);
            }
            if (log_record["fields"]["message"] && log_record["fields"]["message"].startsWith("New vaults: ")) {
                new_vaults_message = log_record["fields"]["message"];
            }
        }
        // to make sure the bot did something and did not just crash
        expect(new_vaults_message).to.be.equal("New vaults: 1397");
    });

    it("does not liquidate <1000 DAI vaults Jan-24-2022 (block: 14070324)", async function () {
        this.timeout(1800e3);

        await fork(14070324)
        const [_owner, liquidator] = await deploy_flash_liquidator();

        const liquidator_logs = await run_liquidator(tmp_root, liquidator, {
            "303100000000": "1000000000000000000000"
        });

        const vault_not_to_be_auctioned = "9f78a0b12bc8152573520d52";

        let new_vaults_message;

        for (const log_record of liquidator_logs) {
            if (log_record["level"] == "INFO" && log_record["fields"]["message"] == "Submitted buy order") {
                const vault_id = log_record["fields"]["vault_id"];
                expect(vault_id).to.not.equal(`"${vault_not_to_be_auctioned}"`);
            }
            if (log_record["fields"]["message"] && log_record["fields"]["message"].startsWith("New vaults: ")) {
                new_vaults_message = log_record["fields"]["message"];
            }
        }
        // to make sure the bot did something and did not just crash
        expect(new_vaults_message).to.be.equal("New vaults: 1397");
    });


    describe("90% collateral offer", function () {
        const test_vault_id = "3ddcb12f945cd58f4acf26c7";
        const auction_started_in_block = 13900229; // 1640781211 ~= 04:33:31
        const liquidated_in_block = 13900498; // 1640784847 ~= 05:34:07

        const auction_start = 1640781211;
        const ilk_id = "0x303300000000";
        const duration = 3600;
        const initial_offer = 666000; // .000000000000666000 really?

        it("triggers liquidation upon expiry", async function () {
            this.timeout(1800e3);

            // block timestamp: 1640784562 ~= 05:29:22; ~95% collateral is offered
            await fork(13900485);
            const [_owner, liquidator] = await deploy_flash_liquidator();

            const liquidator_logs = await run_liquidator(tmp_root, liquidator);

            let vault_is_liquidated = false;
            for (const log_record of liquidator_logs) {
                if (log_record["level"] == "INFO" && log_record["fields"]["message"] == "Submitted buy order") {
                    const vault_id = log_record["fields"]["vault_id"];
                    if (vault_id == `"${test_vault_id}"`) {
                        vault_is_liquidated = true;
                    }
                }
            }
            expect(vault_is_liquidated).to.equal(true);
        })

        it("does not trigger liquidation before expiry", async function () {
            this.timeout(1800e3);

            // block timestamp: 1640782880 ~= 05:01:20; ~50% collateral is offered
            await fork(13900364);
            const [_owner, liquidator] = await deploy_flash_liquidator();

            const liquidator_logs = await run_liquidator(tmp_root, liquidator);

            let new_vaults_message;
            for (const log_record of liquidator_logs) {
                if (log_record["level"] == "INFO" && log_record["fields"]["message"] == "Submitted buy order") {
                    const vault_id = log_record["fields"]["vault_id"];
                    expect(vault_id).to.not.equal(`"${test_vault_id}"`);
                }
                if (log_record["fields"]["message"] && log_record["fields"]["message"].startsWith("New vaults: ")) {
                    new_vaults_message = log_record["fields"]["message"];
                }

            }
            // to make sure the bot did something and did not just crash
            expect(new_vaults_message).to.be.equal("New vaults: 1073");
        })
    });

    it("liquidates multihop ENS vaults on Jan-20-2022 (block: 14045343)", async function () {
        this.timeout(1800e3);

        await fork(14045343);
        const [_owner, liquidator] = await deploy_flash_liquidator();

        const liquidator_logs = await run_liquidator(tmp_root, liquidator);

        const vault_to_be_auctioned = "b50e0c2ce9adb248f755540b";
        let vault_is_liquidated = false;
        for (const log_record of liquidator_logs) {
            if (log_record["level"] == "INFO" && log_record["fields"]["message"] == "Submitted buy order") {
                const vault_id = log_record["fields"]["vault_id"];
                if (vault_id == `"${vault_to_be_auctioned}"`) {
                    vault_is_liquidated = true;
                }
            }
        }
        expect(vault_is_liquidated).to.equal(true);
    })
});
