import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/dist/src/signer-with-address'

import { constants, id } from '@yield-protocol/utils-v2'
const { WAD, THREE_MONTHS } = constants
import { RATE } from '../src/constants'

import FYTokenArtifact from '../artifacts/contracts/FYToken.sol/FYToken.json'
import JoinFactoryArtifact from '../artifacts/contracts/JoinFactory.sol/JoinFactory.json'
import OracleMockArtifact from '../artifacts/contracts/mocks/oracles/OracleMock.sol/OracleMock.json'
import ERC20MockArtifact from '../artifacts/contracts/mocks/ERC20Mock.sol/ERC20Mock.json'
import PoolFactoryMockArtifact from '../artifacts/contracts/mocks/PoolFactoryMock.sol/PoolFactoryMock.json'

import { Cauldron } from '../typechain/Cauldron'
import { Join } from '../typechain/Join'
import { JoinFactory } from '../typechain/JoinFactory'
import { FYToken } from '../typechain/FYToken'
import { ERC20Mock } from '../typechain/ERC20Mock'
import { OracleMock } from '../typechain/OracleMock'
import { PoolMock } from '../typechain/PoolMock'
import { PoolFactoryMock } from '../typechain/PoolFactoryMock'

import { ethers, waffle } from 'hardhat'
import { expect } from 'chai'
const { deployContract, loadFixture } = waffle

import { YieldEnvironment } from './shared/fixtures'
import { LadleWrapper } from '../src/ladleWrapper'

describe('Ladle - admin', function () {
  this.timeout(0)

  let env: YieldEnvironment
  let ownerAcc: SignerWithAddress
  let otherAcc: SignerWithAddress
  let owner: string
  let other: string
  let cauldron: Cauldron
  let fyToken: FYToken
  let base: ERC20Mock
  let baseJoin: Join
  let joinFactory: JoinFactory
  let ilk: ERC20Mock
  let ilkJoin: Join
  let poolFactory: PoolFactoryMock
  let pool: PoolMock
  let oracle: OracleMock
  let rateOracle: OracleMock
  let ladle: LadleWrapper
  let ladleFromOther: LadleWrapper

  const mockAssetId = ethers.utils.hexlify(ethers.utils.randomBytes(6))
  const mockSeriesId = ethers.utils.hexlify(ethers.utils.randomBytes(6))

  async function fixture() {
    return await YieldEnvironment.setup(ownerAcc, [baseId], [])
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
  const otherIlkId = ethers.utils.hexlify(ethers.utils.randomBytes(6))
  const seriesId = ethers.utils.hexlify(ethers.utils.randomBytes(6))
  const otherSeriesId = ethers.utils.hexlify(ethers.utils.randomBytes(6))
  const ratio = 1000000 // == 100% collateralization ratio

  let maturity: number

  beforeEach(async () => {
    env = await loadFixture(fixture)
    cauldron = env.cauldron
    ladle = env.ladle
    ladleFromOther = ladle.connect(otherAcc)
    base = env.assets.get(baseId) as ERC20Mock
    baseJoin = env.joins.get(baseId) as Join
    rateOracle = env.oracles.get(RATE) as OracleMock

    // ==== Set testing environment ====
    ilk = (await deployContract(ownerAcc, ERC20MockArtifact, [ilkId, 'Mock Ilk'])) as ERC20Mock
    oracle = (await deployContract(ownerAcc, OracleMockArtifact, [])) as OracleMock
    await oracle.set(WAD)

    await cauldron.addAsset(ilkId, ilk.address)
    await cauldron.setDebtLimits(baseId, ilkId, WAD.mul(2), 0, 0)
    await cauldron.setSpotOracle(baseId, ilkId, oracle.address, ratio)

    // Deploy a join
    joinFactory = (await deployContract(ownerAcc, JoinFactoryArtifact, [])) as JoinFactory
    const joinAddress = await joinFactory.calculateJoinAddress(ilk.address) // Get the address
    await joinFactory.createJoin(ilk.address) // Create the Join (doesn't return anything outside a contract call)
    ilkJoin = (await ethers.getContractAt('Join', joinAddress, ownerAcc)) as Join
    await ilkJoin.grantRoles([id('join(address,uint128)'), id('exit(address,uint128)')], ladle.address)

    // Deploy a series
    const { timestamp } = await ethers.provider.getBlock('latest')
    maturity = timestamp + THREE_MONTHS
    fyToken = (await deployContract(ownerAcc, FYTokenArtifact, [
      baseId,
      rateOracle.address,
      baseJoin.address,
      maturity,
      seriesId,
      'Mock FYToken',
    ])) as FYToken
    await cauldron.addSeries(seriesId, baseId, fyToken.address)
    await cauldron.addIlks(seriesId, [ilkId])

    // Deploy a pool
    poolFactory = (await deployContract(ownerAcc, PoolFactoryMockArtifact, [])) as PoolFactoryMock
    const poolAddress = await poolFactory.calculatePoolAddress(base.address, fyToken.address) // Get the address
    await poolFactory.createPool(base.address, fyToken.address) // Create the Pool (doesn't return anything outside a contract call)
    pool = (await ethers.getContractAt('PoolMock', poolAddress, ownerAcc)) as PoolMock
  })

  it('sets the borrowing fee', async () => {
    const fee = WAD.div(100)
    expect(await ladle.setFee(fee))
      .to.emit(ladle.ladle, 'FeeSet') // The event is emitted by the ladle, not the wrapper
      .withArgs(fee)
    expect(await ladle.borrowingFee()).to.equal(fee)
  })

  describe('join admin', async () => {
    it('does not allow adding a join before adding its ilk', async () => {
      await expect(ladle.addJoin(mockAssetId, ilkJoin.address)).to.be.revertedWith('Asset not found')
    })

    it('does not allow adding a join with a mismatched ilk', async () => {
      await expect(ladle.addJoin(baseId, ilkJoin.address)).to.be.revertedWith('Mismatched asset and join')
    })

    it('adds a join', async () => {
      expect(await ladle.addJoin(ilkId, ilkJoin.address))
        .to.emit(ladle.ladle, 'JoinAdded') // The event is emitted by the ladle, not the wrapper
        .withArgs(ilkId, ilkJoin.address)
      expect(await ladle.joins(ilkId)).to.equal(ilkJoin.address)
    })

    it('adds the same join for a second ilk of the same asset', async () => {
      await cauldron.addAsset(otherIlkId, ilk.address)
      expect(await ladle.addJoin(otherIlkId, ilkJoin.address))
        .to.emit(ladle.ladle, 'JoinAdded')
        .withArgs(otherIlkId, ilkJoin.address)
      expect(await ladle.joins(otherIlkId)).to.equal(ilkJoin.address)
    })
  })

  describe('pool admin', async () => {
    it('does not allow adding a pool before adding its series', async () => {
      await expect(ladle.addPool(mockSeriesId, pool.address)).to.be.revertedWith('Series not found')
    })

    it('does not allow adding a pool with a mismatched fyToken', async () => {
      // Deploy other series
      const otherFYToken = (await deployContract(ownerAcc, FYTokenArtifact, [
        baseId,
        rateOracle.address,
        baseJoin.address,
        maturity,
        seriesId,
        'Mock FYToken',
      ])) as FYToken
      await cauldron.addSeries(otherSeriesId, baseId, otherFYToken.address)
      await cauldron.addIlks(otherSeriesId, [ilkId])

      await expect(ladle.addPool(otherSeriesId, pool.address)).to.be.revertedWith('Mismatched pool fyToken and series')
    })

    it('does not allow adding a pool with a mismatched base', async () => {
      const poolAddress = await poolFactory.calculatePoolAddress(ilk.address, fyToken.address) // Get the address
      await poolFactory.createPool(ilk.address, fyToken.address) // Create the Pool (doesn't return anything outside a contract call)
      const otherPool = (await ethers.getContractAt('PoolMock', poolAddress, ownerAcc)) as PoolMock

      await expect(ladle.addPool(seriesId, otherPool.address)).to.be.revertedWith('Mismatched pool base and series')
    })

    it('adds a pool', async () => {
      expect(await ladle.addPool(seriesId, pool.address))
        .to.emit(ladle.ladle, 'PoolAdded')
        .withArgs(seriesId, pool.address)
      expect(await ladle.pools(seriesId)).to.equal(pool.address)
    })
  })
})