# <img src="logo.svg" alt="Angle Core Module" height="40px"> Angle Core Module

[![Docs](https://img.shields.io/badge/docs-%F0%9F%93%84-blue)](https://docs.angle.money/angle-core-module/overview)
[![Developers](https://img.shields.io/badge/developers-%F0%9F%93%84-pink)](https://developers.angle.money/core-module-contracts/protocol-and-architecture-overview)

## Documentation

### To Start With

Angle is a decentralized stablecoin protocol, designed to be both over-collateralized and capital-efficient. For more information about the protocol, you can refer to [Angle Documentation](https://docs.angle.money).

The protocol is made of different modules, each with their own set of smart contracts. This repo contains the Core module smart contracts as well as the governance-related and staking contracts of the protocol.

If you would like to know how the module works under the hood and how these smart contracts work together, you can also check [Angle Developers Doc](https://developers.angle.money/core-module-contracts/protocol-and-architecture-overview).

Whitepaper for the module can be found [here](https://docs.angle.money/overview/whitepapers).

### Further Information

For a broader overview of the protocol and its different modules, you can also check [this overview page](https://developers.angle.money) of our developers documentation.

Other Angle-related smart contracts can be found in the following repositories:

- [Angle Borrowing module contracts](https://github.com/AngleProtocol/angle-borrow)
- [Angle Strategies](https://github.com/AngleProtocol/angle-strategies)

Otherwise, for more info about the protocol, check out [this portal](https://linktr.ee/angleprotocol) of resources.

## Module Architecture

![Angle Protocol Smart Contract Architecture](./AngleArchitectureSchema.png)

## Remarks

### Strategies

The Core module relies on yield strategies. While some templates of the strategy contracts used are present in this repo, these contracts are now all developed in the [Angle Strategies repo](https://github.com/AngleProtocol/angle-strategies). This is where you can get the up-to-date version of the contracts used on-chain.

### Cross-module Contracts

Some smart contracts of the protocol, beyond strategy contracts, are used across the different modules of Angle (like the `agToken` contract) and you'll sometimes see different versions across the different repositories of the protocol.

Here are some cross-module contracts and the repos in which you should look for their correct and latest version:

- [`angle-core`](https://github.com/AngleProtocol/angle-core): All DAO-related contracts (`ANGLE`, `veANGLE`, gauges, surplus distribution, ...), `AngleRouter` contract
- [`angle-borrow`](https://github.com/AngleProtocol/angle-borrow): `agToken` contract
- [`angle-strategies`](https://github.com/AngleProtocol/angle-strategies): Yield strategies of the protocol

### Error Messages

Some smart contracts use error messages. These error messages are sometimes encoded in numbers rather than as custom errors like done most of the time. The conversion from numbers to error messages can be found in `errorMessages.json`.

## Audits

Angle Core module and governance smart contracts have been audited by Sigma Prime and [Chainsecurity](https://chainsecurity.com/security-audit/angle-protocol/). The audit reports can be found in the `audits/` folder of this repo. Contracts of the module have been audited at least by one of the two auditors.

All Angle Protocol related audits can be found in [this page](https://docs.angle.money/resources/audits) of our docs.

## Bug Bounty

At Angle, we consider the security of our systems a top priority. But even putting top priority status and maximum effort, there is still possibility that vulnerabilities exist.

We have therefore setup a bug bounty program with the help of Immunefi. The Angle Protocol bug bounty program is focused around our smart contracts with a primary interest in the prevention of:

- Thefts and freezing of principal of any amount
- Thefts and freezing of unclaimed yield of any amount
- Theft of governance funds
- Governance activity disruption

For more details, please refer to the [official page of the bounty on Immunefi](https://immunefi.com/bounty/angleprotocol/).

| Level    |                     |
| :------- | :------------------ |
| Critical | up to USD \$500,000 |
| High     | USD \$20,000        |
| Medium   | USD \$2,500         |

All bug reports must include a Proof of Concept demonstrating how the vulnerability can be exploited to be eligible for a reward. This may be a smart contract itself or a transaction.

## Usage

Note that this repo is not a repo on which the Angle Core Team develops. There is another repo, with all the tests and scripts, that is actively worked on.
