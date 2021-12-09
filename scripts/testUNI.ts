import { ethers, network } from 'hardhat'

import { BigNumber } from 'ethers'
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers'
import { readAddressMappingIfExists, bytesToBytes32, impersonate, getOriginalChainId, getOwnerOrImpersonate } from './helpers'
import { ERC20Mock, Cauldron, Ladle, Witch, FYToken, CompositeMultiOracle, WstETHMock, WstethFlashLiquidator } from '../typechain'
import { developer, whales, seriesIds, assets } from './test.config'
import { ETH, UNI, WAD } from './constants'

/**
 * @dev This script tests ENS as a collateral
 */

;(async () => {
  const flashLiquidatorAddress = '0x23d85060F87218bb276AFE55a26BfD3B5F59914E'
  const recipient = '0x3b43618b2961D5fbDf269A72ACcb225Df70dCb48'

  const chainId = await getOriginalChainId()
  if (!(chainId === 1 || chainId === 4 || chainId === 42)) throw "Only Kovan, Rinkeby and Mainnet supported"

  let ownerAcc = await getOwnerOrImpersonate(developer.get(chainId) as string, WAD)
  let whaleAcc: SignerWithAddress

  const protocol = readAddressMappingIfExists('protocol.json');
  const governance = readAddressMappingIfExists('governance.json');

  const timelockAddress = governance.get('timelock') as string

  const weth = (await ethers.getContractAt(
    'IWETH9',
    assets.get(ETH) as string,
    ownerAcc
  )) as unknown as ERC20Mock
  const uni = (await ethers.getContractAt(
    'UNIMock',
    assets.get(UNI) as string,
    ownerAcc
  )) as unknown as WstETHMock
  const cauldron = (await ethers.getContractAt(
    'Cauldron',
    protocol.get('cauldron') as string,
    ownerAcc
  )) as unknown as Cauldron
  const ladle = (await ethers.getContractAt(
    'Ladle',
    protocol.get('ladle') as string,
    ownerAcc
  )) as unknown as Ladle
  const witch = (await ethers.getContractAt(
    'Witch',
    protocol.get('witch') as string,
    ownerAcc
  )) as unknown as Witch
  const oracle = (await ethers.getContractAt(
    'CompositeMultiOracle',
    protocol.get('compositeOracle') as string,
    ownerAcc
  )) as unknown as CompositeMultiOracle

  const flashLiquidator = ((await ethers.getContractAt(
    'FlashLiquidator',
    flashLiquidatorAddress,
    ownerAcc
  )) as unknown) as WstethFlashLiquidator

  whaleAcc = await impersonate(whales.get(UNI) as string, WAD)

  for (let seriesId of seriesIds) {
    console.log(`series: ${seriesId}`)
    const series = await cauldron.series(seriesId)
    const fyToken = (await ethers.getContractAt(
      'FYToken',
      series.fyToken,
      ownerAcc
      )) as unknown as FYToken
    
    const baseId = series.baseId
    const dust = (await cauldron.debt(series.baseId, UNI)).min
    const ratio = (await cauldron.spotOracles(series.baseId, UNI)).ratio
    const borrowed = BigNumber.from(10).pow(await fyToken.decimals()).mul(dust)
    const posted = (await oracle.peek(bytesToBytes32(series.baseId), bytesToBytes32(UNI), borrowed))[0].mul(ratio).div(1000000).mul(101).div(100) // borrowed * spot * ratio * 1.01 (for margin)

    // Build vault
    await ladle.build(seriesId, UNI, 0)
    const logs = await cauldron.queryFilter(cauldron.filters.VaultBuilt(null, null, null, null))
    const vaultId = logs[logs.length - 1].args.vaultId
    console.log(`vault: ${vaultId}`)

    // Post uni and borrow fyToken
    const uniJoinAddress = await ladle.joins(UNI)
    console.log(`posting ${posted} UNI out of ${await uni.balanceOf(whaleAcc.address)}`)
    await uni.connect(whaleAcc).transfer(uniJoinAddress, posted)
    console.log(`borrowing ${borrowed} ${baseId} with ${seriesId}`)
    await ladle.pour(vaultId, whaleAcc.address, posted, borrowed)
    console.log(`posted and borrowed`)

    // At the time of writing, this vault is collateralized at 268%. Find more at https://yield-protocol-info.netlify.app/#/vaults
    console.log(`Vault to liquidate: ${vaultId}`)

    // Check collateralToDebtRatio, just to make sure it doesn't revert
    console.log(`Collateral to debt ratio: ${await flashLiquidator.callStatic.collateralToDebtRatio(vaultId)}`)

    // Raise the required collateralization to 300%
    const timelockAcc = await impersonate(timelockAddress, WAD)
    const spotOracle = await cauldron.spotOracles(baseId, UNI)
    console.log(`Raising required collateralization to 3000%`)
    await cauldron.connect(timelockAcc).setSpotOracle(baseId, UNI, spotOracle.oracle, 30000000)

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

    console.log(`Profit: ${await weth.balanceOf(recipient)}`)

    console.log(`Restore collateralization ratio`)
    await cauldron.connect(timelockAcc).setSpotOracle(baseId, UNI, spotOracle.oracle, spotOracle.ratio)
  }
})()