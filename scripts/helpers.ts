import { ethers, network, run, waffle } from 'hardhat'
import * as fs from 'fs'
import * as hre from 'hardhat'
import { existsSync, readFileSync, writeFileSync, mkdirSync } from 'fs';
import { join, dirname } from "path";
import { BigNumber } from 'ethers'
import { BaseProvider } from '@ethersproject/providers'
import { THREE_MONTHS, ROOT } from './constants'
import { AccessControl, Timelock } from '../typechain'


/** @dev Determines chainId and retrieves address mappings from governance and protocol json files*/
/** returns a 2 element array of Map's for **governance** and **protocol**, with contract names mapped to addresses */
export const getGovernanceProtocolAddresses = async (chainId: number): Promise<Map<string, string>[]> => {
  if (chainId !== 1 && chainId !== 42) throw `Chain id ${chainId} not found. Only Kovan and Mainnet supported`
  const path = chainId === 1 ? './addresses/mainnet/' : './addresses/kovan/'
  const governance = jsonToMap(fs.readFileSync(`${path}governance.json`, 'utf8')) as Map<string, string>
  const protocol = jsonToMap(fs.readFileSync(`${path}protocol.json`, 'utf8')) as Map<string, string>
  return [governance, protocol]
}

/** @dev Get the chain id, even after forking. This works because WETH10 was deployed at the same
 * address in all networks, and recorded its chainId at deployment */
export const getOriginalChainId = async (): Promise<number> => {
  const ABI = ['function deploymentChainId() view returns (uint256)']
  const weth10Address = '0xf4BB2e28688e89fCcE3c0580D37d36A7672E8A9F'
  const weth10 = new ethers.Contract(weth10Address, ABI, ethers.provider)
  let chainId
  if ((await ethers.provider.getCode(weth10Address)) === '0x') {
    chainId = 31337 // local or unknown network
  } else {
    chainId = (await weth10.deploymentChainId()).toNumber()
  }
  console.log(`ChainId: ${chainId}`)
  return chainId
}

/** @dev Get the first account or, if we are in a fork, impersonate the one at the address passed on as a parameter */
export const getOwnerOrImpersonate = async (impersonatedAddress: string, balance?: BigNumber) => {
  let [ownerAcc] = await ethers.getSigners()
  const on_fork = ownerAcc.address === '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266'
  if (on_fork) {
    console.log(`Running on a fork, impersonating ${impersonatedAddress}`)
    await hre.network.provider.request({
      method: 'hardhat_impersonateAccount',
      params: [impersonatedAddress],
    })
    ownerAcc = await ethers.getSigner(impersonatedAddress)

    // Get some Ether while we are at it
    await hre.network.provider.request({
      method: 'hardhat_setBalance',
      params: [impersonatedAddress, '0x1000000000000000000000'],
    })
  }
  return ownerAcc
}

/** @dev Impersonate an account and optionally add some ether to it */
export const impersonate = async (account: string, balance?: BigNumber) => {
  await hre.network.provider.request({
    method: 'hardhat_impersonateAccount',
    params: [account],
  })
  const ownerAcc = await ethers.getSigner(account)

  if (balance !== undefined) {
    await hre.network.provider.request({
      method: 'hardhat_setBalance',
      params: [account, '0x1000000000000000000000'], // ethers.utils.hexlify(balance)?
    })
  }
  return ownerAcc
}

/**
 * @dev Given a timelock contract and a proposal hash, propose it, approve it or execute it,
 * depending on the proposal state in the timelock.
 * If approving a proposal and on a fork, impersonate the multisig address passed on as a parameter.
 */
export const proposeApproveExecute = async (
  timelock: Timelock,
  proposal: Array<{ target: string; data: string }>,
  multisig?: string
) => {
  // Propose, approve, execute
  const txHash = await timelock.hash(proposal)
  console.log(`Proposal: ${txHash}`)
  // Depending on the proposal state, propose, approve (if in a fork, impersonating the multisig), or execute
  if ((await timelock.proposals(txHash)).state === 0) {
    // Propose
    await timelock.propose(proposal)
    while ((await timelock.proposals(txHash)).state < 1) {}
    console.log(`Proposed ${txHash}`)
  } else if ((await timelock.proposals(txHash)).state === 1) {
    // Approve, impersonating multisig if in a fork
    let [ownerAcc] = await ethers.getSigners()
    const on_fork = ownerAcc.address === '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266'
    if (on_fork) {
      // If running on a mainnet fork, impersonating the multisig will work
      if (multisig === undefined) throw 'Must provide an address with approve permissions to impersonate'
      console.log(`Running on a fork, impersonating multisig at ${multisig}`)
      await hre.network.provider.request({
        method: 'hardhat_impersonateAccount',
        params: [multisig],
      })
      // Make sure the multisig has Ether
      await hre.network.provider.request({
        method: 'hardhat_setBalance',
        params: [multisig, '0x100000000000000000000'], // ethers.utils.hexlify(balance)?
      })
      const multisigAcc = await ethers.getSigner(multisig as unknown as string)
      await timelock.connect(multisigAcc).approve(txHash)
      while ((await timelock.proposals(txHash)).state < 2) {}
      console.log(`Approved ${txHash}`)
    } else {
      // On kovan we have approval permissions
      await timelock.approve(txHash)
      while ((await timelock.proposals(txHash)).state < 2) {}
      console.log(`Approved ${txHash}`)
    }
  } else if ((await timelock.proposals(txHash)).state === 2) {
    // Execute
    await timelock.execute(proposal)
    while ((await timelock.proposals(txHash)).state > 0) {}
    console.log(`Executed ${txHash}`)
  }
}

export const transferFromFunder = async (
  tokenAddress: string,
  recipientAddress: string,
  amount: BigNumber,
  funderAddress: string
) => {
  const tokenContract = await ethers.getContractAt('ERC20', tokenAddress)
  const tokenSymbol = await tokenContract.symbol()
  try {
    console.log(
      `Attempting to move ${ethers.utils.formatEther(
        amount
      )} ${tokenSymbol} from whale account ${funderAddress} to account ${recipientAddress}`
    )
    /* if using whaleTransfer, impersonate that account, and transfer token from it */
    await network.provider.request({
      method: 'hardhat_impersonateAccount',
      params: [funderAddress],
    })
    const _signer = await ethers.provider.getSigner(funderAddress)
    const _tokenContract = await ethers.getContractAt('ERC20', tokenAddress, _signer)
    await _tokenContract.transfer(recipientAddress, amount)
    console.log('Transfer Successful.')

    await network.provider.request({
      method: 'hardhat_stopImpersonatingAccount',
      params: [funderAddress],
    })
  } catch (e) {
    console.log(
      `Warning: Failed transferring ${tokenSymbol} from whale account. Some protocol features related to this token may not work`,
      e
    )
  }
}

export const generateMaturities = async (n: number) => {
  const provider: BaseProvider = await ethers.provider
  const now = (await provider.getBlock(await provider.getBlockNumber())).timestamp
  let count: number = 1
  const maturities = Array.from({ length: n }, () => now + THREE_MONTHS * count++)
  return maturities
}

export const fundExternalAccounts = async (assetList: Map<string, any>, accountList: Array<string>) => {
  const [ownerAcc] = await ethers.getSigners()
  await Promise.all(
    accountList.map((to: string) => {
      /* add test Eth */
      ownerAcc.sendTransaction({ to, value: ethers.utils.parseEther('100') })
      /* add test asset[] values (if not ETH) */
      assetList.forEach(async (value: any, key: any) => {
        if (key !== '0x455448000000') {
          await value.transfer(to, ethers.utils.parseEther('1000'))
        }
      })
    })
  )
  console.log('External test accounts funded with 100ETH, and 1000 of each asset')
}

export function bytesToString(bytes: string): string {
  return ethers.utils.parseBytes32String(bytes + '0'.repeat(66 - bytes.length))
}

export function stringToBytes6(x: string): string {
  return ethers.utils.formatBytes32String(x).slice(0, 14)
}

export function stringToBytes32(x: string): string {
  return ethers.utils.formatBytes32String(x)
}

export function bytesToBytes32(bytes: string): string {
  return stringToBytes32(bytesToString(bytes))
}

export function verify(address: string, args: any, libs?: any) {
  const libsargs = libs !== undefined ? `--libraries ${libs.toString()}` : ''
  console.log(`npx hardhat verify --network ${network.name} ${address} ${args.join(' ')} ${libsargs}`)
  /* if (network.name !== 'localhost') {
    run("verify:verify", {
      address: address,
      constructorArguments: args,
      libraries: libs,
    })
  } */
}

/* MAP to Json for file export */
export function mapToJson(map: Map<any, any>): string {
  return JSON.stringify(
    flattenContractMap(map),
    /* replacer */
    (key: any, value: any) => {
      if (value instanceof Map) {
        return {
          dataType: 'Map',
          value: [...value],
        }
      } else {
        return value
      }
    }, 2);
}

export function writeAddressMap(out_file: string, map_or_dictionary: Record<string, any>|Map<any,any>) {
  let map = new Map<any, any>();
  if (map_or_dictionary instanceof Map) {
    map = map_or_dictionary;
  } else {
    for (let k in map_or_dictionary) {
      map.set(k, map_or_dictionary[k]);
    }
  }
  writeFileSync(getAddressMappingFilePath(out_file), mapToJson(map), 'utf8');
}

export function flattenContractMap(map: Map<string, any>): Map<string, string> {
  const flat = new Map<string, string>()
  map.forEach((value: any, key: string) => {
    flat.set(key, value.address !== undefined ? value.address : value)
  })
  return flat
}

export function toAddress(obj: any): string {
  return obj.address !== undefined ? obj.address : obj
}

export function jsonToMap(json: string): Map<any, any> {
  return JSON.parse(
    json,
    /* revivor */
    (key: any, value: any) => {
      if (typeof value === 'object' && value !== null) {
        if (value.dataType === 'Map') {
          return new Map(value.value)
        }
      }
      return value
    }
  )
}

/**
 * Return path to network-specific address mapping file
 * 'government.json' can be resolved to 'addresses/kovan/government.json', for example
 */
export function getAddressMappingFilePath(file_name: string): string {
  const full_path = join("addresses", network.name, file_name);
  if (!existsSync(dirname(full_path))) {
    console.log(`Directory for ${full_path} doesn't exist, creating it`)
    mkdirSync(dirname(full_path))
  }
  return full_path;
}

/**
 * Read Map<string, string> from network-specific file
 * If the file does not exist, empty map is returned
 */
export function readAddressMappingIfExists(file_name: string): Map<string, string>{
  const full_path = getAddressMappingFilePath(file_name);
  if (existsSync(full_path)) {
    return jsonToMap(readFileSync(full_path, 'utf8'));
  }
  return new Map<string, string>();
} 

/**
 * Deploy a contract and verify it
 * Just a type-safe wrapper to deploy/log/verify a contract
 */
export async function deploy<OutT>(owner: any, artifact: any, constructor_args: any[]) {
  const ret = (await waffle.deployContract(owner, artifact, constructor_args)) as unknown as OutT;
  console.log(`[${artifact.contractName}, '${(ret as any).address}']`);
  verify((ret as any).address, constructor_args);
  return ret;
}

/**
 * Type-safe wrapper around ethers.getContractAt: return deployed instance of a contract
 */
export async function getContract<OutT>(owner:any, name: string, address: string | undefined): Promise<OutT> {
  if (address == undefined) {
    throw new Error(`null address for ${name}`);
  }
  return (await ethers.getContractAt(
    name,
    address,
    owner
  )) as unknown as OutT;
}

/**
 * Make sure Timelock has ROOT access to the contract
 */
export async function ensureRootAccess(contract: AccessControl, timelock: Timelock) {
  if (!(await contract.hasRole(ROOT, timelock.address))) {
    await contract.grantRole(ROOT, timelock.address)
    console.log(`${contract.address}.grantRoles(ROOT, timelock)`)
    while (!(await contract.hasRole(ROOT, timelock.address))) {}
  }  
}

/**
 * Get an instance of the contract from the mapping file
 * If the contract is not registered there, deploy, register and return it
 */
export async function getOrDeploy<OutT extends AccessControl>(owner: any, mapping_file: string, key: string,
    contractName: string, constructor_args: any[], timelock: Timelock): Promise<OutT>{
  const mapping = readAddressMappingIfExists(mapping_file);

  let ret: OutT
  if (mapping.get(key) === undefined) {
    ret = await deploy<OutT>(
      owner, 
      await hre.artifacts.readArtifact(contractName), 
      constructor_args);
    mapping.set(key, ret.address);
    writeAddressMap(mapping_file, mapping);
  } else {
    ret = await getContract<OutT>(
      owner,
      contractName,
      mapping.get(key));
  }
  await ensureRootAccess(ret, timelock);
  return ret;
}
