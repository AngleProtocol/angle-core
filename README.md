# Angle Protocol

Core Module of the Angle Protocol.

## Documentation

Angle is a decentralized stablecoin protocol, designed to be both over-collateralized and capital-efficient. For more information about the protocol, you can refer to [Angle Documentation](https://docs.angle.money).

The protocol is made of different modules, each with their own set of smart contracts. This repo contains the Core module smart contracts.

If you would like to know how the module works under the hood and how these smart contracts work together, you can also check [Angle Developers Doc](https://developers.angle.money/core-module-contracts/protocol-and-architecture-overview).

Whitepaper for the module can be found [here](https://docs.angle.money/overview/whitepapers).

## Module Architecture

![Angle Protocol Smart Contract Architecture](./AngleArchitectureSchema.png)

## Audits

Angle Core module smart contracts have been audited by Sigma Prime and [Chainsecurity](https://chainsecurity.com/security-audit/angle-protocol/). The audit reports can be found in the `audits/` folder of this repo. Every contract of the protocol has been audited at least by one of the two auditors.

All Angle Protocol related audits can be found in [this page](https://docs.angle.money/resources/audits) of our docs.

## Some Remarks on the Code

Some smart contracts use error messages. These error messages are sometimes encoded in numbers rather than as custom errors like done most of the time. The conversion from numbers to error messages can be found in `errorMessages.json`.

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

## Further Information

For a broader overview of the protocol and its different modules, you can also check [this overview page](https://developers.angle.money) of our developers documentation.

Other Angle-related smart contracts can be found in the following repositories:

- [Angle Borrowing module contracts](https://github.com/AngleProtocol/angle-borrow)

Otherwise, for more info about the protocol, check out [this portal](https://linktr.ee/angleprotocol) of resources.
