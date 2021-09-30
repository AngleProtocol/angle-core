# Angle Protocol

Core smart contracts of the Angle Protocol

## Documentation

It is possible to find documentation to understand the Angle Protocol on https://docs.angle.money.
Developers documentation to understand the smart contract architecture can be found here: https://angle.gitbook.io/developers/.

## Some Remarks on the Code

Our developers documentation is not completely up-to date with the changes we have recently made. The source of truth when it comes to the protocol is what is in the contracts. We will try to update it as soon as possible.

The interfaces we define in the smart contracts are for our own usage. We will work on a SDK where we define the correct interfaces to integrate with our contracts.

There are some risks and vulnerabilities in our code we are aware of. In the code, in each situation where a risk arises, we try to mention it in the comments. A non-exhaustive list of such risks includes:

- Front-running risks for keepers interacting with our contracts: there are some functions which gives rewards to the address calling it and it is easy to get front-ran by miners when calling these functions
- Reentrancy risks: when running Slither, some reentrancy risks arise. In most situations, these happen for riskless calls to trusted smart contracts of the protocol
- Dependence on a careful governance for some changes at the protocol level. Extreme care must be taken when deploying and when updating roles. For instance when adding a new governor, as to propagate the changes across all contracts of the protocol, several transactions may be needed

The smart contracts use error messages. To optimize for gas, these error messages are encoded in numbers rather than in plain text. The conversion from numbers to error messages can be found in `errorMessages.json`.

## Usage

To install all the packages needed to run the tests, run:
`yarn`

Create a  `.env` file with the following variables:
ETH_NODE_URI_KOVAN, MNEMONIC_KOVAN, MNEMONIC_LOCAL

## Responsible Disclosure

At Angle, we consider the security of our systems a top priority. But even putting top priority status and maximum effort, there is still possibility that vulnerabilities can exist.

In case you discover a vulnerability, we would like to know about it immediately so we can take steps to address it as quickly as possible.

If you discover a vulnerability, please do the following:

    E-mail your findings to contact@angle.money;

    Do not take advantage of the vulnerability or problem you have discovered;

    Do not reveal the problem to others until it has been resolved;

    Do not use attacks on physical security, social engineering, distributed denial of service, spam or applications of third parties; and

    Do provide sufficient information to reproduce the problem, so we will be able to resolve it as quickly as possible. Complex vulnerabilities may require further explanation so we might ask you for additional information.

We will promise the following:

    We will respond to your report within 3 business days with our evaluation of the report and an expected resolution date;

    If you have followed the instructions above, we will not take any legal action against you in regard to the report;

    We will handle your report with strict confidentiality, and not pass on your personal details to third parties without your permission;

    If you so wish we will keep you informed of the progress towards resolving the problem;

    In the public information concerning the problem reported, we will give your name as the discoverer of the problem (unless you desire otherwise); and

    As a token of our gratitude for your assistance, we offer a reward for every report of a security problem that was not yet known to us. The amount of the reward will be determined based on the severity of the leak, the quality of the report and any additional assistance you provide.
