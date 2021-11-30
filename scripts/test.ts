import { ethers, network } from 'hardhat'
import * as hre from 'hardhat'

import { WstethFlashLiquidator, Cauldron, Witch, IERC20 } from '../typechain/'

/**
 * @dev This script tests the FlashLiquidator
 * @notice The vault id and FlashLiquidator address might not be valid, please check
 */
;(async () => {
  // UPDATE THESE TWO MANUALLY:
  const flashLiquidatorAddress = '0xfbC22278A96299D91d41C453234d97b4F5Eb9B2d'
  const vaultId = '0x776160d44b7a09553c2732d3'

  const wethAddress = '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2'
  const cauldronAddress = '0xc88191F8cb8e6D4a668B047c1C8503432c3Ca867'
  const witchAddress = '0x53C3760670f6091E1eC76B4dd27f73ba4CAd5061'
  const timelockAddress = '0x3b870db67a45611CF4723d44487EAF398fAc51E3'
  const recipient = '0x3b43618b2961D5fbDf269A72ACcb225Df70dCb48'

  const ETH = ethers.utils.formatBytes32String('00').slice(0, 14)
  const WSTETH = ethers.utils.formatBytes32String('04').slice(0, 14)
  const STETH = ethers.utils.formatBytes32String('05').slice(0, 14)

  let [ownerAcc] = await ethers.getSigners()

  // Give some ether to the running account, since we are in a mainnet fork and would have nothing
  await network.provider.send('hardhat_setBalance', [ownerAcc.address, ethers.utils.parseEther('10').toHexString()])

  // Give some ether to the timelock, we'll need it later
  await network.provider.send('hardhat_setBalance', [timelockAddress, ethers.utils.parseEther('10').toHexString()])

  // Contract instantiation
  const WETH = ((await ethers.getContractAt('IWETH9', wethAddress, ownerAcc)) as unknown) as IERC20
  const cauldron = ((await ethers.getContractAt('Cauldron', cauldronAddress, ownerAcc)) as unknown) as Cauldron
  const witch = ((await ethers.getContractAt('Witch', witchAddress, ownerAcc)) as unknown) as Witch
  const flashLiquidator = ((await ethers.getContractAt(
    'FlashLiquidator',
    flashLiquidatorAddress,
    ownerAcc
  )) as unknown) as WstethFlashLiquidator

  // At the time of writing, this vault is collateralized at 268%. Find more at https://yield-protocol-info.netlify.app/#/vaults
  console.log(`Vault to liquidate: ${vaultId}`)

  // Check collateralToDebtRatio, just to make sure it doesn't revert
  console.log(`Collateral to debt ratio: ${await flashLiquidator.callStatic.collateralToDebtRatio(vaultId)}`)

  // Raise the required collateralization to 300%
  await hre.network.provider.request({
    method: 'hardhat_impersonateAccount',
    params: [timelockAddress],
  })
  const timelockAcc = await ethers.getSigner(timelockAddress)
  const oracleAddress = (await cauldron.spotOracles(ETH, WSTETH)).oracle
  console.log(`Raising required collateralization to 3000%`)
  await cauldron.connect(timelockAcc).setSpotOracle(ETH, WSTETH, oracleAddress, 30000000)

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

  console.log(`Profit: ${await WETH.balanceOf(recipient)}`)
})()
