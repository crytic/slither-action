#!/usr/bin/env bash
set -e

# smoelius: `get` works for non-standard variable names like `INPUT_CORPUS-DIR`.
get() {
    env | sed -n "s/^$1=\(.*\)/\1/;T;p"
}

TARGET="$1"
SOLCVER="$2"
NODEVER="$3"
SARIFOUT="$4"
SLITHERVER="$5"
SLITHERARGS="$(get INPUT_SLITHER-ARGS)"
SLITHERCONF="$(get INPUT_SLITHER-CONFIG)"
IGNORECOMPILE="$(get INPUT_IGNORE-COMPILE)"

compatibility_link()
{
    HOST_GITHUB_WORKSPACE="$(get INPUT_INTERNAL-GITHUB-WORKSPACE | tr -d \")"
    if [[ -d "$GITHUB_WORKSPACE" ]]; then
        mkdir -p "$(dirname "$HOST_GITHUB_WORKSPACE")"
        ln -s "$GITHUB_WORKSPACE" "$HOST_GITHUB_WORKSPACE"
        echo "[-] Applied compatibility link: $HOST_GITHUB_WORKSPACE -> $GITHUB_WORKSPACE"
    fi
}

install_solc()
{
    if [[ -z "$SOLCVER" ]]; then
        echo "[-] SOLCVER was not set; guessing."

        if [[ -f "$TARGET" ]]; then
            SOLCVER="$(grep --no-filename '^pragma solidity' "$TARGET" | cut -d' ' -f3)"
        else
            pushd "$TARGET" >/dev/null
            SOLCVER="$(grep --no-filename '^pragma solidity' -r --include \*.sol --exclude-dir node_modules | \
                       cut -d' ' -f3 | sort | uniq -c | sort -n | tail -1 | tr -s ' ' | cut -d' ' -f3)"
            popd >/dev/null
        fi
        SOLCVER="$(echo "$SOLCVER" | sed 's/[^0-9\.]//g')"

        if [[ -z "$SOLCVER" ]]; then
        # Fallback to latest version if the above fails.
            SOLCVER="$(solc-select install | tail -1)"
        fi

        echo "[-] Guessed $SOLCVER."
    fi

    solc-select install "$SOLCVER"
    solc-select use "$SOLCVER"
}

install_node()
{
    if [[ -z "$NODEVER" ]]; then
        NODEVER="node"
        echo "[-] NODEVER was not set, using the latest version."
    fi

    wget -q -O nvm-install.sh https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.1/install.sh
    if [ ! "fabc489b39a5e9c999c7cab4d281cdbbcbad10ec2f8b9a7f7144ad701b6bfdc7  nvm-install.sh" = "$(sha256sum nvm-install.sh)" ]; then
        echo "NVM installer does not match expected checksum! exiting"
        exit 1
    fi
    bash nvm-install.sh
    rm nvm-install.sh

    # Avoid picking up `.nvmrc` from the repository
    pushd / >/dev/null
    . ~/.nvm/nvm.sh
    nvm install "$NODEVER"
    popd >/dev/null
}

install_foundry()
{
    if [[ -d "$TARGET" ]] && [[ -f "$TARGET/foundry.toml" ]]; then
        echo "[-] Foundry target detected, installing foundry nightly"

        wget -q -O foundryup https://raw.githubusercontent.com/foundry-rs/foundry/36a66c857ff148f6ed007cdcd3402077de3595cf/foundryup/foundryup
        if [ ! "c0c6711dc39deae65bebcc0320fec1265930895a527e18daa643a708218c07ae  foundryup" = "$(sha256sum foundryup)" ]; then
            echo "Foundry installer does not match expected checksum! exiting"
            exit 1
        fi

        export FOUNDRY_DIR="/opt/foundry"
        export PATH="$FOUNDRY_DIR/bin:$PATH"
        mkdir -p "$FOUNDRY_DIR/bin" "$FOUNDRY_DIR/share/man/man1"
        bash foundryup
        rm foundryup
    fi
}

install_slither()
{
    SLITHERPKG="slither-analyzer"
    if [[ -n "$SLITHERVER" ]]; then
        SLITHERPKG="slither-analyzer==$SLITHERVER"
        echo "[-] SLITHERVER provided, installing $SLITHERPKG"
    fi

    python3 -m venv /opt/slither
    export PATH="/opt/slither/bin:$PATH"
    pip3 install wheel
    pip3 install "$SLITHERPKG"
}

install_deps()
{
    if [[ -d "$TARGET" ]]; then
        pushd "$TARGET" >/dev/null

        # JS dependencies
        if [[ -f package-lock.json ]]; then
            echo "[-] Installing dependencies from package-lock.json"
            npm ci
        elif [[ -f yarn.lock ]]; then
            echo "[-] Installing dependencies from yarn.lock"
            npm install -g yarn
            yarn install --frozen-lockfile
        elif [[ -f pnpm-lock.yaml ]]; then
            echo "[-] Installing dependencies from pnpm-lock-yaml"
            npm install -g pnpm
            pnpm install
        elif [[ -f package.json ]]; then
            echo "[-] Did not detect a package-lock.json or yarn.lock in $TARGET, consider locking your dependencies!"
            echo "[-] Proceeding with 'npm i' to install dependencies"
            npm i
        else
            echo "[-] Did not find a package.json, proceeding without installing JS dependencies."
        fi

        # Python dependencies
        if [[ -f requirements.txt ]]; then
            echo "[-] Installing dependencies from requirements.txt in a venv"
            python3 -m venv /opt/dependencies
            OLDPATH="$PATH"
            export PATH="/opt/dependencies/bin:$PATH"
            pip3 install wheel
            pip3 install -r requirements.txt
            # Add to the end of PATH, to give preference to the action's tools
            export PATH="$OLDPATH:/opt/dependencies/bin"
        else
            echo "[-] Did not find a requirements.txt, proceeding without installing Python dependencies."
        fi

        # Foundry dependencies
        if [[ -f foundry.toml ]]; then
            echo "[-] Installing dependencies from foundry.toml"
            forge install
        else
            echo "[-] Did not find a foundry.toml, proceeding without installing Foundry dependencies."
        fi

        popd >/dev/null
    fi
}

install_slither

IGNORECOMPILEFLAG=
if [[ -z "$IGNORECOMPILE" || $IGNORECOMPILE =~ ^[Ff]alse$ ]]; then
    install_solc
    install_node
    install_foundry
    install_deps
else
    compatibility_link
    IGNORECOMPILEFLAG="--ignore-compile"
fi

SARIFFLAG=
if [[ -n "$SARIFOUT" ]]; then
    echo "[-] SARIF output enabled, writing to $SARIFOUT."
    echo "::set-output name=sarif::$SARIFOUT"
    SARIFFLAG="--sarif=$SARIFOUT"
fi

CONFIGFLAG=
if [[ -n "$SLITHERCONF" ]]; then
    echo "[-] Slither config provided: $SLITHERCONF"
    CONFIGFLAG="--config-file=$SLITHERCONF"
fi

if [[ -z "$SLITHERARGS" ]]; then
    slither "$TARGET" $SARIFFLAG $IGNORECOMPILEFLAG $CONFIGFLAG
else
    echo "[-] SLITHERARGS provided. Running slither with extra arguments"
    printf "%s\n" "$SLITHERARGS" | xargs slither "$TARGET" $SARIFFLAG $IGNORECOMPILEFLAG $CONFIGFLAG
fi
