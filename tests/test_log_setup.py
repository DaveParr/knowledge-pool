"""Hosted logging: each line reaches Railway with its real level."""

import io
import json
import logging
import sys

import pytest

import log_setup


@pytest.fixture
def hosted_logs():
    root = logging.getLogger()
    saved, level = list(root.handlers), root.level
    stream = io.StringIO()
    log_setup.use_json_logs(stream)
    yield lambda: [json.loads(line) for line in stream.getvalue().splitlines()]
    root.handlers[:] = saved
    root.setLevel(level)


def test_hosted_logs_give_a_routine_request_line_the_info_level(hosted_logs):
    logging.getLogger("httpx").info('HTTP Request: POST https://api.workos.com/x "HTTP/1.1 200 OK"')
    (line,) = hosted_logs()
    assert line["level"] == "info"
    assert "200 OK" in line["message"]


def test_hosted_logs_give_a_warning_the_warn_level(hosted_logs):
    logging.getLogger("knowledge_pool.rate_limits").warning("refused a key")
    assert [line["level"] for line in hosted_logs()] == ["warn"]


def test_hosted_logs_give_a_failure_the_error_level_with_its_traceback(hosted_logs):
    try:
        raise ValueError("boom")
    except ValueError:
        logging.getLogger("uvicorn.error").exception("Exception in ASGI application")
    (line,) = hosted_logs()
    assert line["level"] == "error"
    assert "ValueError: boom" in line["exception"]


def test_hosted_logs_leave_no_plain_text_handler_on_stderr(hosted_logs):
    plain = [h for h in logging.getLogger().handlers
             if getattr(h, "stream", None) is sys.stderr and not isinstance(h.formatter, log_setup.JsonLineFormatter)]
    assert plain == []
