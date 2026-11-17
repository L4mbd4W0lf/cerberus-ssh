# Security policy

CerberusSSH holds SSH credentials, private keys and session recordings, so security problems are taken seriously.

## Reporting a problem

Please report it privately, not in public: on this repository's **Security** tab, choose **Report a vulnerability**. Only the maintainer can see the report.

Include what you can of:

- the version (CerberusSSH ▸ About CerberusSSH) and the macOS version;
- what the problem is and what an attacker could do with it;
- the steps to reproduce it.

Do not include real passwords, private keys, host names or session logs. Use made-up ones.

## Supported versions

CerberusSSH is in pre-release. Fixes go into the next release only; older versions are not patched.

## Scope

This repository is the interface. The vault, the SSH engine and the terminal are in a separate, private package, but report problems in them here too: the report reaches the same person.

Some things are deliberate, not vulnerabilities:

- SSH agent forwarding is not supported and will not be added.
- A changed host key blocks the connection; there is no way to accept it silently.
- A forgotten backup passphrase cannot be recovered; there is no escrow.
