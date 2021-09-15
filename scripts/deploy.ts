import { run, ethers, network } from "hardhat";
import { Contract } from "ethers";

import { id, constants } from '@yield-protocol/utils-v2'
import { Cauldron } from '../typechain/Cauldron'
import { FYToken } from '../typechain/FYToken'
import { ERC20Mock as ERC20 } from '../typechain/ERC20Mock'
import { ChainlinkMultiOracle } from '../typechain/ChainlinkMultiOracle'
import { CompoundMultiOracle } from '../typechain/CompoundMultiOracle'
import { ISourceMock } from '../typechain/ISourceMock'

import { YieldEnvironment } from '../test/shared/fixtures'
const { WAD, THREE_MONTHS, ETH, DAI, USDC } = constants
import { RATE } from '../src/constants'

import {readFileSync} from 'fs'
import {resolve} from 'path'
import { WETH9Mock } from "../typechain/WETH9Mock";
import { parseEther } from "ethers/lib/utils";


async function deploy(contract_name: string, args: Iterable<any>): Promise<Contract> {
    console.log("Deploying ", contract_name);

    const factory = await ethers.getContractFactory(contract_name);

    const contract = await factory.deploy(...args);
    await contract.deployed();
    console.log(contract_name, " deployed to: ", contract.address);
    return contract;
};

async function main() {
    console.log("Current block: ", await ethers.provider.getBlockNumber());

    const accounts = await ethers.getSigners();
    const mnemonic = readFileSync(resolve(__dirname, "..", '.secret')).toString().trim();

    const userPrivateKey = ethers.Wallet.fromMnemonic(mnemonic, "m/44'/60'/0'/0/0").privateKey;

    const baseId = DAI; //ethers.utils.hexlify(ethers.utils.randomBytes(6))
    const ilkId = ETH; //ethers.utils.hexlify(ethers.utils.randomBytes(6))
    const seriesId = ethers.utils.hexlify(ethers.utils.randomBytes(6))

    const env = await YieldEnvironment.setup(accounts[0], [baseId, ilkId], [seriesId])
    console.log("env initialized");

    const cauldron = env.cauldron;

    const base = env.assets.get(baseId) as ERC20;
    const ilk = env.assets.get(ilkId) as unknown as WETH9Mock;

    const rateOracle = (env.oracles.get(RATE) as unknown) as CompoundMultiOracle;
    const rateSource = (await ethers.getContractAt('ISourceMock', await rateOracle.sources(baseId, RATE))) as ISourceMock;
    const spotOracle = (env.oracles.get(ilkId) as unknown) as ChainlinkMultiOracle;
    const spotSource = (await ethers.getContractAt(
        'ISourceMock',
        (await spotOracle.sources(baseId, ilkId))[0]
    )) as ISourceMock;
    const fyToken = env.series.get(seriesId) as FYToken;
    const vaultId = (env.vaults.get(seriesId) as Map<string, string>).get(ilkId) as string;

    await base.mint(await accounts[0].getAddress(), WAD.mul(100000)); // mint DAI
    await network.provider.send("hardhat_setBalance", [
        accounts[0].address,
        parseEther("1000000").toHexString(),
      ]);
    await ilk.deposit({value: WAD.mul(100000)});//ilk.mint(await accounts[0].getAddress(), WAD.mul(100000)); // mint WETH

    // await spotSource.set(WAD.mul(2));
    // await spotSource.set(WAD.div(2500)) // ETH wei per DAI

    console.log("pouring");
    await env.ladle.pour(vaultId, accounts[0].address, WAD, WAD)

    console.log("poured");

    const flash = await deploy("PairFlash", [
        accounts[0].address,
        "0xE592427A0AEce92De3Edee1F18E0157C05861564", // swaprouter mainnet
        "0x1F98431c8aD98523631AE4a59f267346ea31F984", // factory mainnet
        "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", // weth mainnet
        env.witch.address
    ]);

    const config = {
        "Cauldron": cauldron.address,
        "Witch": env.witch.address,
        "Flash": flash.address,
        "Multicall": "0xeefba1e63905ef1d7acba5a8513c70307c1ce441" // mainnet
    }

    console.log(JSON.stringify(config, null, 2));

    console.log("owner: ", accounts[0].address, "private key: ", userPrivateKey);

    console.log("spotSource", spotSource.address);
    console.log("spotOracle", spotOracle.address);
    console.log("vaultId", vaultId);
    console.log("WETH: ", ETH);
    console.log("DAI: ", DAI);

    await cauldron.setSpotOracle(baseId, ilkId, spotOracle.address, 150 * 10000);
    // await spotSource.set(WAD.mul(1).div(2)); // take the vault under water
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });