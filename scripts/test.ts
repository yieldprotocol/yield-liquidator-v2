import { ethers, network } from 'hardhat'
import * as hre from 'hardhat'

import { FlashLiquidator, Cauldron, Witch, IERC20 } from '../typechain/'

/**
 * @dev This script tests the FlashLiquidator
 * @notice The vault id and FlashLiquidator address might not be valid, please check
 */

;(async () => {
    const daiAddress = '0x6B175474E89094C44Da98b954EedeAC495271d0F'
    const cauldronAddress = '0xc88191F8cb8e6D4a668B047c1C8503432c3Ca867'
    const witchAddress = '0x53C3760670f6091E1eC76B4dd27f73ba4CAd5061'
    const timelockAddress = '0x3b870db67a45611CF4723d44487EAF398fAc51E3'
    const flashLiquidatorAddress = '0x4EE6eCAD1c2Dae9f525404De8555724e3c35d07B'
    const recipient = '0x3b43618b2961D5fbDf269A72ACcb225Df70dCb48'

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
    const dai = (await ethers.getContractAt('IWETH9', daiAddress, ownerAcc)) as unknown as IERC20
    const cauldron = (await ethers.getContractAt('Cauldron', cauldronAddress, ownerAcc)) as unknown as Cauldron
    const witch = (await ethers.getContractAt('Witch', witchAddress, ownerAcc)) as unknown as Witch
    const flashLiquidator = (await ethers.getContractAt('FlashLiquidator', flashLiquidatorAddress, ownerAcc)) as unknown as FlashLiquidator

    // At the time of writing, this vault is collateralized at 268%. Find more at https://yield-protocol-info.netlify.app/#/vaults
    const vaultId = '0xd22a8e6260143034ccb99398'
    console.log(`Vault to liquidate: ${vaultId}`)

    // Check collateralToDebtRatio, just to make sure it doesn't revert
    console.log(`Collateral to debt ratio: ${await flashLiquidator.callStatic.collateralToDebtRatio(vaultId)}`)
    
    // Raise the required collateralization to 300%
    await hre.network.provider.request({
      method: "hardhat_impersonateAccount",
      params: [timelockAddress],
    });
    const timelockAcc = await ethers.getSigner(timelockAddress)
    const oracleAddress = (await cauldron.spotOracles(DAI, ETH)).oracle
    console.log(`Raising required collateralization to 300%`)
    await cauldron.connect(timelockAcc).setSpotOracle(DAI, ETH, oracleAddress, 3000000)

    // Liquidate the vault
    console.log(`Auctioning ${vaultId}`)
    await witch.auction(vaultId)

    // Check if it is at minimal price (should be false)
    console.log(`Is at minimal price: ${await flashLiquidator.callStatic.isAtMinimalPrice(vaultId)}`)

    // Wait to get enough collateral to pay the flash loan plus the fees
    const { timestamp } = await ethers.provider.getBlock('latest')
    await ethers.provider.send('evm_mine', [timestamp + 3600])

    // Check if it is at minimal price (should be true)
    console.log(`Is at minimal price: ${await flashLiquidator.callStatic.isAtMinimalPrice(vaultId)}`)

    console.log(`Liquidating ${vaultId}`)
    await flashLiquidator.liquidate(vaultId)

    console.log(`Profit: ${await dai.balanceOf(recipient)}`)
})()
