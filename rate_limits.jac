"""Rate limits at the front door.

Two token-bucket limits, kept in the front door's memory. Each bucket holds up
to a full minute's allowance (the burst) and refills evenly across the minute.

- Per address, for requests with no valid token or session: strangers cannot
  burn compute. The address is `X-Real-IP`; a request without it counts against
  one shared "unknown" bucket. The address table holds at most `MAX_ADDRESSES`
  entries; once full, an address with no entry shares "unknown".
- Per user, for requests with a valid token or session, browser and connector
  together: one user's runaway agent cannot starve the others.

Both limits are read from variables (`KP_RATE_LIMIT_ADDRESS` and
`KP_RATE_LIMIT_USER`, requests a minute) with the defaults below; tests set
them low. A refused key is logged once a minute.
"""

import logging;
import math;
import os;
import time;

glob ADDRESS_LIMIT_SETTING: str = "KP_RATE_LIMIT_ADDRESS",
     USER_LIMIT_SETTING: str = "KP_RATE_LIMIT_USER",
     DEFAULT_ADDRESS_LIMIT: int = 30,
     DEFAULT_USER_LIMIT: int = 300,
     MAX_ADDRESSES: int = 10000,
     UNKNOWN_ADDRESS: str = "unknown",
     WINDOW_S: float = 60.0,
     LOG_PRUNE_AT: int = 1000,
     RATE_LOG: logging.Logger = logging.getLogger("knowledge_pool.rate_limits");

"""A set of token buckets, one per key, each `per_minute` tokens deep. `take`
spends a token for a key. `max_keys` bounds the table: past it, a new key
shares `overflow_key`'s bucket."""
obj Buckets {
    has per_minute: int,
        label: str,
        max_keys: int = 0,
        overflow_key: str = "",
        clock: Callable[[], float] = time.monotonic,
        tokens: dict[str, float] = {},
        stamped: dict[str, float] = {},
        logged: dict[str, float] = {};

    """Spend one token for `key`: 0 when allowed, else the whole seconds
    (at least 1) until a token is back."""
    def take(key: str) -> int {
        now = self.clock();
        key = self.entry_for(key, now);
        have = self.refilled(key, now);
        self.stamped[key] = now;
        if have >= 1.0 {
            self.tokens[key] = have - 1.0;
            return 0;
        }
        self.tokens[key] = have;
        pause = max(1, math.ceil((1.0 - have) * WINDOW_S / self.per_minute));
        self.log_refusal(key, now);
        return pause;
    }

    """The tokens `key` holds now: what it had, plus the refill since."""
    def refilled(key: str, now: float) -> float {
        if key not in self.tokens {
            return float(self.per_minute);
        }
        earned = (now - self.stamped[key]) * self.per_minute / WINDOW_S;
        return min(float(self.per_minute), self.tokens[key] + earned);
    }

    """The key whose bucket answers for `key`: itself, or the overflow key when
    the table is full and `key` has no entry. Entries that have refilled to a
    full bucket are the same as no entry, so they go first."""
    def entry_for(key: str, now: float) -> str {
        if not self.max_keys or key in self.tokens or key == self.overflow_key {
            return key;
        }
        # One place is always kept for the overflow key, so the table never holds more than `max_keys`.
        room = self.max_keys - (0 if self.overflow_key in self.tokens else 1);
        if len(self.tokens) < room {
            return key;
        }
        for k in list(self.tokens) {
            if k != self.overflow_key and self.refilled(k, now) >= self.per_minute {
                del self.tokens[k];
                del self.stamped[k];
            }
        }
        return key if len(self.tokens) < room else self.overflow_key;
    }

    """One log line per refused key per minute."""
    def log_refusal(key: str, now: float) {
        if key in self.logged and now - self.logged[key] < WINDOW_S {
            return;
        }
        # Lines older than a minute no longer silence anything: forget them, so this table stays small.
        if len(self.logged) >= LOG_PRUNE_AT {
            self.logged = {k: t for (k, t) in self.logged.items() if now - t < WINDOW_S};
        }
        self.logged[key] = now;
        RATE_LOG.warning("Rate limit hit for %s %s (%d a minute).", self.label, key, self.per_minute);
    }
}

"""The front door's two limits."""
obj RateLimits {
    has addresses: Buckets,
        users: Buckets;
}

"""A positive whole number from the environment variable `name`, else `fallback`."""
def limit_setting(name: str, fallback: int) -> int {
    raw = os.environ.get(name, "").strip();
    if not raw {
        return fallback;
    }
    value = int(raw);
    if value < 1 {
        raise ValueError(f"{name} must be a whole number of requests a minute, at least 1, not {raw!r}.");
    }
    return value;
}

"""The limits from the environment, with their defaults. `clock` is for tests."""
def rate_limits(clock: Callable[[], float] = time.monotonic) -> RateLimits {
    return RateLimits(
        addresses=Buckets(
            per_minute=limit_setting(ADDRESS_LIMIT_SETTING, DEFAULT_ADDRESS_LIMIT), label="address",
            max_keys=MAX_ADDRESSES, overflow_key=UNKNOWN_ADDRESS, clock=clock
        ),
        users=Buckets(per_minute=limit_setting(USER_LIMIT_SETTING, DEFAULT_USER_LIMIT), label="user", clock=clock)
    );
}
