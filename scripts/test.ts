import { ethers, network } from 'hardhat'
import * as hre from 'hardhat'

import { FlashLiquidator, Cauldron, Witch } from '../typechain/'

/**
 * @dev This script tests the FlashLiquidator
 * @notice The vault id and FlashLiquidator address might not be valid, please check
 */

;(async () => {
    const cauldronAddress = '0xc88191F8cb8e6D4a668B047c1C8503432c3Ca867'
    const witchAddress = '0x53C3760670f6091E1eC76B4dd27f73ba4CAd5061'
    const timelockAddress = '0x3b870db67a45611CF4723d44487EAF398fAc51E3'
    const flashLiquidatorAddress = '0x51A1ceB83B83F1985a81C295d1fF28Afef186E02' // Check for each test

    const ETH = ethers.utils.formatBytes32String('00').slice(0, 14)
    const DAI = ethers.utils.formatBytes32String('01').slice(0, 14)

    let [ownerAcc] = await ethers.getSigners()

    // Give some ether to the running account, since we are in a mainnet fork and would have nothing
    await network.provider.send("hardhat_setBalance", [
      ownerAcc.address,
      ethers.utils.parseEther("10").toHexString(),
    ]);

    // Give some ether to the timelock, we'll need it later
    await network.provider.send("hardhat_setBalance", [
      timelockAddress,
      ethers.utils.parseEther("10").toHexString(),
    ]);

    // Contract instantiation
    const cauldron = (await ethers.getContractAt('Cauldron', cauldronAddress, ownerAcc)) as unknown as Cauldron
    const witch = (await ethers.getContractAt('Witch', witchAddress, ownerAcc)) as unknown as Witch
    const flashLiquidator = (await ethers.getContractAt('FlashLiquidator', flashLiquidatorAddress, ownerAcc)) as unknown as FlashLiquidator

    // At the time of writing, this vault is collateralized at 268%. Find more at https://yield-protocol-info.netlify.app/#/vaults
    const vaultId = '0xd22a8e6260143034ccb99398'
    
    // Raise the required collateralization to 300%
    await hre.network.provider.request({
      method: "hardhat_impersonateAccount",
      params: [timelockAddress],
    });
    const timelockAcc = await ethers.getSigner(timelockAddress)
    const oracleAddress = (await cauldron.spotOracles(DAI, ETH)).oracle
    await cauldron.connect(timelockAcc).setSpotOracle(DAI, ETH, oracleAddress, 3000000)

    // Liquidate the vault
    await witch.auction(vaultId)

    // Wait to get enough collateral to pay the flash loan plus the fees
    const { timestamp } = await ethers.provider.getBlock('latest')
    await ethers.provider.send('evm_mine', [timestamp + 3600])

    await flashLiquidator.liquidate(vaultId)
})()
