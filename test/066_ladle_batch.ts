import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/dist/src/signer-with-address'
import { WAD } from './shared/constants'

import { Cauldron } from '../typechain/Cauldron'
import { FYToken } from '../typechain/FYToken'
import { ERC20Mock } from '../typechain/ERC20Mock'
import { Ladle } from '../typechain/Ladle'

import { ethers, waffle } from 'hardhat'
import { expect } from 'chai'
const { loadFixture } = waffle

import { YieldEnvironment } from './shared/fixtures'

describe('Ladle - multicall', function () {
  this.timeout(0)

  let env: YieldEnvironment
  let ownerAcc: SignerWithAddress
  let otherAcc: SignerWithAddress
  let owner: string
  let other: string
  let cauldron: Cauldron
  let fyToken: FYToken
  let base: ERC20Mock
  let ladle: Ladle

  async function fixture() {
    return await YieldEnvironment.setup(ownerAcc, [baseId, ilkId], [seriesId])
  }

  before(async () => {
    const signers = await ethers.getSigners()
    ownerAcc = signers[0]
    owner = await ownerAcc.getAddress()

    otherAcc = signers[1]
    other = await otherAcc.getAddress()
  })

  const baseId = ethers.utils.hexlify(ethers.utils.randomBytes(6))
  const ilkId = ethers.utils.hexlify(ethers.utils.randomBytes(6))
  const seriesId = ethers.utils.hexlify(ethers.utils.randomBytes(6))
  const vaultId = ethers.utils.hexlify(ethers.utils.randomBytes(12))

  beforeEach(async () => {
    env = await loadFixture(fixture)
    cauldron = env.cauldron
    ladle = env.ladle
    base = env.assets.get(baseId) as ERC20Mock
    fyToken = env.series.get(seriesId) as FYToken
  })

  it('builds a vault and posts to it', async () => {
    const buildCall = ladle.interface.encodeFunctionData('build', [vaultId, seriesId, ilkId])
    const pourCall = ladle.interface.encodeFunctionData('pour', [vaultId, owner, WAD, WAD])
    await ladle.batch([buildCall, pourCall], true)

    const vault = await cauldron.vaults(vaultId)
    expect(vault.owner).to.equal(owner)
    expect(vault.seriesId).to.equal(seriesId)
    expect(vault.ilkId).to.equal(ilkId)

    expect(await fyToken.balanceOf(owner)).to.equal(WAD)
  })

  it('reverts with the appropriate message when needed', async () => {
    const pourCall = ladle.interface.encodeFunctionData('pour', [vaultId, owner, WAD, WAD])
    await expect(ladle.batch([pourCall], true)).to.be.revertedWith('Only vault owner')
  })
})
