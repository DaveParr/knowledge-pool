from lib import *
a, ar = user("alicer1"); b, br = user("bobr1")
F = lambda name, body, tok=None: call("/function/" + name, body, tok)
for how in ("query", "loop", "disconnect"):
    tag = "G2"
    name = "rm-" + how
    d = show(f"bob make_deck {name}", F("make_deck", {"tag": tag, "name": name, "count": 2}, b))
    ad = show(f"alice make_deck {name}", F("make_deck", {"tag": tag, "name": "a-" + name, "count": 5}, a))
    show(f"bob remove_card2 how={how}", F("remove_card2", {"tag": tag, "deck_name": name, "how": how}, b))
    show("bob my_deck after", F("my_deck", {"deck_id": d["deck"]}, b))
    show("alice my_deck after", F("my_deck", {"deck_id": ad["deck"]}, a))
