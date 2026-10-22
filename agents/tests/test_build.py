import hashlib

import pytest

from vol_agents import build as b

GENERATED = (
    "// SPDX-License-Identifier: MIT\n"
    "pragma solidity ^0.8.0;\n"
    "contract Halo2Verifier {\n"
    "    uint256 constant X = {x};\n"
    "}\n"
)


@pytest.fixture
def srs_env(tmp_path, monkeypatch):
    good = tmp_path / "good.srs"
    good.write_bytes(b"pinned srs bytes")
    monkeypatch.setattr(b, "SRS_SHA256", hashlib.sha256(good.read_bytes()).hexdigest())
    monkeypatch.setattr(b, "OUT", tmp_path / "out")
    monkeypatch.setattr(b, "SRS", tmp_path / "out" / "kzg15.srs")
    monkeypatch.delenv(b.SRS_ENV, raising=False)
    return good


def test_srs_copied_from_explicit_source(srs_env):
    b.ensure_srs(srs_env)
    assert b.SRS.read_bytes() == srs_env.read_bytes()


def test_srs_source_from_env(srs_env, monkeypatch):
    monkeypatch.setenv(b.SRS_ENV, str(srs_env))
    b.ensure_srs()
    assert b.SRS.read_bytes() == srs_env.read_bytes()


def test_srs_source_with_wrong_digest_rejected(srs_env, tmp_path):
    bad = tmp_path / "bad.srs"
    bad.write_bytes(b"tampered")
    with pytest.raises(b.SrsMismatch):
        b.ensure_srs(bad)
    assert not b.SRS.exists()


def test_existing_srs_with_wrong_digest_rejected(srs_env):
    b.SRS.parent.mkdir(parents=True)
    b.SRS.write_bytes(b"tampered")
    with pytest.raises(b.SrsMismatch):
        b.ensure_srs(srs_env)


@pytest.fixture
def verifier_env(tmp_path, monkeypatch):
    sol = tmp_path / "Verifier.sol"
    monkeypatch.setattr(b, "paths", lambda model: {"sol": sol})
    monkeypatch.setattr(b, "VERIFIER_DIR", tmp_path / "verifier")
    (tmp_path / "verifier").mkdir()
    return sol


def test_verifier_installed_when_absent(verifier_env):
    verifier_env.write_text(GENERATED.replace("{x}", "1"))
    dest = b.install_verifier("toy_model")
    assert dest.name == "ToyModelVerifier.sol"
    assert "contract ToyModelVerifier {" in dest.read_text()


def test_identical_verifier_left_alone(verifier_env):
    verifier_env.write_text(GENERATED.replace("{x}", "1"))
    dest = b.install_verifier("toy_model")
    mtime = dest.stat().st_mtime_ns
    assert b.install_verifier("toy_model") == dest
    assert dest.stat().st_mtime_ns == mtime


def test_changed_verifier_needs_force(verifier_env):
    verifier_env.write_text(GENERATED.replace("{x}", "1"))
    dest = b.install_verifier("toy_model")
    committed = dest.read_text()
    verifier_env.write_text(GENERATED.replace("{x}", "2"))
    with pytest.raises(b.VerifierChanged):
        b.install_verifier("toy_model")
    assert dest.read_text() == committed
    b.install_verifier("toy_model", force=True)
    assert "= 2;" in dest.read_text()
