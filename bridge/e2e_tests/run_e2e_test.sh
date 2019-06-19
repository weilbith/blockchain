#! /bin/bash

set -e
set -a

E2E_DIRECTORY=$(realpath "$(dirname "${BASH_SOURCE[0]}")")
VALIDATOR_SET_DEPLOY_DIRECTORY=$(realpath "$E2E_DIRECTORY/../../validator-set-deploy")
BRIDGE_DEPLOY_DIRECTORY=$(realpath "$E2E_DIRECTORY/../../bridge-deploy")
VALIDATOR_SET_CSV_FILE=$(realpath "$E2E_DIRECTORY/validator-list")
DOCKER_COMPOSE_COMMAND="docker-compose -f ../docker-compose.yml -f docker-compose-override.yml"
VIRTUAL_ENV="$E2E_DIRECTORY/venv"
VALIDATOR_ADDRESS=0x7e5f4552091a69125d5dfcb7b8c2659029395bdf
VALIDATOR_ADDRESS_PRIVATE_KEY=0x0000000000000000000000000000000000000000000000000000000000000001

OPTIND=1
ARGUMENT_DOCKER_BUILD=0
ARGUMENT_DOCKER_PULL=0

while getopts "pb" opt; do
  case "$opt" in
  b)
    ARGUMENT_DOCKER_BUILD=1
    ;;
  p)
    ARGUMENT_DOCKER_PULL=1
    ;;
  *) ;;

  esac
done

# Optimized version of 'set -x'
function preexec() {
  if [[ $BASH_COMMAND != echo* ]]; then echo >&2 "+ $BASH_COMMAND"; fi
}

set -o functrace # run DEBUG trap in subshells
trap preexec DEBUG

function cleanup() {
  cd "$E2E_DIRECTORY"
  $DOCKER_COMPOSE_COMMAND logs node_side >node_side.log
  $DOCKER_COMPOSE_COMMAND down -v
}

trap "cleanup" EXIT
trap "exit 1" SIGINT SIGTERM

echo "====> Shutdown possible old services"
$DOCKER_COMPOSE_COMMAND down -v

if [[ $ARGUMENT_DOCKER_BUILD == 1 ]]; then
  echo "====> Build images for services"
  $DOCKER_COMPOSE_COMMAND build
fi

if [[ $ARGUMENT_DOCKER_PULL == 1 ]]; then
  echo "====> Pull images for services"
  $DOCKER_COMPOSE_COMMAND pull
fi

echo "====> Start main and side chain node services"
$DOCKER_COMPOSE_COMMAND up --no-start
$DOCKER_COMPOSE_COMMAND up -d node_side node_main

side_node_ip_address=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' node_side)
main_node_ip_address=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' node_main)

echo "===> Prepare deploy tools"
[[ ! -d "$VIRTUAL_ENV" ]] && python3 -m venv "$VIRTUAL_ENV"
source "$VIRTUAL_ENV/bin/activate"
# TOOD: remove in future:
pip install py-geth==2.1.0 'eth-tester[py-evm]==0.1.0-beta.39' pytest-ethereum==0.1.3a6 pysha3==1.0.2

echo "===> Prepare deployment tools"
(cd "$VALIDATOR_SET_DEPLOY_DIRECTORY" && make install)
(cd "$BRIDGE_DEPLOY_DIRECTORY" && make install)

echo "===> Deploy validator set contracts"
# TODO: parse validator set contract address
validator-set-deploy deploy --jsonrpc "http://$side_node_ip_address:8545" --validators "$VALIDATOR_SET_CSV_FILE"
echo "done"
validator-set-deploy deploy-proxy --jsonrpc "http://$side_node_ip_address:8545"

echo "===> Deploy bridge contracts"
bridge-deploy deploy-foreign --jsonrpc "http://$main_node_ip_address:8544"
bridge-deploy deploy-home --jsonrpc "http://$side_node_ip_address:8545" # TODO: pass validator set contract

echo "===> Set bridge environment variables"

# TODO: overwrite parts of .env_overwrite

echo "===> Start bridge services"

$DOCKER_COMPOSE_COMMAND up -d \
  bridge_request bridge_collected bridge_affirmation bridge_senderhome bridge_senderforeign

echo "====> Test if all service have started and are running"
RABBIT_RUNNING=$(docker inspect -f '{{.State.Running}}' bridge_rabbit_1)
REDIS_RUNNING=$(docker inspect -f '{{.State.Running}}' bridge_redis_1)
REQUEST_RUNNING=$(docker inspect -f '{{.State.Running}}' bridge_bridge_request_1)
AFFIRMATION_RUNNING=$(docker inspect -f '{{.State.Running}}' bridge_bridge_affirmation_1)
SENDER_FOREIGN_RUNNING=$(docker inspect -f '{{.State.Running}}' bridge_bridge_senderforeign)
SENDER_HOME_RUNNING=$(docker inspect -f '{{.State.Running}}' bridge_bridge_senderhome_1)
COLLECTED_RUNNING=$(docker inspect -f '{{.State.Running}}' bridge_bridge_collected_1)

if [ "${RABBIT_RUNNING}" != "true" ] ||
  [ "${REDIS_RUNNING}" != "true" ] ||
  [ "${REQUEST_RUNNING}" != "true" ] ||
  [ "${AFFIRMATION_RUNNING}" != "true" ] ||
  [ "${SENDER_FOREIGN_RUNNING}" != "true" ] ||
  [ "${SENDER_HOME_RUNNING}" != "true" ] ||
  [ "${COLLECTED_RUNNING}" != "true" ]; then
  exit 1
fi

echo "===> Test a bridge transfer from foreign to home chain"

# TODO

echo "====> Shutting down"
$DOCKER_COMPOSE_COMMAND down
