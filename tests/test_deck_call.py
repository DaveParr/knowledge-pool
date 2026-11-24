"""The deck-call endpoint without sign-in: `deck_call.walker_call` and `function_call`
given a fixed `Caller`, with no credential, `Origin` or rate-limit check in the way."""

import pytest
from jaclang.testing.testing import JacTestClient
from starlette.applications import Starlette
from starlette.testclient import TestClient
from starlette.routing import Route

import deck_call
from gatekeeper import Caller

pytestmark = pytest.mark.usefixtures("jac_db_url")


def _as(user_id: str) -> TestClient:
    async def walker(request):
        return await deck_call.walker_call(Caller(user_id=user_id), request)

    async def function(request):
        return await deck_call.function_call(Caller(user_id=user_id), request)

    return TestClient(Starlette(routes=[
        Route("/walker/{name}", walker, methods=["POST"]), Route("/function/{name}", function, methods=["POST"]),
    ]))


@pytest.fixture
def jac(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    # Jac's test client sets Jac up on `JAC_DB_URL` on its first request, and frees it on close.
    assert client.get("/healthz").status_code in (200, 404)
    yield client
    client.close()


def _names(client: TestClient) -> list[str]:
    return [d["name"] for d in client.post("/walker/ListDecks", json={}).json()["data"]["reports"][0]]


def test_a_walker_call_runs_as_the_fixed_caller(jac):
    alice, bob = _as("user_alice"), _as("user_bob")
    made = alice.post("/walker/CreateDeck", json={"name": "Mine", "format": "commander"})
    assert made.status_code == 200 and made.json()["ok"] is True
    assert _names(alice) == ["Mine"] and _names(bob) == []


def test_a_function_call_answers_in_jacs_envelope(jac):
    reply = _as("user_alice").post("/function/list_formats", json={})
    assert reply.status_code == 200 and reply.json()["data"]["result"]


def test_a_walker_that_is_not_the_pages_is_404(jac):
    assert _as("user_alice").post("/walker/GetFormatRules", json={}).status_code == 404
    assert _as("user_alice").post("/function/nothing", json={}).status_code == 404


def test_fields_that_do_not_fit_are_422(jac):
    door = _as("user_alice")
    assert door.post("/walker/GetDeck", json={"nope": 1}).status_code == 422
    assert door.post("/walker/ListDecks", json={"reports": []}).status_code == 422
    assert door.post("/function/list_formats", json={"x": 1}).status_code == 422


def test_a_call_sent_without_an_origin_still_runs(jac):
    """The origin check is the gatekeeper's: this endpoint never looks at it."""
    assert _as("user_alice").post("/walker/ListDecks", json={}, headers={}).status_code == 200
