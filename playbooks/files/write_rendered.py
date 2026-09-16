#!/usr/bin/env python3
"""Writes the configuration rendered by playbooks/render_config.yml.

stdin : one JSON document per line: {"env": ..., "host": ..., "properties": {component: {...}}, "environment": {component: {...}}}
argv  : <output directory for the environment> <regular expression of secret keys>
output: <dir>/<host>/<component>.properties  (same "key=value" format as the cp-ansible templates)
        <dir>/<host>/<component>.env         (systemd Environment overrides)

All files of an environment are written by ONE process; one Ansible module run per file would make
rendering several times slower.
"""
import json
import os
import re
import sys


def main():
    out_dir, secret_pattern = sys.argv[1], re.compile(sys.argv[2])
    count = 0
    for line in sys.stdin:
        if not line.strip():
            continue
        doc = json.loads(line)
        host_dir = os.path.join(out_dir, doc["host"])
        os.makedirs(host_dir, exist_ok=True)
        for component in sorted(doc["properties"]):
            for kind, source, title in (
                ("properties", doc["properties"], "final properties"),
                ("env", doc["environment"], "systemd Environment overrides"),
            ):
                lines = [f"# {doc['env']} | {doc['host']} | {component} | {title} | rendered by playbooks/render_config.yml"]
                values = source.get(component) or {}
                for key in sorted(values):
                    value = values[key]
                    if kind == "env" and str(value) == "":
                        continue
                    lines.append(f"{key}={'<masked>' if secret_pattern.search(key) else value}")
                with open(os.path.join(host_dir, f"{component}.{kind}"), "w", encoding="utf-8") as handle:
                    handle.write("\n".join(lines) + "\n")
                count += 1
    print(f"{count} files written to {out_dir}")


if __name__ == "__main__":
    main()
