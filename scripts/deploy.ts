import { ethers, waffle, network } from 'hardhat'

import FlashLiquidatorArtifact from '../artifacts/contracts/FlashLiquidator.sol/FlashLiquidator.json'
import { FlashLiquidator } from '../typechain/FlashLiquidator'

const { deployContract } = waffle

/**
 * @dev This script deploys the FlashLiquidator
 */

;(async () => {
  const recipient = '0x3b43618b2961D5fbDf269A72ACcb225Df70dCb48'
  const swapRouter = '0xE592427A0AEce92De3Edee1F18E0157C05861564'
  const factory = '0x1F98431c8aD98523631AE4a59f267346ea31F984'
  const weth = '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2'
  const dai = '0x6B175474E89094C44Da98b954EedeAC495271d0F'

  const witch = '0x53C3760670f6091E1eC76B4dd27f73ba4CAd5061'

  let [ownerAcc] = await ethers.getSigners()
  // If we are running in a mainnet fork, we give some Ether to the current account
  if (ownerAcc.address === '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266') {
    await network.provider.send('hardhat_setBalance', [
      ownerAcc.address,
      ethers.utils.parseEther('1000000').toHexString(),
    ])
  }

  const args = [recipient, witch, factory, swapRouter, dai, weth]
  let flashLiquidator = (await deployContract(ownerAcc, FlashLiquidatorArtifact, args)) as FlashLiquidator
  console.log(`FlashLiquidator deployed at ${flashLiquidator.address}`)
  console.log(`npx hardhat verify --network ${network.name} ${flashLiquidator.address} ${args.join(' ')}`)
})()
