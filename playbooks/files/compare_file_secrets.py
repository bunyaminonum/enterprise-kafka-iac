#!/usr/bin/env python3
"""Compares the FileConfigProvider secret files with the configuration the services run with right now.

Run by playbooks/file_secrets.yml (-e iac_file_secrets_verify=true) BEFORE the properties files are switched
to ${file:...} references: every value in a secret file must equal the value the service reads today, either
decrypted from its ${securepass:...} reference (Confluent CLI, master key from the service's override.conf)
or in plain text. Prints key names and verdicts only, never values.

argv  : [--cli <confluent CLI>] --component <name>,<properties file>,<Secret Protection file>,<override.conf>,<secret file> ...
exit  : 0 every value is equal, 1 at least one difference, 2 runtime error
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

MASTER_KEY = re.compile(r'CONFLUENT_SECURITY_MASTER_KEY=([^"\s]+)')
ESCAPES = {"t": "\t", "n": "\n", "r": "\r", "f": "\f"}


def unescape(text):
    out, i = [], 0
    while i < len(text):
        char = text[i]
        if char == "\\" and i + 1 < len(text):
            nxt = text[i + 1]
            if nxt == "u" and i + 5 < len(text):
                out.append(chr(int(text[i + 2:i + 6], 16)))
                i += 6
                continue
            out.append(ESCAPES.get(nxt, nxt))
            i += 2
            continue
        out.append(char)
        i += 1
    return "".join(out)


def load_properties(path):
    """java.util.Properties semantics (comments, separators, escapes, continuation lines)."""
    with open(path, encoding="utf-8") as handle:
        physical = handle.read().splitlines()
    logical, buffer = [], None
    for raw in physical:
        line = raw.lstrip(" \t\f")
        if buffer is None and (not line or line[0] in "#!"):
            continue
        trailing = len(line) - len(line.rstrip("\\"))
        if trailing % 2 == 1:
            buffer = (buffer or "") + line[:-1]
            continue
        logical.append((buffer or "") + line)
        buffer = None
    if buffer is not None:
        logical.append(buffer)
    props = {}
    for line in logical:
        i = 0
        while i < len(line) and line[i] not in "=: \t\f":
            i += 2 if line[i] == "\\" else 1
        key = line[:i]
        while i < len(line) and line[i] in " \t\f":
            i += 1
        if i < len(line) and line[i] in "=:":
            i += 1
        while i < len(line) and line[i] in " \t\f":
            i += 1
        props[unescape(key)] = unescape(line[i:])
    return props


def decrypt(cli, config, sp_file, override):
    """Decrypted ${securepass:...} values of a copy of <config> (the live files are never touched)."""
    if not os.path.isfile(override):
        raise RuntimeError(f"{override} not found (master key)")
    with open(override, encoding="utf-8") as handle:
        match = MASTER_KEY.search(handle.read())
    if not match:
        raise RuntimeError(f"no CONFLUENT_SECURITY_MASTER_KEY in {override}")
    with tempfile.TemporaryDirectory() as tmp:
        # the secret keys are named <config file name>/<key>, so the copy keeps the file name
        copy = os.path.join(tmp, os.path.basename(config))
        secrets = os.path.join(tmp, "secrets.properties")
        output = os.path.join(tmp, "decrypted.properties")
        shutil.copyfile(config, copy)
        shutil.copyfile(sp_file, secrets)
        run = subprocess.run(
            [cli, "secret", "file", "decrypt", "--config-file", copy,
             "--local-secrets-file", secrets, "--output-file", output],
            env=dict(os.environ, CONFLUENT_SECURITY_MASTER_KEY=match.group(1)),
            capture_output=True, text=True, check=False)
        if run.returncode != 0 or not os.path.isfile(output):
            raise RuntimeError(f"confluent secret file decrypt failed (exit {run.returncode})")
        # CLI output: "<key> = <value>" per decrypted key, values unescaped
        values = {}
        with open(output, encoding="utf-8") as handle:
            for line in handle.read().splitlines():
                key, sep, value = line.partition(" = ")
                if sep:
                    values[key] = value
        return values


def compare(cli, name, config, sp_file, override, secret_file):
    if not os.path.isfile(secret_file):
        return [f"{name}: ERROR {secret_file} not found"], 1
    if not os.path.isfile(config):
        return [f"{name}: ERROR {config} not found"], 1
    ours = load_properties(secret_file)
    current = load_properties(config)
    encrypted = sorted(k for k, v in current.items() if v.startswith("${securepass:"))
    migrated = sorted(k for k, v in current.items() if v.startswith("${file:"))
    if migrated and not encrypted:
        return [f"{name}: SKIPPED {config} already uses ${{file:...}} references"], 0
    decrypted = decrypt(cli, config, sp_file, override) if encrypted else {}
    problems, equal = [], 0
    for key in sorted(ours):
        if key in encrypted:
            running = decrypted.get(key)
        else:
            running = current.get(key)
        if running is None:
            problems.append(f"  MISSING    {key} (not in the running configuration)")
        elif running != ours[key]:
            problems.append(f"  DIFFERENT  {key}")
        else:
            equal += 1
    for key in encrypted:
        if key not in ours:
            problems.append(f"  UNCOVERED  {key} (encrypted today, not in the secret file)")
    from_secret_protection = sum(1 for key in ours if key in encrypted)
    source = f"{from_secret_protection} Secret Protection, {len(ours) - from_secret_protection} plain text"
    lines = [f"{name}: {equal}/{len(ours)} equal ({source})"] + problems
    return lines, 1 if problems else 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", default="/usr/local/bin/confluent")
    parser.add_argument("--component", action="append", required=True)
    args = parser.parse_args()
    status = 0
    for spec in args.component:
        parts = spec.split(",")
        if len(parts) != 5:
            print(f"invalid --component {spec}", file=sys.stderr)
            return 2
        try:
            lines, result = compare(args.cli, *parts)
        except (OSError, RuntimeError) as error:
            lines, result = [f"{parts[0]}: ERROR {error}"], 2
        print("\n".join(lines))
        status = max(status, result)
    return status


if __name__ == "__main__":
    sys.exit(main())
