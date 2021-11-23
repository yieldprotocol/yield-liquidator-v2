import { ethers, waffle, network } from 'hardhat'

import WstethFlashLiquidatorArtifact from '../artifacts/contracts/WstethFlashLiquidator.sol/WstethFlashLiquidator.json'
import { WstethFlashLiquidator } from '../typechain/WstethFlashLiquidator'

const { deployContract } = waffle

/**
 * @dev This script deploys the FlashLiquidator
 */

;(async () => {
  const recipient = '0x3b43618b2961D5fbDf269A72ACcb225Df70dCb48'
  const swapRouter = '0xE592427A0AEce92De3Edee1F18E0157C05861564'
  const factory = '0x1F98431c8aD98523631AE4a59f267346ea31F984'
  const weth = '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2'
  const dai = '0x6b175474e89094c44da98b954eedeac495271d0f'
  const witch = '0x53C3760670f6091E1eC76B4dd27f73ba4CAd5061'
  const steth = '0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84'
  const wsteth = '0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0'
  const curvestableswap = '0xDC24316b9AE028F1497c275EB9192a3Ea0f67022'
  let [ownerAcc] = await ethers.getSigners()
  // If we are running in a mainnet fork, we give some Ether to the current account
  if (ownerAcc.address === '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266') {
    await network.provider.send('hardhat_setBalance', [
      ownerAcc.address,
      ethers.utils.parseEther('1000000').toHexString(),
    ])
  }

  const args = [recipient, swapRouter, factory, weth, witch, curvestableswap, wsteth, steth, dai]
  let flashLiquidator = (await deployContract(ownerAcc, WstethFlashLiquidatorArtifact, args)) as WstethFlashLiquidator
  console.log(`FlashLiquidator deployed at ${flashLiquidator.address}`)
  console.log(`npx hardhat verify --network ${network.name} ${flashLiquidator.address} ${args.join(' ')}`)
})()
