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

        popd >/dev/null
    fi
}

install_slither

IGNORECOMPILEFLAG=
if [[ -z "$IGNORECOMPILE" || $IGNORECOMPILE =~ ^[Ff]alse$ ]]; then
    install_solc
    install_node
    install_deps
else
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

crytic-compile "$TARGET" $IGNORECOMPILEFLAG

if [[ -z "$SLITHERARGS" ]]; then
    slither "$TARGET" $SARIFFLAG $IGNORECOMPILEFLAG $CONFIGFLAG
else
    echo "[-] SLITHERARGS provided. Running slither with extra arguments"
    printf "%s\n" "$SLITHERARGS" | xargs slither "$TARGET" $SARIFFLAG $IGNORECOMPILEFLAG $CONFIGFLAG
fi
