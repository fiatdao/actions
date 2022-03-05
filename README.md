# <h1 align="center"> FIAT Actions </h1>

**Repository containing smart contracts for easier interaction with the FIAT protocol**

WARNING: The functions in the actions contracts are meant to be used as a library for the [Proxy](https://github.com/fiatdao/proxy/tree/fiatdao-dev).

## Requirements
If you do not have DappTools already installed, you'll need to run the
commands below

### Install Nix

```sh
# User must be in sudoers
curl -L https://nixos.org/nix/install | sh

# Run this or login again to use Nix
. "$HOME/.nix-profile/etc/profile.d/nix.sh"
```

### Install DappTools
```sh
nix-env -f https://github.com/dapphub/dapptools/archive/f9ff55e11100b14cd595d8c15789d8407124b349.tar.gz -iA dapp hevm seth ethsign
```

### Set .env
Copy and update contents from `.env.example` to `.env`

## Building and testing

```sh
git clone git@github.com:fiatdao/actions.git
cd actions
make # This installs the project's dependencies.
make test
```
