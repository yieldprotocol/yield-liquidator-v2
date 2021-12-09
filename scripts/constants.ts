import { ethers, BigNumber } from 'ethers'

export const ZERO = BigNumber.from(0)
export const ZERO_ADDRESS = '0x'+'00'.repeat(20)
export const DEC6 = BigNumber.from(10).pow(6)
export const WAD = BigNumber.from(10).pow(18)
export const ONEUSDC = BigNumber.from(10).pow(6)
export const ONEWBTC = BigNumber.from(10).pow(8)
export const RAY = BigNumber.from(10).pow(27)
export const MAX128 = BigNumber.from(2).pow(128).sub(1)
export const MAX256 = BigNumber.from(2).pow(256).sub(1)
export const THREE_MONTHS: number = 3 * 30 * 24 * 60 * 60
export const ROOT = '0x00000000'

export const ETH    = ethers.utils.formatBytes32String('00').slice(0, 14)
export const DAI    = ethers.utils.formatBytes32String('01').slice(0, 14)
export const USDC   = ethers.utils.formatBytes32String('02').slice(0, 14)
export const WBTC   = ethers.utils.formatBytes32String('03').slice(0, 14)
export const WSTETH = ethers.utils.formatBytes32String('04').slice(0, 14)
export const STETH  = ethers.utils.formatBytes32String('05').slice(0, 14)
export const LINK   = ethers.utils.formatBytes32String('06').slice(0, 14)
export const ENS    = ethers.utils.formatBytes32String('07').slice(0, 14)
export const YVDAI  = ethers.utils.formatBytes32String('08').slice(0, 14)
export const YVUSDC = ethers.utils.formatBytes32String('09').slice(0, 14)
export const UNI    = ethers.utils.formatBytes32String('10').slice(0, 14)

export const CHAINLINK = 'chainlinkOracle'
export const COMPOUND  = 'compoundOracle'
export const COMPOSITE = 'compositeOracle'
export const LIDO      = 'lidoOracle'
export const UNISWAP   = 'uniswapOracle'

export const CDAI  = ethers.utils.formatBytes32String('CDAI').slice(0, 14)
export const CUSDC = ethers.utils.formatBytes32String('CUSDC').slice(0, 14)
export const CWBTC = ethers.utils.formatBytes32String('CWBTC').slice(0, 14)
export const CUSDT = ethers.utils.formatBytes32String('CUSDT').slice(0, 14)

export const EODEC21 = 1640919600
export const EOMAR22 = 1648177200
export const EOJUN22 = 1656039600 // Friday, June 24, 2022 3:00:00 PM GMT+0

export const FYETH2203  = ethers.utils.formatBytes32String('0005').slice(0, 14) // End of 5th quarter from 1st January 2021
export const FYETH2206  = ethers.utils.formatBytes32String('0006').slice(0, 14) // End of 6th quarter from 1st January 2021
export const FYDAI2112  = ethers.utils.formatBytes32String('0104').slice(0, 14)
export const FYDAI2203  = ethers.utils.formatBytes32String('0105').slice(0, 14)
export const FYUSDC2112 = ethers.utils.formatBytes32String('0204').slice(0, 14)
export const FYUSDC2203 = ethers.utils.formatBytes32String('0205').slice(0, 14)

export const YSDAI6MMS  = 'YSDAI6MMS' // Yield Strategy DAI 6M Mar Sep
export const YSDAI6MJD  = 'YSDAI6MJD' // Yield Strategy DAI 6M Jun Dec
export const YSUSDC6MMS = 'YSUSDC6MMS' // Yield Strategy USDC 6M Mar Sep
export const YSUSDC6MJD = 'YSUSDC6MJD' // Yield Strategy USDC 6M Jun Dec
export const YSETH6MMS  = 'YSETH6MMS' // Yield Strategy ETH 6M Mar Sep
export const YSETH6MJD  = 'YSETH6MJD' // Yield Strategy ETH 6M Jun Dec

export const ONE64 = BigNumber.from('18446744073709551616') // In 64.64 format
export const secondsInOneYear = BigNumber.from(31557600)
export const secondsInTenYears = secondsInOneYear.mul(10) // Seconds in 10 years
export const k = ONE64.div(secondsInTenYears)

export const g0 = ONE64 // No fees
export const g1 = ONE64.mul(950).div(1000) // Sell base to the pool
export const g2 = ONE64.mul(1000).div(950) // Sell fyToken to the pool

export const CHI  = ethers.utils.formatBytes32String('CHI').slice(0, 14)
export const RATE = ethers.utils.formatBytes32String('RATE').slice(0, 14)

