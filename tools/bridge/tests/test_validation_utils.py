import pytest

from bridge.contract_abis import HOME_BRIDGE_ABI
from bridge.validation_utils import validate_contract, validate_confirmation_permissions


FAKE_ERC20_TOKEN_ABI = [
    {"anonymous": False, "inputs": [], "name": "FakeEvent", "type": "event"}
]


@pytest.fixture
def internal_home_bridge_contract(w3_home, home_bridge_contract):
    """Home bridge contract as it would be represented within the client.

    Using the home bridge instead of the token, because the to check internal
    ABI is more complex and contain not only descriptions of type 'event'.
    """
    return w3_home.eth.contract(
        address=home_bridge_contract.address, abi=HOME_BRIDGE_ABI
    )


@pytest.fixture
def home_bridge_contract_with_not_deployed_proxy_contract(
    deploy_contract_on_chain, w3_home
):
    """Home bridge contract with not deployed proxy contract

    The referenced validator proxy address does not point to any contract.
    """

    return deploy_contract_on_chain(
        w3_home,
        "TestHomeBridge",
        constructor_args=("0x0000000000000000000000000000000000000001", 50),
    )


@pytest.fixture
def home_bridge_contract_with_not_matching_proxy_contract_abi(
    deploy_contract_on_chain, w3_home, foreign_bridge_contract
):
    """Home bridge contract which proxy address do not match the ABI

    The referenced validator proxy address does not implemented the expected ABI
    """

    return deploy_contract_on_chain(
        w3_home,
        "TestHomeBridge",
        constructor_args=(foreign_bridge_contract.address, 50),
    )


def test_validate_contract_successfully(internal_home_bridge_contract):
    validate_contract(internal_home_bridge_contract)


def test_validate_contract_undeployed_address(internal_home_bridge_contract):
    internal_home_bridge_contract.address = "0x0000000000000000000000000000000000000000"

    with pytest.raises(ValueError):
        validate_contract(internal_home_bridge_contract)


def test_validate_contract_not_matching_abi(internal_home_bridge_contract):
    internal_home_bridge_contract.abi = FAKE_ERC20_TOKEN_ABI

    with pytest.raises(ValueError):
        validate_contract(internal_home_bridge_contract)


def test_validate_confirmation_permissions_successfully(
    home_bridge_contract, validator_address
):
    validate_confirmation_permissions(home_bridge_contract, validator_address)


def test_validate_confirmation_permissions_not_permissioned(
    home_bridge_contract, non_validator_address
):
    with pytest.raises(ValueError):
        validate_confirmation_permissions(home_bridge_contract, non_validator_address)


def test_validate_confirmation_permissions_not_deployed_proxy_contract(
    home_bridge_contract_with_not_deployed_proxy_contract, validator_address
):
    with pytest.raises(RuntimeError):
        validate_confirmation_permissions(
            home_bridge_contract_with_not_deployed_proxy_contract, validator_address
        )


def test_validate_confirmation_permissions_not_matching_proxy_contract_abi(
    home_bridge_contract_with_not_matching_proxy_contract_abi, validator_address
):
    with pytest.raises(RuntimeError):
        validate_confirmation_permissions(
            home_bridge_contract_with_not_matching_proxy_contract_abi, validator_address
        )