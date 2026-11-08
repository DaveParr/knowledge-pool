import json

import pytest

from jaclang.runtimelib.testing import JacTestClient

from catalog import store


def _reports(resp):
    body = resp.json()
    assert body["ok"], body
    return body["data"]["reports"]


def _oracle_id(name: str) -> str:
    return next(c["oracle_id"] for c in store.search(name) if c["name"] == name)


def _new_deck(client, name="IO deck", format="modern") -> str:
    _reports(client.post("/walker/CreateDeck", json={"name": name, "format": format}))
    return _reports(client.post("/walker/ListDecks"))[0][-1]["_jac_id"]


def test_export_mtgdeck1_contains_every_card_in_the_right_zone(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        deck_id = _new_deck(client)
        client.post("/walker/AddCard", json={"deck_id": deck_id, "oracle_id": _oracle_id("Lightning Bolt"), "count": 4})
        client.post("/walker/AddCard", json={"deck_id": deck_id, "oracle_id": _oracle_id("Mountain"), "count": 20, "zone": "sideboard"})

        exported = _reports(client.post("/walker/DeckExport", json={"deck_id": deck_id, "format": "mtgdeck1"}))[0]
        doc = json.loads(exported["content"])
        assert doc["schema"] == "mtgdeck/1"
        assert {e["name"]: e["count"] for e in doc["zones"]["main"]} == {"Lightning Bolt": 4}
        assert {e["name"]: e["count"] for e in doc["zones"]["sideboard"]} == {"Mountain": 20}
    finally:
        client.close()


def _error(reports: list) -> dict:
    [only] = reports
    return {k: only[k] for k in ("code", "message")}


def test_export_says_why_a_format_cannot_be_used(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        deck_id = _new_deck(client)
        assert _error(_reports(client.post("/walker/DeckExport", json={"deck_id": deck_id, "format": "nope"}))) == {
            "code": "unknown-list-format",
            "message": "Unknown deck format: nope. Use one of: arena, moxfield, mtgdeck1, mtgjson, text.",
        }
    finally:
        client.close()


def test_export_mtgdeck1_then_import_round_trips(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        deck_id = _new_deck(client)
        client.post("/walker/AddCard", json={"deck_id": deck_id, "oracle_id": _oracle_id("Lightning Bolt"), "count": 4})
        client.post("/walker/AddCard", json={"deck_id": deck_id, "oracle_id": _oracle_id("Mountain"), "count": 20, "zone": "sideboard"})
        exported = _reports(client.post("/walker/DeckExport", json={"deck_id": deck_id, "format": "mtgdeck1"}))[0]

        imported = _reports(client.post("/walker/DeckImport", json={
            "deck_id": deck_id, "format": "mtgdeck1", "text": exported["content"],
        }))[0]
        assert imported["unresolved"] == []
        cards = {(c["name"], c["zone"]): c["count"] for c in imported["deck"]["cards"]}
        assert cards == {("Lightning Bolt", "main"): 4, ("Mountain", "sideboard"): 20}
        # Re-importing the same list changes no counts, so it logs nothing new.
        assert all(h["reason"] == "Edited in the app" for h in imported["deck"]["history"])
    finally:
        client.close()


def test_import_flags_unresolved_lines_and_never_invents_a_card(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        deck_id = _new_deck(client)
        result = _reports(client.post("/walker/DeckImport", json={
            "deck_id": deck_id, "format": "text",
            "text": "4 Lightning Bolt\n2 Flargle the Unreal\n",
        }))[0]
        assert result["unresolved"] == ["Flargle the Unreal"]
        assert [c["name"] for c in result["deck"]["cards"]] == ["Lightning Bolt"]
    finally:
        client.close()


def test_importing_a_new_list_replaces_what_was_there_before(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        deck_id = _new_deck(client)
        client.post("/walker/AddCard", json={"deck_id": deck_id, "oracle_id": _oracle_id("Goblin Guide"), "count": 4})
        result = _reports(client.post("/walker/DeckImport", json={
            "deck_id": deck_id, "format": "text", "text": "4 Lightning Bolt\n",
        }))[0]
        assert [c["name"] for c in result["deck"]["cards"]] == ["Lightning Bolt"]
    finally:
        client.close()


def test_commander_zone_entries_do_not_count_toward_main_deck_legality(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        deck_id = _new_deck(client, format="modern")
        text = json.dumps({
            "schema": "mtgdeck/1", "name": "cmdr test", "format": "modern",
            "zones": {
                "commander": [{"name": "Lightning Bolt", "count": 1}],
                "main": [{"name": "Mountain", "count": 60}],
            },
        })
        result = _reports(client.post("/walker/DeckImport", json={"deck_id": deck_id, "format": "mtgdeck1", "text": text}))[0]
        assert result["unresolved"] == []
        view = _reports(client.post("/walker/GetDeck", json={"deck_id": deck_id}))[0]
        assert view["legal"] is True
        assert view["main_total"] == 60
    finally:
        client.close()


def test_import_says_why_a_format_cannot_be_used(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        deck_id = _new_deck(client)
        assert _error(_reports(client.post("/walker/DeckImport", json={"deck_id": deck_id, "format": "nope", "text": ""})))["code"] == "unknown-list-format"
        assert _error(_reports(client.post("/walker/DeckImport", json={"deck_id": deck_id, "format": "mtgjson", "text": "{}"}))) == {
            "code": "no-import", "message": "mtgjson lists can be exported but not imported.",
        }
        assert _error(_reports(client.post("/walker/CreateDeckFromList", json={"format": "mtgjson", "text": "{}"})))["code"] == "no-import"
        assert [d["name"] for d in _reports(client.post("/walker/ListDecks"))[0]] == ["IO deck"]
    finally:
        client.close()


def test_import_flags_an_invalid_zone_instead_of_bricking_the_deck(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        deck_id = _new_deck(client)
        client.post("/walker/AddCard", json={"deck_id": deck_id, "oracle_id": _oracle_id("Goblin Guide"), "count": 4})
        text = json.dumps({
            "schema": "mtgdeck/1", "name": "bad zone test", "format": "modern",
            "zones": {
                "bogus_zone": [{"name": "Mountain", "count": 1}],
                "main": [{"name": "Lightning Bolt", "count": 4}],
            },
        })
        result = _reports(client.post("/walker/DeckImport", json={"deck_id": deck_id, "format": "mtgdeck1", "text": text}))[0]
        assert result["unresolved"] == ["Mountain (invalid zone: bogus_zone)"]
        assert [c["name"] for c in result["deck"]["cards"]] == ["Lightning Bolt"]

        # The deck must still be readable afterwards - a bad zone entry must
        # never be persisted onto the deck.
        view = _reports(client.post("/walker/GetDeck", json={"deck_id": deck_id}))[0]
        assert [c["name"] for c in view["cards"]] == ["Lightning Bolt"]
    finally:
        client.close()


def test_importing_plain_text_as_mtgdeck1_reports_a_parse_error_and_keeps_the_deck(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        deck_id = _new_deck(client)
        client.post("/walker/AddCard", json={"deck_id": deck_id, "oracle_id": _oracle_id("Goblin Guide"), "count": 4})
        result = _reports(client.post("/walker/DeckImport", json={
            "deck_id": deck_id, "format": "mtgdeck1", "text": "4 Lightning Bolt",
        }))[0]
        assert len(result["unresolved"]) == 1
        assert "not JSON" in result["unresolved"][0]
        assert [(c["name"], c["count"]) for c in result["deck"]["cards"]] == [("Goblin Guide", 4)]
    finally:
        client.close()


def test_mtgdeck1_entries_with_invalid_counts_are_never_persisted(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        deck_id = _new_deck(client)
        text = json.dumps({
            "schema": "mtgdeck/1", "name": "bad counts", "format": "modern",
            "zones": {"main": [
                {"name": "Mountain", "count": -5},
                {"name": "Goblin Guide", "count": "4"},
                {"name": "Lightning Bolt", "count": 4},
            ]},
        })
        result = _reports(client.post("/walker/DeckImport", json={"deck_id": deck_id, "format": "mtgdeck1", "text": text}))[0]
        assert result["unresolved"] == ["Mountain (invalid count)", "Goblin Guide (invalid count)"]
        view = _reports(client.post("/walker/GetDeck", json={"deck_id": deck_id}))[0]
        assert [(c["name"], c["count"]) for c in view["cards"]] == [("Lightning Bolt", 4)]
        assert view["main_total"] == 4
    finally:
        client.close()


def test_the_same_card_listed_across_printings_is_summed(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        deck_id = _new_deck(client)
        result = _reports(client.post("/walker/DeckImport", json={
            "deck_id": deck_id, "format": "arena",
            "text": "Deck\n2 Lightning Bolt (M10) 146\n2 Lightning Bolt (2XM) 123\n\nSideboard\n1 Lightning Bolt (M10) 146\n",
        }))[0]
        assert result["unresolved"] == []
        cards = {(c["name"], c["zone"]): c["count"] for c in result["deck"]["cards"]}
        assert cards == {("Lightning Bolt", "main"): 4, ("Lightning Bolt", "sideboard"): 1}
    finally:
        client.close()


def test_duplicate_mtgdeck1_entries_sum_counts_and_keep_the_last_metadata(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        deck_id = _new_deck(client)
        text = json.dumps({
            "schema": "mtgdeck/1", "name": "dupes", "format": "modern",
            "zones": {"main": [
                {"name": "Lightning Bolt", "count": 1, "tags": ["first"]},
                {"name": "Lightning Bolt", "count": 3, "tags": ["last"], "reason": "burn"},
            ]},
        })
        result = _reports(client.post("/walker/DeckImport", json={"deck_id": deck_id, "format": "mtgdeck1", "text": text}))[0]
        [card] = result["deck"]["cards"]
        assert (card["name"], card["count"], card["tags"], card["reason"]) == ("Lightning Bolt", 4, ["last"], "burn")
    finally:
        client.close()


def test_a_paste_where_nothing_resolves_leaves_the_deck_untouched(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        deck_id = _new_deck(client)
        client.post("/walker/AddCard", json={"deck_id": deck_id, "oracle_id": _oracle_id("Goblin Guide"), "count": 4})
        for text, unresolved in [
            ("this is not a deck\nneither is this\n", ["this is not a deck", "neither is this"]),
            ("4 Flargle the Unreal\n", ["Flargle the Unreal"]),
        ]:
            result = _reports(client.post("/walker/DeckImport", json={"deck_id": deck_id, "format": "text", "text": text}))[0]
            assert result["unresolved"] == unresolved
            assert [(c["name"], c["count"]) for c in result["deck"]["cards"]] == [("Goblin Guide", 4)]
        view = _reports(client.post("/walker/GetDeck", json={"deck_id": deck_id}))[0]
        assert [(c["name"], c["count"]) for c in view["cards"]] == [("Goblin Guide", 4)]
    finally:
        client.close()


def test_a_stale_oracle_id_falls_back_to_the_card_name(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        deck_id = _new_deck(client)
        text = json.dumps({
            "schema": "mtgdeck/1", "name": "stale", "format": "modern",
            "zones": {"main": [
                {"name": "Lightning Bolt", "oracleId": "00000000-0000-0000-0000-000000000000", "count": 4},
                {"name": "Flargle the Unreal", "oracleId": "00000000-0000-0000-0000-000000000001", "count": 1},
            ]},
        })
        result = _reports(client.post("/walker/DeckImport", json={"deck_id": deck_id, "format": "mtgdeck1", "text": text}))[0]
        assert result["unresolved"] == ["Flargle the Unreal"]
        assert [(c["name"], c["count"]) for c in result["deck"]["cards"]] == [("Lightning Bolt", 4)]
    finally:
        client.close()


@pytest.mark.parametrize("fmt, text", [
    ("text", ""),
    ("arena", "   \n\n"),
    ("mtgdeck1", json.dumps({"schema": "mtgdeck/1", "name": "empty", "zones": {}})),
    ("mtgdeck1", json.dumps({"name": "x", "mainBoard": [{"count": 4, "name": "Lightning Bolt"}]})),
])
def test_an_import_with_no_cards_leaves_the_deck_untouched(tmp_path, fmt, text):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        deck_id = _new_deck(client)
        client.post("/walker/AddCard", json={"deck_id": deck_id, "oracle_id": _oracle_id("Goblin Guide"), "count": 4})
        result = _reports(client.post("/walker/DeckImport", json={"deck_id": deck_id, "format": fmt, "text": text}))[0]
        assert len(result["unresolved"]) == 1
        view = _reports(client.post("/walker/GetDeck", json={"deck_id": deck_id}))[0]
        assert [(c["name"], c["count"]) for c in view["cards"]] == [("Goblin Guide", 4)]
    finally:
        client.close()


def test_create_deck_from_list_makes_a_filled_deck_and_flags_unresolved_lines(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        result = _reports(client.post("/walker/CreateDeckFromList", json={
            "name": "Burn", "format": "moxfield",
            "text": "4 Lightning Bolt (2X2) 117\n2 Flargle the Unreal\n\nSideboard\n3 Goblin Guide\n",
        }))[0]
        assert result["unresolved"] == ["Flargle the Unreal"]
        view = _reports(client.post("/walker/GetDeck", json={"deck_id": result["deck_id"]}))[0]
        assert view["name"] == "Burn"
        assert view["format"] == "standard"
        assert sorted((c["name"], c["count"], c["zone"]) for c in view["cards"]) == [
            ("Goblin Guide", 3, "sideboard"), ("Lightning Bolt", 4, "main"),
        ]
        assert {h["reason"] for h in view["history"]} == {"Created from a moxfield list"}
    finally:
        client.close()


def test_create_deck_from_mtgdeck1_takes_its_name_and_format_when_none_is_given(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        text = json.dumps({
            "schema": "mtgdeck/1", "name": "Shared Burn", "format": "modern",
            "zones": {"main": [{"name": "Lightning Bolt", "count": 4}]},
        })
        result = _reports(client.post("/walker/CreateDeckFromList", json={"name": " ", "format": "mtgdeck1", "text": text}))[0]
        view = _reports(client.post("/walker/GetDeck", json={"deck_id": result["deck_id"]}))[0]
        assert (view["name"], view["format"]) == ("Shared Burn", "modern")
    finally:
        client.close()


@pytest.mark.parametrize("fmt, text", [
    ("text", ""),
    ("text", "4 Flargle the Unreal\n"),
    ("mtgdeck1", "4 Lightning Bolt\n"),
])
def test_create_deck_from_a_list_with_nothing_usable_creates_no_deck(tmp_path, fmt, text):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        result = _reports(client.post("/walker/CreateDeckFromList", json={"name": "Nope", "format": fmt, "text": text}))[0]
        assert result["deck_id"] == ""
        assert len(result["unresolved"]) >= 1
        assert _reports(client.post("/walker/ListDecks"))[0] == []
    finally:
        client.close()


@pytest.mark.parametrize("fmt, text", [
    ("moxfield", "4 Lightning Bolt\n"),
    ("mtgdeck1", json.dumps({"schema": "mtgdeck/1", "name": "x", "format": "standard",
                             "zones": {"main": [{"name": "Lightning Bolt", "count": 4}]}})),
])
def test_create_deck_from_list_uses_the_chosen_play_format(tmp_path, fmt, text):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        result = _reports(client.post("/walker/CreateDeckFromList", json={
            "name": "Burn", "format": fmt, "text": text, "play_format": "modern",
        }))[0]
        view = _reports(client.post("/walker/GetDeck", json={"deck_id": result["deck_id"]}))[0]
        assert view["format"] == "modern"
        assert view["legal"] is False
        assert all("not legal in" not in v["message"] for v in view["violations"])
    finally:
        client.close()
