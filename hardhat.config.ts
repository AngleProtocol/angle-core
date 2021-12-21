/// ENVVAR
// - ENABLE_GAS_REPORT
// - CI
// - RUNS
import 'dotenv/config'

import yargs from 'yargs'
import { nodeUrl, accounts } from './utils/network'
import { HardhatUserConfig, subtask } from 'hardhat/config'
import { TASK_COMPILE_GET_COMPILATION_TASKS } from 'hardhat/builtin-tasks/task-names'
import '@nomiclabs/hardhat-vyper'
import path from 'path'
import fse from 'fs-extra'

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

const VYPER_TEMP_DIR = path.join(__dirname, 'vyper_temp_dir')
subtask(
  TASK_COMPILE_GET_COMPILATION_TASKS,
  async (_, { config }, runSuper): Promise<string[]> => {
    await runSuper()

    // We save already compiled vyper artifacts
    const glob = await import('glob')
    const vyFiles = glob.sync(path.join(config.paths.artifacts, '**', '*.vy'))
    const vpyFiles = glob.sync(
      path.join(config.paths.artifacts, '**', '*.v.py'),
    )
    const files = [...vyFiles, ...vpyFiles]

    await fse.remove(VYPER_TEMP_DIR)
    await fse.mkdir(VYPER_TEMP_DIR)
    for (const file of files) {
      const filename = file.replace(config.paths.artifacts + '/contracts/', '')
      await fse.move(file, path.join(VYPER_TEMP_DIR, filename))
    }

    return ['compile:solidity', 'restore_vyper_artifacts', 'compile:vyper']
  },
)

subtask<{ force: boolean }>(
  'restore_vyper_artifacts',
  async (args, { config }) => {
    if (!args.force) {
      const dirs = await fse.readdir(VYPER_TEMP_DIR)

      for (const dir of dirs) {
        const destination = path.join(config.paths.artifacts, 'contracts', dir)

        if (!fse.pathExists(destination)) {
          await fse.move(
            path.join(VYPER_TEMP_DIR, dir),
            path.join(config.paths.artifacts, 'contracts', dir),
          )
        } else {
          const files = await fse.readdir(path.join(VYPER_TEMP_DIR, dir))
          for (const file of files) {
            await fse.move(
              path.join(VYPER_TEMP_DIR, dir, file),
              path.join(config.paths.artifacts, 'contracts', dir, file),
              {
                overwrite: true,
              },
            )
          }
        }
      }
    }
    await fse.remove(VYPER_TEMP_DIR)
  },
)

subtask('compile:vyper', async (_, { config, artifacts }) => {
  const { compile } = await import('./vyperCompile')
  const { generateVyperTypes } = await import('./vyperTypesGenerator')

  await compile(config.vyper, config.paths, artifacts)
  await generateVyperTypes()
})

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
    version: '0.2.16',
  },
  defaultNetwork: 'hardhat',
  networks: {
    hardhat: {
      accounts: accounts('mainnet'),
      live: argv.fork || false,
      blockGasLimit: 125e5,
      initialBaseFeePerGas: 0,
      hardfork: 'london',
      forking: {
        enabled: argv.fork || false,
        url: nodeUrl('fork'),
        // blockNumber: 13473325,
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
