"""Render private native configs from shell variables sent over a NUL-delimited pipe."""
import json
from pathlib import Path
import re
import sys

FIELD = re.compile(r"\$\{([A-Z][A-Z0-9_]*)\}")
JSON_STRING = re.compile(r'"(?:[^"\\]|\\.)*"')


def main(source, target):
    fields = sys.stdin.buffer.read().decode().split("\0")[:-1]
    values = dict(zip(fields[::2], fields[1::2]))
    text = source.read_text()
    if source.name.endswith((".json.tpl", ".toml.tpl")):
        def render_string(match):
            # JSON escaping is valid in the TOML basic strings used by these templates.
            literal = match[0]
            return FIELD.sub(lambda m: json.dumps(values[m[1]], ensure_ascii=False)[1:-1], literal)
        pattern = re.compile(f"({JSON_STRING.pattern})|({FIELD.pattern})")
        def render_token(match):
            if match[0].startswith('"'):
                return render_string(match)
            return values[FIELD.fullmatch(match[0])[1]]
        text = pattern.sub(render_token, text)
    elif source.name == "patroni.yml.tpl":
        text = FIELD.sub(lambda m: json.dumps(values[m[1]]) if m[1].endswith("_PASSWORD") else values[m[1]], text)
    elif source.name == "docker-compose.yml.tpl":
        def compose_value(match):
            if match[1] == "SWFS_ADMIN_PASSWORD":
                return json.dumps("-adminPassword=" + values[match[1]].replace("$", "$$"))
            return values[match[1]]
        text = FIELD.sub(compose_value, text)
    else:
        text = FIELD.sub(lambda m: values[m[1]], text)
    target.write_text(text)


if __name__ == "__main__":
    main(*map(Path, sys.argv[1:]))
