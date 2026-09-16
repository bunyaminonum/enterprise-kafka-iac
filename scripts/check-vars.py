#!/usr/bin/env python3
"""Fail when an override variable is unknown to the pinned confluent.platform collection.

Ansible silently ignores variables nobody reads, so a typo such as `kafka_broker_custom_propertes`
would be dropped without any error. Every top-level variable defined in shared/ and in the
environment files must therefore appear somewhere in the collection (defaults, vars, tasks,
templates, plugins). Our own namespaces (iac_*, vault_*) and connection variables (ansible_*)
are exempt. The check is intentionally simple: a name that only occurs in an upstream comment
would pass, a misspelled name never does.
"""
import pathlib
import re
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
COLLECTION = ROOT / "collections" / "ansible_collections" / "confluent" / "platform"
OWN_PREFIXES = ("iac_", "vault_", "ansible_")
LAYER_LINKS = {"00-base", "05-tier", "06-topology"}


class Loader(yaml.SafeLoader):
    """SafeLoader that accepts inline vault values."""


Loader.add_constructor("!vault", lambda loader, node: "<vault>")


def known_words():
    if not COLLECTION.is_dir():
        sys.exit(f"error: {COLLECTION} not found - run scripts/bootstrap.sh first")
    words = set()
    for sub in ("roles", "playbooks", "plugins"):
        for path in (COLLECTION / sub).rglob("*"):
            if path.is_file() and path.suffix in {".yml", ".yaml", ".j2", ".py"}:
                words.update(re.findall(r"[A-Za-z_][A-Za-z0-9_]*", path.read_text(errors="ignore")))
    return words


def variable_files():
    yield from sorted((ROOT / "shared").rglob("*.yml"))
    for path in sorted((ROOT / "environments").rglob("*.yml")):
        relative = path.relative_to(ROOT / "environments")
        if path.name != "hosts.yml" and not LAYER_LINKS.intersection(relative.parts):
            yield path


def main():
    words = known_words()
    problems = []
    for path in variable_files():
        data = yaml.load(path.read_text(), Loader=Loader) or {}
        if not isinstance(data, dict):
            problems.append(f"{path.relative_to(ROOT)}: top level must be a mapping")
            continue
        for name in data:
            if path.name.startswith("90-vault") and not name.startswith("vault_"):
                problems.append(f"{path.relative_to(ROOT)}: '{name}' - vault files may only define vault_* variables")
            elif not name.startswith(OWN_PREFIXES) and name not in words:
                problems.append(f"{path.relative_to(ROOT)}: '{name}' is not used by confluent.platform (typo?)")
    for problem in problems:
        print(f"error: {problem}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
