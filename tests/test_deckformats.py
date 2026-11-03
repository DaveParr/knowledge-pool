import json
from pathlib import Path

import jsonschema

SCHEMA = json.loads((Path(__file__).parent.parent / "schemas" / "mtgdeck-1.schema.json").read_text())


def test_schema_file_is_a_valid_json_schema():
    jsonschema.Draft202012Validator.check_schema(SCHEMA)
