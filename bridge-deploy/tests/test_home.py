from bridge_deploy.home import (
    deploy_home_block_reward_contract,
    deploy_home_bridge_validators_contract,
    deploy_home_bridge_contract,
    initialize_home_bridge_contract,
)


DUMMY_PRIVATE_KEY = (
    "0fe15822e1e481af027ae3b23a2a053401c76881e66cdb26dc0265d97c766c33"
)  # 0x6d705788A2B4B7439e7311700065Bdf0881Fc0Bc


def test_deploy_home_block_reward_contract(web3):
    reward_contract = deploy_home_block_reward_contract(web3=web3)

    assert reward_contract.functions.bridgesAllowed().call() == [
        "0x0000000000000000000000000000000000000000"
    ]


def test_deploy_home_bridge_validators_contract(web3):

    home_bridge_validators_contract = deploy_home_bridge_validators_contract(
        web3=web3,
        validator_proxy="0x0000000000000000000000000000000000000000",
        required_signatures_divisor=1,
        required_signatures_multiplier=1,
    )

    assert (
        home_bridge_validators_contract.functions.owner().call()
        == "0x0000000000000000000000000000000000000000"
    )


def test_deploy_home_bridge_contract(web3):

    deployment_result = deploy_home_bridge_contract(web3=web3)
    home_bridge_contract = deployment_result.home_bridge

    assert home_bridge_contract.functions.getBridgeInterfacesVersion().call() == [
        2,
        2,
        0,
    ]


def test_initialize_home_bridge_contract(
    home_bridge_contract,
    home_bridge_proxy_contract,
    home_bridge_validators_contract,
    block_reward_contract,
    web3,
    chain,
):
    initialize_home_bridge_contract(
        web3=web3,
        # Inject the owner address, as we don't know the private key
        owner_address=chain.get_accounts()[0],
        home_bridge_contract=home_bridge_contract,
        home_bridge_proxy_contract=home_bridge_proxy_contract,
        validator_contract_address=home_bridge_validators_contract.address,
        home_daily_limit=30000000000000000000000000,
        home_max_per_tx=1500000000000000000000000,
        home_min_per_tx=500000000000000000,
        home_gas_price=1000000000,
        required_block_confirmations=1,
        block_reward_address=block_reward_contract.address,
    )

    assert home_bridge_contract.functions.isInitialized().call()