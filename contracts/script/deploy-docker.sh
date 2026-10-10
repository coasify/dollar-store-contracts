#!/usr/bin/env bash
set -eo pipefail

# Helper to deploy and verify contracts using a standardized Linux Docker container.
# This prevents compilation differences (Yul/via_ir non-determinism) between macOS and Etherscan's Linux servers.

if [ -z "$1" ]; then
    echo "Usage: $0 <env-file> [extra-forge-args]"
    echo "Example: $0 .env.sepolia --broadcast --verify"
    exit 1
fi

ENV_FILE="$1"
shift

if [ ! -f "$ENV_FILE" ]; then
    echo "Error: Environment file '$ENV_FILE' not found."
    exit 1
fi

CONTRACTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLEAN_ENV_FILE="${ENV_FILE}.clean"
# The cleaned file holds the deployment secrets; remove it on every exit path.
trap 'rm -f "$CLEAN_ENV_FILE"' EXIT

# Strip comments and inline comments from the environment file for Docker compatibility
echo "Cleaning environment file for Docker..."
grep -v '^#' "$ENV_FILE" | sed -E 's/[[:space:]]*#.*$//g' | grep -v '^[[:space:]]*$' > "$CLEAN_ENV_FILE"

# Derive the network alias from the env file NAME, not from which URLs are populated.
# (.env.sepolia also carries MAINNET_RPC_URL for fork tests, so sniffing the URLs could pick the
# wrong chain and deploy to mainnet by accident.)
case "$ENV_FILE" in
    *mainnet*) RPC_ALIAS="mainnet" ;;
    *sepolia*) RPC_ALIAS="sepolia" ;;
    *)
        echo "Error: cannot infer the network from '$ENV_FILE' (expected a name containing 'sepolia' or 'mainnet')."
        exit 1
        ;;
esac

# Dependencies are git submodules pinned to exact commits. Refuse to build from anything else.
if ! LIB_STATUS="$(git -C "$CONTRACTS_DIR" submodule status lib)"; then
    echo "Error: could not read the submodule status of contracts/lib."
    exit 1
fi
if grep -q '^[^ ]' <<<"$LIB_STATUS"; then
    echo "Error: contracts/lib does not match the pinned submodule commits. Run: git submodule update --init"
    exit 1
fi

echo "Detected RPC alias: $RPC_ALIAS"
echo "Running compilation and deployment inside Docker container..."

docker run --rm \
  --env-file "$CLEAN_ENV_FILE" \
  -v "$CONTRACTS_DIR":/app \
  -w /app \
  ghcr.io/foundry-rs/foundry:v1.8.3 \
  "forge script script/DeployGovernance.s.sol:DeployGovernance --rpc-url $RPC_ALIAS $*"

echo "Deployment process completed."
