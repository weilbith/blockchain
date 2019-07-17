from typing import Any, Dict

import toml

from eth_utils.toolz import merge


def validate_rpc_url(url: Any) -> None:
    if not isinstance(url, str):
        raise ValueError(f"{url} is not a valid RPC url")


def validate_positive_float(number: Any) -> float:
    if not isinstance(number, (int, float)):
        raise ValueError(f"{number} is neither integer nor float")
    if number <= 0:
        raise ValueError(f"{number} must be positive")
    return float(number)


REQUIRED_CONFIG_ENTRIES = ["home_rpc_url", "foreign_rpc_url"]

OPTIONAL_CONFIG_ENTRIES_WITH_DEFAULTS: Dict[str, Any] = {
    "transfer_event_poll_interval": 5
}

CONFIG_ENTRY_VALIDATORS = {
    "home_rpc_url": validate_rpc_url,
    "foreign_rpc_url": validate_rpc_url,
    "transfer_event_poll_interval": validate_positive_float,
}

assert all(key in CONFIG_ENTRY_VALIDATORS for key in REQUIRED_CONFIG_ENTRIES)
assert all(
    key in CONFIG_ENTRY_VALIDATORS for key in OPTIONAL_CONFIG_ENTRIES_WITH_DEFAULTS
)


def load_config(path: str) -> Dict[str, Any]:
    if path is None:
        user_config = {}
    else:
        user_config = toml.load(path)

    config = merge(OPTIONAL_CONFIG_ENTRIES_WITH_DEFAULTS, user_config)

    validate_config(config)

    return config


def validate_config(config: Dict[str, Any]) -> None:
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
    for key, value in config.items():
        try:
            CONFIG_ENTRY_VALIDATORS[key](value)
        except ValueError as value_error:
            raise ValueError(f"Invalid config entry {key}: {value_error}")