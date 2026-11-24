"""The page's paths (`session_bar.jac`, client code) copy the front door's names;
the page cannot import them, so this ties the copies together."""

import re
from pathlib import Path

import gatekeeper

PAGE = (Path(__file__).resolve().parent.parent / "session_bar.jac").read_text()


def page_path(name: str) -> str:
    return re.search(rf'{name}: str = "([^"]+)"', PAGE).group(1)


def test_the_pages_sign_in_sign_out_and_session_paths_are_the_front_doors():
    assert page_path("SIGN_IN_PATH") == gatekeeper.LOGIN_PATH
    assert page_path("SIGN_OUT_PATH") == gatekeeper.LOGOUT_PATH
    assert page_path("ME_PATH") == gatekeeper.ME_PATH


def test_the_pages_connector_path_is_one_the_front_door_hands_to_mcp():
    assert page_path("CONNECTOR_PATH") in gatekeeper.MCP_PREFIXES
