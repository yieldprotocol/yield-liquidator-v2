import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { id } from '@yield-protocol/utils-v2'

import { expect } from "chai";
import { ethers } from "hardhat";

import { Logger } from "tslog";


import { Cauldron, CompoundMultiOracle, ChainlinkMultiOracle, ERC20Mock, FYToken, Join, 
    SafeERC20Namer, ChainlinkAggregatorV3Mock, FlashLiquidator, Witch } from "../typechain";
import { BigNumber } from "@ethersproject/bignumber";
import { Interface } from '@ethersproject/abi';


const logger: Logger = new Logger();

const baseId = ethers.utils.formatBytes32String('02').slice(0, 14)
const ilkId = ethers.utils.formatBytes32String('00').slice(0, 14)
const vaultId = ethers.utils.randomBytes(12)
const seriesId = ethers.utils.randomBytes(6)

const WAD = BigNumber.from(10).pow(18);

async function deploy<T>(owner: SignerWithAddress, contract_name: string, ...args: any[]): Promise<T> {
    const factory = await ethers.getContractFactory(contract_name, owner)
    return (await factory.deploy(...args)) as unknown as T;
}

describe("collateralToDebtRatio", function () {
    let cauldron: Cauldron;
    let owner: SignerWithAddress;
    let spotSource: ChainlinkAggregatorV3Mock;
    let flashLiquidator: FlashLiquidator;

    this.beforeEach(async function () {
        [owner] = await ethers.getSigners()

        const base = await deploy<ERC20Mock>(owner, "ERC20Mock", "base", "BASE");
        logger.info("base deployed");

        const ilk = await deploy<ERC20Mock>(owner, "ERC20Mock", "ilk", "ILK");
        logger.info("ilk deployed");

        const join = await deploy<Join>(owner, "Join", base.address);
        logger.info("join deployed");

        const chiRateOracle = await deploy<CompoundMultiOracle>(owner, "CompoundMultiOracle");
        const spotOracle = await deploy<ChainlinkMultiOracle>(owner, "ChainlinkMultiOracle");
        await spotOracle.grantRole(
            id(spotOracle.interface as any, 'setSource(bytes6,address,bytes6,address,address)'),
            owner.address
        )

        logger.info("oracles deployed");

        spotSource = await deploy<ChainlinkAggregatorV3Mock>(owner, "ChainlinkAggregatorV3Mock");
        await spotSource.set(WAD.div(2).toString()) // 0.5 base == 1 ilk
        await spotOracle.setSource(baseId, base.address, ilkId, ilk.address, spotSource.address);
        logger.info("spot source set");

        const current_block = await ethers.provider.getBlock(await ethers.provider.getBlockNumber());
        const fyTokenLibrary = await ethers.getContractFactory("FYToken", {
            signer: owner,
            libraries: {
                "SafeERC20Namer": (await deploy<SafeERC20Namer>(owner, "SafeERC20Namer")).address
            }
        });
        const fyToken = (await fyTokenLibrary.deploy(
            baseId, chiRateOracle.address, join.address,
            current_block.timestamp + 3600, "fytoken", "FYT")) as FYToken;

        logger.info("FYToken deployed");

        const cauldronFactory = await ethers.getContractFactory('Cauldron', owner)
        cauldron = (await cauldronFactory.deploy()) as Cauldron

        await cauldron.grantRoles(
            [
                id(cauldron.interface as any, 'build(address,bytes12,bytes6,bytes6)'),
                id(cauldron.interface as any, 'addAsset(bytes6,address)'),
                id(cauldron.interface as any, 'addSeries(bytes6,bytes6,address)'),
                id(cauldron.interface as any, 'addIlks(bytes6,bytes6[])'),
                id(cauldron.interface as any, 'setDebtLimits(bytes6,bytes6,uint96,uint24,uint8)'),
                id(cauldron.interface as any, 'setLendingOracle(bytes6,address)'),
                id(cauldron.interface as any, 'setSpotOracle(bytes6,bytes6,address,uint32)'),
                id(cauldron.interface as any, 'pour(bytes12,int128,int128)'),
            ],
            owner.address
        )
        logger.info("Cauldron: created");

        await cauldron.addAsset(baseId, base.address);
        await cauldron.addAsset(ilkId, ilk.address);
        logger.info("Cauldron: assets added");

        await cauldron.setLendingOracle(baseId, chiRateOracle.address);
        await cauldron.setSpotOracle(baseId, ilkId, spotOracle.address, 200 * 1e4); // 200% collaterization ratio
        await cauldron.setDebtLimits(baseId, ilkId, WAD.toString(), 0, 18);
        logger.info("Cauldron: oracles set");

        await cauldron.addSeries(seriesId, baseId, fyToken.address);
        logger.info("Cauldron: series added");

        await cauldron.addIlks(seriesId, [ilkId]);
        logger.info("Cauldron: ilks added");

        await cauldron.build(owner.address, vaultId, seriesId, ilkId)
        logger.info("Cauldron: built");

        await cauldron.pour(vaultId, WAD.toString(), WAD.toString())
        logger.info("Cauldron: poured");

        const witch = await deploy<Witch>(owner, "Witch", cauldron.address, ethers.constants.AddressZero);
        flashLiquidator = await deploy<FlashLiquidator>(owner, "FlashLiquidator", witch.address, ethers.constants.AddressZero, ethers.constants.AddressZero);
        logger.info("FlashLiquidator deployed");
    })

    it("is set to >100 for over-collaterized vaults", async function () {
        // oracle says: 0.5 base == 1 ilk
        // vault: 1 base deposited, 1 ilk borrowed => we're at 200% collaterization

        // collaterization rate is set at 200% => level() should be 0
        expect (await cauldron.callStatic.level(vaultId)).to.be.equal(0)

        // collateralToDebtRatio should be 200%
        expect (await flashLiquidator.callStatic.collateralToDebtRatio(vaultId)).to.be.equal(WAD.mul(2).toString());
    });

    it("is set to =100 for just-collaterized vaults", async function () {
        await spotSource.set(WAD.toString()) // 1 base == 1 ilk
        // vault: 1 base deposited, 1 ilk borrowed => we're at 100% collaterization

        // collaterization rate is set at 200% => level() should be at -1
        expect (await cauldron.callStatic.level(vaultId)).to.be.equal(WAD.mul(-1).toString())

        // collateralToDebtRatio should be 100%
        expect (await flashLiquidator.callStatic.collateralToDebtRatio(vaultId)).to.be.equal(WAD.toString());
    });

    it("is set to <100 for under-collaterized vaults", async function () {
        await spotSource.set(WAD.mul(2).toString()) // 2 base == 1 ilk
        // vault: 1 base deposited, 1 ilk borrowed => we're at 50% collaterization

        // collaterization rate is set at 200% => level() should be at -1.5
        expect (await cauldron.callStatic.level(vaultId)).to.be.equal(WAD.mul(-3).div(2).toString())

        // collateralToDebtRatio should be 50%
        expect (await flashLiquidator.callStatic.collateralToDebtRatio(vaultId)).to.be.equal(WAD.div(2).toString());
    });

});
