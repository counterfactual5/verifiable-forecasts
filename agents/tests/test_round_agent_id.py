import pytest

from vol_agents.chain import keccak
from vol_agents.round import _registered_agent_id

REGISTERED = keccak(b"Registered(uint256,string,address)")
TRANSFER = keccak(b"Transfer(address,address,uint256)")
OWNER = "0x" + "00" * 12 + "70997970c51812dc3a010c7d01b50e0d17dc79c8"


def word(n: int) -> str:
    return "0x" + format(n, "064x")


def unrelated():
    return {"topics": [word(0xBEEF), word(0xDEAD)]}


def mint(token_id: int, sender: int = 0):
    return {"topics": [TRANSFER, word(sender), OWNER, word(token_id)]}


def registered(agent_id: int):
    return {"topics": [REGISTERED.upper().replace("0X", "0x"), word(agent_id), OWNER]}


def test_registered_wins_over_earlier_unrelated_and_transfer_logs():
    receipt = {"logs": [unrelated(), mint(43), registered(42)]}
    assert _registered_agent_id(receipt) == 42


def test_registered_after_transfer():
    assert _registered_agent_id({"logs": [mint(42), registered(42)]}) == 42


def test_lite_registry_emits_only_registered():
    assert _registered_agent_id({"logs": [registered(7)]}) == 7


def test_falls_back_to_mint_transfer():
    assert _registered_agent_id({"logs": [mint(42)]}) == 42


def test_non_mint_transfer_raises():
    receipt = {"logs": [unrelated(), mint(42, sender=0x1234)]}
    with pytest.raises(RuntimeError):
        _registered_agent_id(receipt)
