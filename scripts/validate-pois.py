#!/usr/bin/env python3
"""Validate POI files against docs/schema/pois.schema.json (stdlib only).

usage: scripts/validate-pois.py [file ...]

With no arguments, checks every App/Wander/Resources/pois-*.json in the repo.
Implements the JSON Schema subset the schema uses: type, required, properties,
additionalProperties: false, enum, const, pattern, minimum/maximum, minLength, maxLength,
items and $ref to #/$defs. Also checks that POI ids are unique within a file.
Prints `<file>: <json path>: <message>` per problem (at most 50 per file) and
exits 1 if any file has a problem.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCHEMA = ROOT / "docs/schema/pois.schema.json"
MAX_PER_FILE = 50

TYPES = {
    "object": lambda v: isinstance(v, dict),
    "array": lambda v: isinstance(v, list),
    "string": lambda v: isinstance(v, str),
    "boolean": lambda v: isinstance(v, bool),
    "number": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
    "integer": lambda v: (isinstance(v, int) and not isinstance(v, bool))
    or (isinstance(v, float) and v.is_integer()),
    "null": lambda v: v is None,
}
KNOWN = {"$schema", "$id", "$defs", "title", "description", "type", "required",
         "additionalProperties", "properties", "enum", "const", "pattern",
         "minimum", "maximum", "minLength", "maxLength", "items", "$ref"}


def same(a, b):
    """JSON equality: true != 1, 1 == 1.0."""
    if isinstance(a, bool) or isinstance(b, bool):
        return type(a) is type(b) and a == b
    return a == b


def child(path, key):
    if isinstance(key, int):
        return f"{path}[{key}]"
    return f"{path}.{key}" if re.fullmatch(r"[A-Za-z_$][A-Za-z0-9_$]*", key) else f"{path}[{json.dumps(key)}]"


class Validator:
    def __init__(self, schema):
        self.root = schema
        self.unsupported = set()

    def resolve(self, ref):
        if not ref.startswith("#/"):
            raise ValueError(f"unsupported $ref {ref}")
        node = self.root
        for part in ref[2:].split("/"):
            node = node[part.replace("~1", "/").replace("~0", "~")]
        return node

    def check(self, value, schema, path, errors):
        self.unsupported |= set(schema) - KNOWN
        if "$ref" in schema:
            self.check(value, self.resolve(schema["$ref"]), path, errors)
        if "type" in schema:
            types = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
            if not any(TYPES[t](value) for t in types):
                errors.append((path, f"expected {' or '.join(types)}, got {json.dumps(value)[:60]}"))
                return  # other keywords would only add noise
        if "const" in schema and not same(value, schema["const"]):
            errors.append((path, f"must be {json.dumps(schema['const'])}, got {json.dumps(value)[:60]}"))
        if "enum" in schema and not any(same(value, e) for e in schema["enum"]):
            allowed = ", ".join(json.dumps(e) for e in schema["enum"])
            errors.append((path, f"{json.dumps(value)[:60]} is not one of {allowed}"))
        if isinstance(value, str):
            if "minLength" in schema and len(value) < schema["minLength"]:
                errors.append((path, f"shorter than {schema['minLength']} character(s)"))
            if "maxLength" in schema and len(value) > schema["maxLength"]:
                errors.append((path, f"longer than {schema['maxLength']} character(s)"))
            if "pattern" in schema and not re.search(schema["pattern"], value):
                errors.append((path, f"{json.dumps(value)[:60]} does not match {schema['pattern']}"))
        if TYPES["number"](value):
            if "minimum" in schema and value < schema["minimum"]:
                errors.append((path, f"{value} is below the minimum {schema['minimum']}"))
            if "maximum" in schema and value > schema["maximum"]:
                errors.append((path, f"{value} is above the maximum {schema['maximum']}"))
        if isinstance(value, dict):
            props = schema.get("properties", {})
            for key in schema.get("required", []):
                if key not in value:
                    errors.append((path, f"missing required key {json.dumps(key)}"))
            for key, item in value.items():
                if key in props:
                    self.check(item, props[key], child(path, key), errors)
                elif schema.get("additionalProperties") is False:
                    errors.append((child(path, key), "unexpected key (additionalProperties is false)"))
        if isinstance(value, list) and "items" in schema:
            for i, item in enumerate(value):
                self.check(item, schema["items"], child(path, i), errors)


def validate_file(path, validator):
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError) as e:
        return [("$", f"cannot read: {e}")]
    except json.JSONDecodeError as e:
        return [("$", f"invalid JSON: {e}")]
    errors = []
    validator.check(data, validator.root, "$", errors)
    if isinstance(data, dict) and isinstance(data.get("pois"), list):
        seen = {}
        for i, poi in enumerate(data["pois"]):
            pid = poi.get("id") if isinstance(poi, dict) else None
            if not isinstance(pid, str):
                continue
            if pid in seen:
                errors.append((f"$.pois[{i}].id", f"duplicate id {json.dumps(pid)} (first at $.pois[{seen[pid]}])"))
            else:
                seen[pid] = i
    return errors


def main(argv):
    if any(a in ("-h", "--help") for a in argv):
        print(__doc__.strip())
        return 0
    validator = Validator(json.loads(SCHEMA.read_text(encoding="utf-8")))
    files = [Path(a) for a in argv] or sorted((ROOT / "App/Wander/Resources").glob("pois-*.json"))
    if not files:
        print("validate-pois: no pois-*.json files found", file=sys.stderr)
        return 1
    failed = 0
    for f in files:
        try:
            name = f.resolve().relative_to(ROOT)
        except ValueError:
            name = f
        errors = validate_file(f, validator)
        if errors:
            failed += 1
            for p, msg in errors[:MAX_PER_FILE]:
                print(f"{name}: {p}: {msg}")
            if len(errors) > MAX_PER_FILE:
                print(f"{name}: ... and {len(errors) - MAX_PER_FILE} more problem(s)")
        else:
            count = ""
            try:
                count = f" ({len(json.loads(f.read_text(encoding='utf-8'))['pois'])} POIs)"
            except Exception:
                pass
            print(f"{name}: ok{count}")
    if validator.unsupported:
        print(f"validate-pois: schema uses keywords this validator ignores: {sorted(validator.unsupported)}",
              file=sys.stderr)
        return 1
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
