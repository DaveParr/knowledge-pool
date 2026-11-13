from lib import *
a, ar = user("alicer1"); b, br = user("bobr1")
F = lambda name, body, tok=None: call("/function/" + name, body, tok)
card = open(sys.argv[1].replace("port", "g2card")).read()
print(call("/function/rename_node", {"node_id": card, "name": "HACKED"}, b))
print(call("/function/delete_node", {"node_id": card}, b))
print(call("/function/look", {"tag": "G2"}, a)[1]["data"]["result"]["cards"])
print(call("/function/make_deck", {"tag": "Rr1", "name": "strict-R", "count": 1}, b))
print(call("/function/make_deck", {"tag": "G2", "name": "strict-G", "count": 1}, b)[0])
