import { BigNumber } from 'ethers'
import { ETH, DAI, USDC, WBTC, WSTETH, STETH, LINK, ENS, UNI, WAD } from './constants'
import { FYDAI2112, FYDAI2203, FYUSDC2112, FYUSDC2203 } from './constants'

export const developer: Map<number, string> = new Map([
  [1, '0xC7aE076086623ecEA2450e364C838916a043F9a8'],
  [4, '0x5AD7799f02D5a829B2d6FA085e6bd69A872619D5'],
  [42, '0x5AD7799f02D5a829B2d6FA085e6bd69A872619D5'],
])

export const whales: Map<string, string> = new Map([
  [WSTETH,  '0x06920c9fc643de77b99cb7670a944ad31eaaa260'],
  [UNI,  '0x5f246d7d19aa612d6718d27c1da1ee66859586b0'],
])

export const assets: Map<string, string> = new Map([
  [ETH,    '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2'],
  [DAI,    '0x6B175474E89094C44Da98b954EedeAC495271d0F'],
  [USDC,   '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48'],
  [WBTC,   '0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599'],
  [WSTETH, '0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0'],
  [STETH,  '0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84'],
  [LINK,   '0x514910771af9ca656af840dff83e8264ecf986ca'],
  [ENS,    '0xC18360217D8F7Ab5e7c516566761Ea12Ce7F9D72'],
])

export const seriesIds = [FYDAI2112, FYDAI2203, FYUSDC2112, FYUSDC2203]



