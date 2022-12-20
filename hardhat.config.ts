/// ENVVAR
// - ENABLE_GAS_REPORT
// - CI
// - RUNS
import 'dotenv/config'

import yargs from 'yargs'
import { nodeUrl, accounts } from './utils/network'
import { HardhatUserConfig } from 'hardhat/config'
import '@nomiclabs/hardhat-vyper'

import 'hardhat-contract-sizer'
import 'hardhat-spdx-license-identifier'
import 'hardhat-docgen'
import 'hardhat-deploy'
import 'hardhat-abi-exporter'
import '@nomiclabs/hardhat-ethers'
import '@nomiclabs/hardhat-truffle5'
import '@nomiclabs/hardhat-solhint'
import '@openzeppelin/hardhat-upgrades'
import 'solidity-coverage'
import '@tenderly/hardhat-tenderly'
import '@typechain/hardhat'

const argv = yargs
  .env('')
  .boolean('enableGasReport')
  .boolean('ci')
  .number('runs')
  .boolean('fork')
  .boolean('disableAutoMining')
  .parseSync()

if (argv.enableGasReport) {
  import('hardhat-gas-reporter') // eslint-disable-line
}

const config: HardhatUserConfig = {
  solidity: {
    compilers: [
      {
        version: '0.8.7',
        settings: {
          optimizer: {
            enabled: true,
            runs: 1000000,
          },
          // debug: { revertStrings: 'strip' },
        },
      },
    ],
    overrides: {
      'contracts/stableMaster/StableMasterFront.sol': {
        version: '0.8.7',
        settings: {
          optimizer: {
            enabled: true,
            runs: 830,
          },
        },
      },
      'contracts/deprecated/StableMasterFrontOld.sol': {
        version: '0.8.7',
        settings: {
          optimizer: {
            enabled: true,
            runs: 830,
          },
        },
      },
      'contracts/perpetualManager/PerpetualManagerFront.sol': {
        version: '0.8.7',
        settings: {
          optimizer: {
            enabled: true,
            runs: 260,
          },
        },
      },
      'contracts/router/AngleRouter01.sol': {
        version: '0.8.7',
        settings: {
          optimizer: {
            enabled: true,
            runs: 4650,
          },
        },
      },
      'contracts/mock/PerpetualManagerFrontUpgrade.sol': {
        version: '0.8.7',
        settings: {
          optimizer: {
            enabled: true,
            runs: 1,
          },
        },
      },
    },
  },
  vyper: {
    compilers: [
      {
        version: '0.3.3',
      },
      {
        version: '0.2.16',
      },
    ],
  },
  defaultNetwork: 'hardhat',
  networks: {
    hardhat: {
      accounts: accounts('mainnet'),
      live: false,
      blockGasLimit: 125e5,
      initialBaseFeePerGas: 0,
      hardfork: 'london',
      forking: {
        enabled: argv.fork || false,
        url: nodeUrl('fork'),
        // blockNumber: 14717592,
      },
      mining: argv.disableAutoMining
        ? {
            auto: false,
            interval: 1000,
          }
        : { auto: true },
      chainId: 1337,
    },
    kovan: {
      live: false,
      url: nodeUrl('kovan'),
      accounts: accounts('kovan'),
      gas: 12e6,
      gasPrice: 1e9,
      chainId: 42,
    },
    rinkeby: {
      live: true,
      url: nodeUrl('rinkeby'),
      accounts: accounts('rinkeby'),
      gas: 'auto',
      // gasPrice: 12e8,
      chainId: 4,
    },
    goerli: {
      live: true,
      url: nodeUrl('goerli'),
      accounts: accounts('goerli'),
      gas: 12e6,
      chainId: 5,
    },
    mumbai: {
      url: nodeUrl('mumbai'),
      accounts: accounts('mumbai'),
      gas: 'auto',
    },
    polygon: {
      url: nodeUrl('polygon'),
      accounts: accounts('polygon'),
      gas: 'auto',
    },
    mainnet: {
      live: true,
      url: nodeUrl('mainnet'),
      accounts: accounts('mainnet'),
      gas: 'auto',
      gasMultiplier: 1.3,
      chainId: 1,
    },
    angleTestNet: {
      url: nodeUrl('angle'),
      accounts: accounts('angle'),
      gas: 12e6,
      gasPrice: 5e9,
    },
  },
  paths: {
    sources: './contracts',
    tests: './test',
  },
  namedAccounts: {
    deployer: 0,
    guardian: 1,
    governor: 2,
    slp: 3,
    ha: 4,
    keeper: 5,
    user2: 6,
    slp2: 7,
    ha2: 8,
    keeper2: 9,
    user: 10,
  },
  mocha: {
    timeout: 100000,
    retries: argv.ci ? 10 : 0,
  },
  contractSizer: {
    alphaSort: true,
    runOnCompile: false,
    disambiguatePaths: false,
  },
  gasReporter: {
    currency: 'USD',
    outputFile: argv.ci ? 'gas-report.txt' : undefined,
  },
  spdxLicenseIdentifier: {
    overwrite: true,
    runOnCompile: false,
  },
  docgen: {
    path: './docs',
    clear: true,
    runOnCompile: false,
  },
  abiExporter: {
    path: './export/abi',
    clear: true,
    flat: true,
    spacing: 2,
  },
  typechain: {
    outDir: 'typechain',
    target: 'ethers-v5',
  },
}

export default config
