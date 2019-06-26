#! /bin/bash

set -e
set -a

E2E_DIRECTORY=$(realpath "$(dirname "${BASH_SOURCE[0]}")")
VALIDATOR_SET_DEPLOY_DIRECTORY=$(realpath "$E2E_DIRECTORY/../../validator-set-deploy")
BRIDGE_DEPLOY_DIRECTORY=$(realpath "$E2E_DIRECTORY/../../bridge-deploy")
CONTRACT_DIRECTORY=$(realpath "$E2E_DIRECTORY/../../contracts/contracts")
VALIDATOR_SET_CSV_FILE=$(realpath "$E2E_DIRECTORY/validator-list")
ENVIRONMENT_VARIABLES_FILE="$E2E_DIRECTORY/env_override"
VIRTUAL_ENV="$E2E_DIRECTORY/venv"
DOCKER_COMPOSE_COMMAND="docker-compose -f ../docker-compose.yml -f docker-compose-override.yml"
VALIDATOR_ADDRESS=0x46ae357bA2f459Cb04697837397eC90b47e48727 # Must be a checksum address
VALIDATOR_ADDRESS_PRIVATE_KEY=0x0000000000000000000000000000000000000000000000000000000000000001
PREMINTED_COINS_AMOUNT=1
BLOCK_REWARD_CONTRACT_TRANSITION_BLOCK=70
NODE_SIDE_RPC_ADDRESS="http://127.0.0.1:8545"
NODE_MAIN_RPC_ADDRESS="http://127.0.0.1:8544"

OPTIND=1
ARGUMENT_DOCKER_BUILD=0
ARGUMENT_DOCKER_PULL=0
ARGUMENT_SILENT=0

while getopts "pbs" opt; do
  case "$opt" in
  b)
    ARGUMENT_DOCKER_BUILD=1
    ;;
  p)
    ARGUMENT_DOCKER_PULL=1
    ;;
  s)
    ARGUMENT_SILENT=1
    ;;
  *) ;;

  esac
done

# Optimized version of 'set -x'
function preexec() {
  if [[ $BASH_COMMAND != echo* ]] && [[ $ARGUMENT_SILENT -eq 0 ]]; then echo >&2 "+ $BASH_COMMAND"; fi
}

set -o functrace # run DEBUG trap in subshells
trap preexec DEBUG

function cleanup() {
  cd "$E2E_DIRECTORY"
  $DOCKER_COMPOSE_COMMAND down -v
}

trap "cleanup" EXIT
trap "exit 1" SIGINT SIGTERM

# Execute a command and parse a possible hex address from the output.
# The address is expected to start with 0x.
# Only the first address will be returned.
#
# Arguments:
#   $1 - command to execute
#
function executeAndParseHexAddress() {
  output=$($1)
  hexAddressWithPostfix=${output##*0x}
  echo "0x${hexAddressWithPostfix%% *}"
}

echo "===> Shutdown possible old services"
$DOCKER_COMPOSE_COMMAND down -v

if [[ $ARGUMENT_DOCKER_BUILD == 1 ]]; then
  echo "===> Build images for services"
  $DOCKER_COMPOSE_COMMAND build
fi

if [[ $ARGUMENT_DOCKER_PULL == 1 ]]; then
  echo "===> Pull images for services"
  $DOCKER_COMPOSE_COMMAND pull
fi

echo "===> Prepare deploy tools"
[[ ! -d "$VIRTUAL_ENV" ]] && python3 -m venv "$VIRTUAL_ENV"
source "$VIRTUAL_ENV/bin/activate"
# TOOD: remove in future:
pip install py-geth==2.1.0 'eth-tester[py-evm]==0.1.0-beta.39' pytest-ethereum==0.1.3a6 pysha3==1.0.2

echo "===> Prepare deployment tools"
(cd "$VALIDATOR_SET_DEPLOY_DIRECTORY" && make install)
(cd "$BRIDGE_DEPLOY_DIRECTORY" && make install)

echo "===> Start main and side chain node services"
$DOCKER_COMPOSE_COMMAND up --no-start
$DOCKER_COMPOSE_COMMAND up -d node_side node_main

echo "===> Wait 10 seconds to let the chains start up"
sleep 10

echo "===> Deploy validator set contracts"
validator-set-deploy deploy --jsonrpc "$NODE_SIDE_RPC_ADDRESS" --validators "$VALIDATOR_SET_CSV_FILE"
validator_set_proxy_contract_address=$(executeAndParseHexAddress "validator-set-deploy deploy-proxy \
  --jsonrpc $NODE_SIDE_RPC_ADDRESS")

echo "ValidatorSetProxy contract address: $validator_set_proxy_contract_address"

echo "===> Deploy block reward contract"

block_reward_contract_address=$(executeAndParseHexAddress \
  "bridge-deploy deploy-reward --jsonrpc $NODE_SIDE_RPC_ADDRESS")

echo "BlockReward contract address: $block_reward_contract_address"

echo "===> Deploy bridge contracts"

foreign_bridge_contract_address=$(executeAndParseHexAddress "bridge-deploy deploy-foreign \
  --jsonrpc $NODE_MAIN_RPC_ADDRESS")

echo "ForeignBridge contract address: $foreign_bridge_contract_address"

home_bridge_contract_address=$(executeAndParseHexAddress \
  "bridge-deploy deploy-home --jsonrpc $NODE_SIDE_RPC_ADDRESS \
  --validator-set-address $validator_set_proxy_contract_address
  --block-reward-address $block_reward_contract_address
  --required-block-confirmations 1
  --owner-address $VALIDATOR_ADDRESS
  --gas 7000000
  --gas-price 10")

echo "HomeBridge contract address: $home_bridge_contract_address"

echo "===> Deploy token contract"
token_contract_address=$(executeAndParseHexAddress "deploy-tools deploy \
  --jsonrpc $NODE_MAIN_RPC_ADDRESS --contracts-dir $CONTRACT_DIRECTORY \
  TrustlinesNetworkToken TrustlinesNetworkToken TNC 18 $VALIDATOR_ADDRESS $PREMINTED_COINS_AMOUNT")

echo "Token contract address: $token_contract_address"

echo "===> Set bridge environment variables"
sed -i "s/\(FOREIGN_BRIDGE_ADDRESS=\).*/\1$foreign_bridge_contract_address/" "$ENVIRONMENT_VARIABLES_FILE"
sed -i "s/\(HOME_BRIDGE_ADDRESS=\).*/\1$home_bridge_contract_address/" "$ENVIRONMENT_VARIABLES_FILE"
sed -i "s/\(ERC20_TOKEN_ADDRESS=\).*/\1$token_contract_address/" "$ENVIRONMENT_VARIABLES_FILE"

printf "===> Wait until block reward contract transition"

blockNumber=0

while [[ $blockNumber -lt $BLOCK_REWARD_CONTRACT_TRANSITION_BLOCK ]]; do
  printf .
  response=$(curl --silent --data \
    '{"method":"eth_blockNumber","params":[],"id":1,"jsonrpc":"2.0"}' \
    -H "Content-Type: application/json" -X POST $NODE_SIDE_RPC_ADDRESS)
  blockNumberHex=$(echo "$response" | awk -F '0x' '{print $2}' | awk -F '"' '{print $1}')
  blockNumber=$((16#$blockNumberHex))
  sleep 1
done

printf '\n'

echo "===> Start bridge services"

$DOCKER_COMPOSE_COMMAND up -d \
  rabbit redis bridge_request bridge_collected bridge_affirmation bridge_senderhome bridge_senderforeign

printf "===> Wait until message broker is up"

rabbit_log_length=0

# Mind the "Attaching to..." line at the beginning.
while [[ $rabbit_log_length -lt 2 ]]; do
  printf .
  rabbit_log=$($DOCKER_COMPOSE_COMMAND logs rabbit)
  rabbit_log_length=$(wc -l <<< "$rabbit_log")
  sleep 5
done

printf '\n'

# echo "===> Test if all service have started and are running"
# RABBIT_RUNNING=$(docker inspect -f '{{.State.Running}}' bridge_rabbit_1)
# REDIS_RUNNING=$(docker inspect -f '{{.State.Running}}' bridge_redis_1)
# REQUEST_RUNNING=$(docker inspect -f '{{.State.Running}}' bridge_bridge_request_1)
# AFFIRMATION_RUNNING=$(docker inspect -f '{{.State.Running}}' bridge_bridge_affirmation_1)
# SENDER_FOREIGN_RUNNING=$(docker inspect -f '{{.State.Running}}' bridge_bridge_senderforeign)
# SENDER_HOME_RUNNING=$(docker inspect -f '{{.State.Running}}' bridge_bridge_senderhome_1)
# COLLECTED_RUNNING=$(docker inspect -f '{{.State.Running}}' bridge_bridge_collected_1)
# 
# if [ "${RABBIT_RUNNING}" != "true" ] ||
  # [ "${REDIS_RUNNING}" != "true" ] ||
  # [ "${REQUEST_RUNNING}" != "true" ] ||
  # [ "${AFFIRMATION_RUNNING}" != "true" ] ||
  # [ "${SENDER_FOREIGN_RUNNING}" != "true" ] ||
  # [ "${SENDER_HOME_RUNNING}" != "true" ] ||
  # [ "${COLLECTED_RUNNING}" != "true" ]; then
  # exit 1
# fi

echo "===> Test a bridge transfer from foreign to home chain"

read
sleep 100
$DOCKER_COMPOSE_COMMAND logs rabbit > rabbit.log
$DOCKER_COMPOSE_COMMAND logs redis > redis.log
$DOCKER_COMPOSE_COMMAND logs bridge_collected > bridge_collected.log
$DOCKER_COMPOSE_COMMAND logs bridge_affirmation > bridge_affirmation.log
$DOCKER_COMPOSE_COMMAND logs bridge_senderhome > bridge_senderhome.log
$DOCKER_COMPOSE_COMMAND logs bridge_senderforeign > bridge_senderforeign.log
# TODO: wait contract-deploy-tools

echo "===> Shutting down"
$DOCKER_COMPOSE_COMMAND down
