import 'dotenv/config'

import yargs from 'yargs'
import { nodeUrl, accounts } from './utils/network'
import { HardhatUserConfig } from 'hardhat/config'

import 'hardhat-contract-sizer'
import 'hardhat-spdx-license-identifier'
import 'hardhat-deploy'
import 'hardhat-docgen'
import 'hardhat-abi-exporter'
import '@nomiclabs/hardhat-ethers'
import '@nomiclabs/hardhat-solhint'
import '@nomiclabs/hardhat-truffle5'
import '@nomiclabs/hardhat-vyper';
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
  .parseSync();

if (argv.enableGasReport) {
  import('hardhat-gas-reporter'); // eslint-disable-line
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
      'contracts/perpetualManager/PerpetualManagerFront.sol': {
        version: '0.8.7',
        settings: {
          optimizer: {
            enabled: true,
            runs: 283,
          },
        },
      },
    },
  },
  vyper: {
    version: '0.2.15',
  },
  defaultNetwork: 'hardhat',
  networks: {
    hardhat: {
      accounts: accounts('local'),
      live: argv.fork || false,
      blockGasLimit: 125e5,
      hardfork: 'london',
      forking: {
        enabled: argv.fork || false,
        url: nodeUrl('fork'),
        blockNumber: 13473325,
      },
      mining: argv.disableAutoMining
        ? {
            auto: false,
            interval: 1000,
          }
        : { auto: true },
      chainId: 1337,
    },
    ganache: {
      url: 'http://127.0.0.1:8545',
      gas: 12e6,
      gasPrice: 40e9,
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
      gas: 12e6,
      gasPrice: 12e8,
      chainId: 4,
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
    user: 2,
    slp: 3,
    ha: 4,
    keeper: 5,
    user2: 6,
    slp2: 7,
    ha2: 8,
    keeper2: 9,
  },
  mocha: {
    timeout: 60000,
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