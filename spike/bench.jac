"""S02 benchmark: load the catalogue graph in memory, then time FindSynergies.

    uv run jac run spike/bench.jac
"""

import time;
import json;
import resource;
import from spike.synergy { load_catalog, make_deck, FindSynergies, LoadedCatalog, Enables, PaysOff }

glob DECKS: list[tuple[str, dict[str, int]]] = [
    (
        "Mono-red burn (spells: biggest theme)",
        {
            "Lightning Bolt": 4, "Monastery Swiftspear": 4, "Goblin Guide": 4,
            "Lava Spike": 4, "Rift Bolt": 4, "Skewer the Critics": 4,
            "Light Up the Stage": 4, "Eidolon of the Great Revel": 4,
            "Searing Blaze": 4, "Mountain": 24
        }
    ),
    (
        "Mono-black aristocrats (sacrifice, tokens)",
        {
            "Viscera Seer": 4, "Blood Artist": 4, "Zulaport Cutthroat": 4,
            "Carrion Feeder": 4, "Bitterblossom": 4, "Gravecrawler": 4,
            "Bloodghast": 4, "Village Rites": 4, "Swamp": 28
        }
    ),
    (
        "Mono-green landfall",
        {
            "Lotus Cobra": 4, "Tireless Tracker": 4, "Rampaging Baloths": 4,
            "Explore": 4, "Harrow": 4, "Scute Swarm": 4, "Primeval Titan": 4,
            "Avenger of Zendikar": 4, "Forest": 28
        }
    )
];

def rss_mb -> float {
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024.0;
}

with entry:__main__ {
    t0 = time.perf_counter();
    cat = load_catalog("data/catalog.sqlite");
    load_s = time.perf_counter() - t0;
    print(f"LOAD {load_s:.1f}s, peak RSS {rss_mb():.0f} MB, {json.dumps(cat.counts)}");
    for t in cat.themes.values() {
        n_en = len([t <-:Enables:<-]);
        n_pay = len([t <-:PaysOff:<-]);
        print(f"  theme {t.name}: {n_en} enablers, {n_pay} payoffs");
    }
    for (name, lines) in DECKS {
        assert sum(lines.values()) == 60;
        deck = make_deck(cat, name, "modern", lines);
        times: list[float] = [];
        w = FindSynergies();
        for _i in range(5) {
            t = time.perf_counter();
            w = deck spawn FindSynergies();
            times.append(time.perf_counter() - t);
        }
        times.sort();
        print(f"DECK {name}: median {times[2] * 1000:.0f} ms, worst {times[-1] * 1000:.0f} ms, {len(w.scores)} candidates scored");
        for s in w.result[:5] {
            print(f"    {s.score:6.1f}  {s.name}  {json.dumps(s.breakdown)}");
        }
    }
}
