"""Databases for tests that start Jac processes (see `tests/conftest.py`)."""

import secrets
from contextlib import contextmanager


@contextmanager
def fresh_database(server):
    """A new, empty database on `server` (the `test_postgres` fixture), as a
    `JAC_DB_URL`; dropped on exit."""
    from jaclang.data.pgembed import PgRuntime

    name = f"jac_kp_test_{secrets.token_hex(6)}"  # Jac drops only jac_* databases
    info = PgRuntime(data_dir=server.data_dir, port=server.port, tcp=True, database=name).ensure()
    try:
        yield f"postgresql://{info.user}@{info.host}:{info.port}/{name}"
    finally:
        server.drop_database(name, force=True)
