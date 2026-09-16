#!/usr/bin/env bash
# Creates the skeleton of a new environment under environments/<name>.
#
# Usage: scripts/new-env.sh <name> <tier> <topology> [domain]
#   name      lowercase letters and digits (the inventory group becomes env_<name>)
#   tier      a directory under shared/tiers       (nonprod | prod)
#   topology  a directory under shared/topologies  (single-site | stretched-2dc)
#   domain    DNS / Active Directory domain of the environment (default: <name>.internal.net)
#
# The generated files are templates: replace host names and endpoints, keep node_id values unique,
# create 90-vault.yml from 90-vault.yml.example and add the environment to the CI environment lists.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO_ROOT"

[[ $# -ge 3 && $# -le 4 ]] \
  || die "usage: $0 <name> <$(ls shared/tiers | paste -sd'|')> <$(ls shared/topologies | paste -sd'|')> [domain]"
name="$1" tier="$2" topology="$3" domain="${4:-$1.internal.net}"
[[ "$name" =~ ^[a-z][a-z0-9]*$ ]] || die "invalid environment name '$name'"
[[ -d "shared/tiers/$tier" ]] || die "unknown tier '$tier'"
[[ -d "shared/topologies/$topology" ]] || die "unknown topology '$topology'"
[[ ! -e "environments/$name" ]] || die "environments/$name already exists"

activate_venv
python3 - "$name" "$tier" "$topology" "$domain" <<'PYTHON'
import pathlib
import sys

import yaml

name, tier, topology, domain = sys.argv[1:5]
root = pathlib.Path("environments") / name
gv = root / "group_vars" / "all"
hv = root / "host_vars"
gv.mkdir(parents=True)
hv.mkdir()

# Layers 1, 2a and 2b are inherited through relative directory symlinks. The link names must not
# contain a dot: Ansible only descends into directories WITHOUT an extension.
for link, target in (("00-base", "shared/base"), ("05-tier", f"shared/tiers/{tier}"),
                     ("06-topology", f"shared/topologies/{topology}")):
    (gv / link).symlink_to(f"../../../../{target}")

base = ",".join(f"DC={part}" for part in domain.split("."))
realm = domain.upper()
host = lambda *parts: "-".join((name,) + parts) + ".internal.net"

if topology == "stretched-2dc":
    sites = {"dc1": [], "dc2": []}
    def add(site, role, number):
        fqdn = host(site, role, f"{number:02d}")
        sites[site].append(fqdn)
        return fqdn
    groups = {
        "kafka_controller": [(add("dc1", "ctrl", 1), 1), (add("dc1", "ctrl", 2), 2), (add("dc2", "ctrl", 3), 3)],
        "kafka_broker": [(add(s, "broker", i), 100 + i) for s, i in (("dc1", 1), ("dc1", 2), ("dc1", 3),
                                                                  ("dc2", 4), ("dc2", 5), ("dc2", 6))],
        "schema_registry": [(add("dc1", "sr", 1), None), (add("dc2", "sr", 2), None)],
        "kafka_connect": [(add("dc1", "connect", 1), None), (add("dc2", "connect", 2), None)],
        "kafka_rest": [(add("dc1", "rest", 1), None), (add("dc2", "rest", 2), None)],
        "control_center_next_gen": [(add("dc1", "c3", 1), None), (add("dc2", "c3", 2), None)],
    }
    title = "stretched cluster over dc1 (primary) and dc2 (secondary), KRaft quorum 2 + 1."
else:
    sites = {}
    groups = {
        "kafka_controller": [(host("ctrl", f"{i:02d}"), i) for i in (1, 2, 3)],
        "kafka_broker": [(host("broker", f"{i:02d}"), 100 + i) for i in (1, 2, 3)],
        "schema_registry": [(host("sr", "01"), None)],
        "kafka_connect": [(host("connect", "01"), None)],
        "kafka_rest": [(host("rest", "01"), None)],
        "control_center_next_gen": [(host("c3", "01"), None)],
    }
    title = "single data center."

lines = ["---", f"# {name} - {title}",
         "# node_id is PINNED per KRaft node and unique across controllers and brokers.",
         "all:", "  children:", f"    env_{name}:", "      children:"]
for group, members in groups.items():
    lines += [f"        {group}:", "          hosts:"]
    lines += [f"            {h}: {{ node_id: {i} }}" if i else f"            {h}:" for h, i in members]
for site, members in sites.items():
    lines += [f"        site_{site}:", "          hosts:"] + [f"            {h}:" for h in members]
(root / "hosts.yml").write_text("\n".join(lines) + "\n")

(gv / "10-env.yml").write_text(f"""---
# =============================================================================
# LAYER 3 - ENVIRONMENT IDENTITY: {name}
# Values that identify the environment and its endpoints. TODO: replace example values.
# =============================================================================
iac_env: {name}

# Cluster names (RBAC cluster registry, Control Center)
kafka_broker_cluster_name: cp-{name}
schema_registry_cluster_name: cp-{name}-schema-registry
kafka_connect_cluster_name: cp-{name}-connect
kafka_connect_group_id: cp-{name}-connect

# Directory services (Active Directory, LDAPS)
iac_ldap_url: ldaps://ad.{domain}:636
iac_ldap_bind_dn: "CN=ldap-bind-user,OU=ServiceAccounts,{base}"
iac_ldap_user_search_base: "OU=Users,{base}"
iac_ldap_group_search_base: "OU=Groups,{base}"
kerberos:                         # merged key by key with the baseline hardening
  realm: {realm}
  kdc_hostname: ad.{domain}
  admin_hostname: ad.{domain}

# Identity provider (OAuth). Client secrets live in 90-vault.yml.
iac_oauth_base_url: https://sso.{domain}/oauth2
iac_oauth_expected_audience: kafka-{name}
iac_oauth_client_ids:
  superuser: kafka-{name}-superuser
  schema_registry: kafka-{name}-schema-registry
  kafka_connect: kafka-{name}-connect
  kafka_rest: kafka-{name}-rest-proxy
  control_center: kafka-{name}-control-center
""")

(gv / "20-components.yml").write_text(f"""---
# =============================================================================
# LAYER 3 - ENVIRONMENT OVERRIDES: {name}
# Only what makes THIS environment different from shared/base + tier ({tier}) + topology ({topology}).
# Examples:
#   iac_kafka_broker_heap: "-Xms8g -Xmx8g"
#   kafka_broker_custom_properties:
#     log.retention.hours: 24
# =============================================================================
{{}}
""")

required = {}
for source in ("shared/base/10-security.yml", f"shared/tiers/{tier}/00-tier.yml"):
    required.update((yaml.safe_load(pathlib.Path(source).read_text()) or {}).get("iac_required_secrets") or {})
(gv / "90-vault.yml.example").write_text(f"""---
# Secrets of the "{name}" environment - TEMPLATE (files ending in .example are ignored by Ansible).
# Copy to 90-vault.yml and replace every value with an individually encrypted string:
#   ansible-vault encrypt_string --vault-id {name}@prompt --encrypt-vault-id {name} --name <variable>
""" + "".join(f"{key}: CHANGE_ME\n" for key, value in required.items() if value))

if sites:
    for site, role in (("dc1", "primary"), ("dc2", "secondary")):
        (root / "group_vars" / f"site_{site}.yml").write_text(f"""---
# LAYER 4 - SITE: {site} - {role} data center ({name})
kafka_broker_custom_properties:
  broker.rack: {site}
""")
    second_c3 = groups["control_center_next_gen"][1][0]
    (hv / f"{second_c3}.yml").write_text("""---
# LAYER 5 - HOST: second Control Center Next Gen instance (dc2), cp-ansible active-active pattern.
control_center_next_gen_custom_properties:
  confluent.controlcenter.id: 2
  confluent.controlcenter.prometheus.url: >-
    {{ control_center_next_gen_dependency_prometheus_schema }}://{{ inventory_hostname }}:{{ control_center_next_gen_dependency_prometheus_port }}
  confluent.controlcenter.alertmanager.url: >-
    {{ control_center_next_gen_dependency_alertmanager_schema }}://{{ inventory_hostname }}:{{ control_center_next_gen_dependency_alertmanager_port }}
control_center_next_gen_dependency_alertmanager_host: "{{ inventory_hostname }}"
""")
else:
    (hv / ".gitkeep").touch()
PYTHON

log "created environments/$name (tier=$tier, topology=$topology, domain=$domain)"
log "next: edit hosts.yml and 10-env.yml, create 90-vault.yml, add '$name' to the CI environment lists"
