"""Logging for the hosted app, so Railway reads each line's real level.

Railway labels a plain line `error` when it arrives on stderr and `info` on
stdout, and reads a `level` field from a JSON line on either. The hosted front
door writes one JSON object a line to stdout, with the level in `level`: a
routine request is `info`, a failure `error`. Jac's child server shares the
front door's stdout (`front_door.start_upstream`), so its plain access lines
are `info` too, and its own JSON lines already carry their level.

Only the HTTP transport uses this: on stdio, stdout belongs to MCP.
"""

import io;
import json;
import logging;
import sys;
import from datetime { datetime, timezone }

glob RAILWAY_LEVELS: dict[str, str] = {
    "DEBUG": "debug", "INFO": "info", "WARNING": "warn", "ERROR": "error", "CRITICAL": "error"
};

"""One log record as a JSON line: `level` as Railway spells it, `message` and, for a
record with an exception, the traceback in `exception`."""
class JsonLineFormatter(logging.Formatter) {
    def format(self: JsonLineFormatter, record: logging.LogRecord) -> str {
        line: dict[str, str] = {
            "level": RAILWAY_LEVELS.get(record.levelname, "info"),
            "message": record.getMessage(),
            "logger": record.name,
            "timestamp": datetime.fromtimestamp(record.created, timezone.utc).isoformat()
        };
        if record.exc_info {
            line["exception"] = self.formatException(record.exc_info);
        }
        return json.dumps(line);
    }
}

"""Send every logger's records to `stream` as JSON lines, replacing the handlers the
root logger has (which write plain text to stderr). Uvicorn must not install its
own handlers over this: start it with `log_config=None`."""
def use_json_logs(stream: io.TextIOBase | None = None) {
    handler = logging.StreamHandler(stream or sys.stdout);
    handler.setFormatter(JsonLineFormatter());
    root_logger = logging.getLogger();
    for old in list(root_logger.handlers) {
        root_logger.removeHandler(old);
    }
    root_logger.addHandler(handler);
    root_logger.setLevel(logging.INFO);
}
