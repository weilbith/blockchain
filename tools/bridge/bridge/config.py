from typing import Any, Dict

import toml
import os

from eth_utils import (
    is_checksum_address,
    to_canonical_address,
    is_hex,
    is_0x_prefixed,
    decode_hex,
    big_endian_to_int,
)
from eth_utils.toolz import merge

from eth_keys.constants import SECPK1_N

from dotenv import load_dotenv

load_dotenv()


def validate_rpc_url(url: Any) -> str:
    if not isinstance(url, str):
        raise ValueError(f"{url} is not a valid RPC url")
    return url


def validate_positive_integer(number: Any) -> int:
    if not isinstance(number, int):
        raise ValueError(f"{number} is not an integer")
    if number <= 0:
        raise ValueError(f"{number} must be positive")
    return int(number)


def validate_positive_float(number: Any) -> float:
    if not isinstance(number, (int, float)):
        raise ValueError(f"{number} is neither integer nor float")
    if number <= 0:
        raise ValueError(f"{number} must be positive")
    return float(number)


def validate_checksum_address(address: Any) -> bytes:
    if not is_checksum_address(address):
        raise ValueError(f"{address} is not a valid Ethereum checksum address")
    return to_canonical_address(address)


def validate_private_key(private_key: Any) -> bytes:
    if not isinstance(private_key, str):
        raise ValueError(f"Private key must be a string, got {private_key}")
    if not is_hex(private_key):
        raise ValueError(f"Private key must be hex encoded, got {private_key}")
    if not is_0x_prefixed(private_key):
        raise ValueError(f"Private key must have a `0x` prefix, got {private_key}")
    private_key_bytes = decode_hex(private_key)
    if len(private_key_bytes) != 32:
        raise ValueError(f"Private key must represent 32 bytes, got {private_key}")
    private_key_int = big_endian_to_int(private_key_bytes)
    if not 0 < private_key_int < SECPK1_N:
        raise ValueError(f"Private key outside of allowed range: {private_key}")

    return private_key_bytes


REQUIRED_CONFIG_ENTRIES = [
    "home_rpc_url",
    "foreign_rpc_url",
    "token_contract_address",
    "home_bridge_contract_address",
    "foreign_bridge_contract_address",
    "validator_private_key",
]

OPTIONAL_CONFIG_ENTRIES_WITH_DEFAULTS: Dict[str, Any] = {
    "home_chain_max_reorg_depth": 1,
    "foreign_chain_max_reorg_depth": 10,
    "transfer_event_poll_interval": 5,
}

CONFIG_ENTRY_VALIDATORS = {
    "home_rpc_url": validate_rpc_url,
    "foreign_rpc_url": validate_rpc_url,
    "token_contract_address": validate_checksum_address,
    "home_bridge_contract_address": validate_checksum_address,
    "foreign_bridge_contract_address": validate_checksum_address,
    "home_chain_max_reorg_depth": validate_positive_integer,
    "foreign_chain_max_reorg_depth": validate_positive_integer,
    "transfer_event_poll_interval": validate_positive_float,
    "validator_private_key": validate_private_key,
}

assert all(key in CONFIG_ENTRY_VALIDATORS for key in REQUIRED_CONFIG_ENTRIES)
assert all(
    key in CONFIG_ENTRY_VALIDATORS for key in OPTIONAL_CONFIG_ENTRIES_WITH_DEFAULTS
)


def load_config_from_environment():
    result = {}
    keys = set(
        REQUIRED_CONFIG_ENTRIES
        + list(OPTIONAL_CONFIG_ENTRIES_WITH_DEFAULTS.keys())
        + list(CONFIG_ENTRY_VALIDATORS.keys())
    )
    for key in keys:
        if os.environ.get(key.upper()):
            result[key] = os.environ.get(key.upper())

    return result


def load_config(path: str) -> Dict[str, Any]:
    if path is None:
        user_config = {}
    else:
        user_config = toml.load(path)

    environment_config = load_config_from_environment()

    config = merge(
        OPTIONAL_CONFIG_ENTRIES_WITH_DEFAULTS, user_config, environment_config
    )

    return validate_config(config)


def validate_config(config: Dict[str, Any]) -> Dict[str, Any]:
    # check for missing keys
    for required_key in REQUIRED_CONFIG_ENTRIES:
        if required_key not in config:
            raise ValueError(f"Config is missing required key {required_key}")

    # check for unknown keys
    for key in config.keys():
        if (
            key not in REQUIRED_CONFIG_ENTRIES
            and key not in OPTIONAL_CONFIG_ENTRIES_WITH_DEFAULTS
        ):
            raise ValueError(f"Config contains unknown key {key}")

    # check for validity of entries
    validated_config = {}
    for key, value in config.items():
        try:
            validated_config[key] = CONFIG_ENTRY_VALIDATORS[key](value)
        except ValueError as value_error:
            raise ValueError(f"Invalid config entry {key}: {value_error}")

    return validated_config
