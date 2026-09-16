# enterprise-kafka-iac

Multi-environment deployment repository for **Confluent Platform 8.3 (KRaft)**, built on the official
cp-ansible collection **`confluent.platform` v8.3.1**. The collection is consumed as a pinned dependency
and is never forked or edited.

Seven environments — `dev100`, `dev`, `test`, `qa`, `preprod`, `production`, `dr` — share one baseline,
and every component (KRaft controllers, brokers, Schema Registry, Kafka Connect, REST Proxy,
Control Center Next Gen) can be overridden per environment, per data center and per host.

> **Status: reference implementation.** Host names, endpoints, accounts and sizing are placeholders
> (`internal.net`, `lab.local`, `TODO` markers). Open design questions are tracked in
> [docs/OPEN-DECISIONS.md](docs/OPEN-DECISIONS.md), upstream behaviours this repository compensates for in
> [docs/UPSTREAM-NOTES.md](docs/UPSTREAM-NOTES.md), and the changes from the previous layout in
> [docs/MIGRATION.md](docs/MIGRATION.md).

---

## Contents

1. [How overrides work](#how-overrides-work)
2. [Environments](#environments)
3. [Repository layout](#repository-layout)
4. [Getting started](#getting-started)
5. [Day-to-day operations](#day-to-day-operations)
6. [Where does a change go?](#where-does-a-change-go)
7. [Guard rails](#guard-rails)
8. [CI/CD](#cicd)
9. [Upgrading cp-ansible](#upgrading-cp-ansible)

---

## How overrides work

The design uses nothing but standard Ansible variable precedence plus `hash_behaviour = merge`
(which cp-ansible requires anyway, see `ansible.cfg`).

| Layer | What | Where | Scope |
|---|---|---|---|
| 0 | cp-ansible defaults | `confluent.platform` roles | upstream, never edited |
| 1 | Organisation baseline | `shared/base/` (linked as `group_vars/all/00-base`) | every environment |
| 2a | Tier | `shared/tiers/{nonprod,prod}/` (linked as `05-tier`) | class of environment |
| 2b | Topology | `shared/topologies/{single-site,stretched-2dc}/` (linked as `06-topology`) | shape of the cluster |
| 3 | Environment | `environments/<env>/group_vars/all/10-env.yml`, `20-components.yml`, `90-vault.yml` | one environment |
| 4 | Site | `environments/<env>/group_vars/site_<code>.yml` | one data center of a stretched cluster |
| 5 | Host | `environments/<env>/hosts.yml`, `environments/<env>/host_vars/<host>.yml` | one server |

Each shared layer is ONE directory symlink, so the order is fixed no matter how many files a layer contains:
Ansible reads the entries of `group_vars/all/` in lexical order (the linked directories recursively) and
later entries win. With `hash_behaviour = merge`:

- **dictionaries are merged key by key** — `kafka_broker_custom_properties`,
  `*_service_environment_overrides`, `kerberos`, `iac_required_secrets`, ... A lower layer changes single
  keys and keeps everything else, including the upstream defaults.
- **scalars and lists are replaced** — values that layers are expected to tune are exposed by the baseline
  as `iac_*` parameters (for example `iac_kafka_broker_heap`) and consumed inside the dictionaries.

Tier and topology are deliberately separate axes: `dr` is a *prod*-tier environment but a *single-site*
cluster with three brokers, so replication settings for two data centers cannot live in the prod tier.
Sharing the `stretched-2dc` topology guarantees that `preprod` keeps the production topology.

### Example: where the values of one production broker come from

Taken from `build/rendered/production/prod-dc2-broker-04.internal.net/` (see
[Rendering](#render-the-effective-configuration)):

| Final value | Source |
|---|---|
| `log.dirs=/var/lib/kafka/data` | layer 1 — `shared/base/31-kafka-broker.yml` |
| `ldap.java.naming.provider.url=ldaps://ad.prod.internal.net:636` | layer 1 (`10-security.yml`) using `iac_ldap_url` from layer 3 |
| `log.retention.hours=168`, `KAFKA_HEAP_OPTS=-Xms6g -Xmx6g ...` | layer 2a — `shared/tiers/prod/00-tier.yml` |
| `default.replication.factor=4`, `offsets.topic.replication.factor=4`, `confluent.metadata.topic.replication.factor=4`, `replica.selector.class=...RackAwareReplicaSelector` | layer 2b — `shared/topologies/stretched-2dc/` |
| `broker.rack=dc2` | layer 4 — `environments/production/group_vars/site_dc2.yml` |
| `node.id=104` | layer 5 — `environments/production/hosts.yml` |
| `KAFKA_OPTS=... -javaagent:...jmx_prometheus_javaagent.jar...`, `LOG_DIR`, `KAFKA_LOG4J_OPTS` | layer 0 — kept by the merge |

An environment override looks like `environments/dev100/group_vars/all/20-components.yml`
(`log.retention.hours: 12` instead of the tier's 72).

### Rules

1. **Never edit the collection.** Pin it in `collections/requirements.yml` and override through variables.
2. **Put a value in the highest layer where it is true** for everything below it. An environment file only
   contains what makes that environment different.
3. **Component variables live at the `all` level** (shared layers and `group_vars/all`). Group-scoped files
   are only for values that are local to those hosts (site: `broker.rack`; host: the second Control Center
   instance). Never scope listeners or security settings to a component group — other components read them
   from their own host context.
4. **Use the cp-ansible extension points**: `<component>_custom_properties`,
   `<component>_service_environment_overrides`, `<component>_custom_java_args`, `<component>_copy_files`, ...
5. **Anything a lower layer may extend must be a dictionary** (see `iac_required_secrets`).
6. **Own variables use the `iac_` prefix, secrets the `vault_` prefix** (`cp_*` names are used by the
   collection itself). Every other variable must be known to the pinned collection —
   `scripts/check-vars.py` rejects typos, which Ansible would otherwise ignore silently.
7. **Layer link names contain no dot** (`00-base`, not `00-base.yml`): Ansible only descends into
   directories without an extension.
8. **`node_id` is pinned in `hosts.yml`**, unique across controllers and brokers, and controllers run on
   dedicated hosts (cp-ansible uses the same `node_id` host variable for both roles).

## Environments

| Environment | Role | Tier | Topology | Controllers | Brokers | Schema Registry | Connect | REST Proxy | Control Center | Protected |
|---|---|---|---|---|---|---|---|---|---|---|
| `dev100` | Platform sandbox | nonprod | single-site | 3 | 3 | 1 | 1 | 1 | 1 | no |
| `dev` | Shared engineering | nonprod | single-site | 3 | 3 | 1 | 1 | 1 | 1 | no |
| `test` | Integration testing | nonprod | single-site | 3 | 3 | 1 | 1 | 1 | 1 | no |
| `qa` | Performance / acceptance | nonprod | single-site | 3 | 3 | 2 | 2 | 2 | 1 | no |
| `preprod` | Production mirror | prod | stretched-2dc | 2 + 1 | 3 + 3 | 1 + 1 | 1 + 1 | 1 + 1 | 1 + 1 | yes |
| `production` | Core streaming | prod | stretched-2dc | 2 + 1 | 3 + 3 | 1 + 1 | 2 + 2 | 1 + 1 | 1 + 1 | yes |
| `dr` | Disaster recovery | prod | single-site | 3 | 3 | 1 | 2 | 1 | 1 | yes |

`dr` is an independent cluster with its own KRaft quorum, fed by Cluster Linking. Replication is never lowered
below 3 / `min.insync.replicas=2` in any environment; stretched clusters use 4 (2 per data center).

## Repository layout

```text
.
├── ansible.cfg                      # hash_behaviour=merge, pinned collections path, YAML output, no default inventory
├── requirements.txt                 # control node Python dependencies (ansible-core 2.18)
├── requirements-dev.txt             # + yamllint, ansible-lint (pinned)
├── collections/requirements.yml     # pinned confluent.platform 8.3.1 (+ ansible.posix, community.general)
├── shared/
│   ├── base/                        # layer 1: platform, security, observability, one file per component
│   ├── tiers/{nonprod,prod}/        # layer 2a: heaps, retention, license requirement
│   └── topologies/{single-site,stretched-2dc}/   # layer 2b: replication, rack awareness, C3 per site
├── environments/<env>/
│   ├── hosts.yml                    # topology, pinned node_id, env and site groups
│   ├── group_vars/all/
│   │   ├── 00-base -> ../../../../shared/base
│   │   ├── 05-tier -> ../../../../shared/tiers/<tier>
│   │   ├── 06-topology -> ../../../../shared/topologies/<topology>
│   │   ├── 10-env.yml               # identity and endpoints of the environment
│   │   ├── 20-components.yml        # component overrides of the environment
│   │   └── 90-vault.yml.example     # template of the secrets file
│   ├── group_vars/site_<code>.yml   # stretched environments only (broker.rack)
│   └── host_vars/                   # host specific values
├── playbooks/
│   ├── site.yml                     # preflight + confluent.platform.all
│   ├── health_check.yml, restart.yml, validate_hosts.yml, support_bundle.yml
│   ├── preflight.yml                # guard rails
│   ├── render_config.yml            # effective configuration without touching hosts
│   └── tasks/, files/               # helpers
├── scripts/
│   ├── bootstrap.sh                 # virtualenv + pinned collections
│   ├── run.sh                       # the only way to run a playbook against an environment
│   ├── validate.sh                  # static validation (CI)
│   ├── render-config.sh             # effective configuration -> build/rendered
│   ├── config-diff.sh               # "plan": effective configuration diff between two revisions
│   ├── check-vars.py                # rejects unknown override variables
│   └── new-env.sh                   # scaffolds a new environment
├── .github/                         # GitHub Actions workflows, CODEOWNERS
├── bitbucket-pipelines.yml          # Bitbucket Pipelines equivalent
└── docs/                            # open decisions, upstream notes, migration notes
```

## Getting started

### Prerequisites

- Linux control node (developer machine or CI runner) with **Python 3.11 or newer** (required by
  ansible-core 2.18; on RHEL 9 install `python3.12` and run `PYTHON=python3.12 scripts/bootstrap.sh`).
- Git with symlink support. On Windows use WSL or `git config core.symlinks true`; without it the layer links
  are checked out as plain files and preflight stops.
- Access to Nexus: PyPI proxy, a raw repository with the collection tarballs, a mirror/proxy of
  `https://packages.confluent.io` and of the Confluent CLI (see `shared/base/00-platform.yml`).
- SSH access and privilege escalation (`sudo`) on the managed hosts, their host keys in `known_hosts`.

### Publish the collections to Nexus (once per version)

From a machine with internet access:

```bash
git clone --branch v8.3.1 --depth 1 https://github.com/confluentinc/cp-ansible.git
ansible-galaxy collection build cp-ansible                       # -> confluent-platform-8.3.1.tar.gz
ansible-galaxy collection download ansible.posix:2.1.0 community.general:12.6.5 -p ./collections-download
# upload the three tarballs to the Nexus raw repository referenced in collections/requirements.yml
```

### Bootstrap the control node

```bash
export PIP_INDEX_URL=https://nexus.internal.net/repository/pypi-proxy/simple   # air-gapped
scripts/bootstrap.sh --dev      # .venv, Python requirements, linters and the pinned collections
scripts/validate.sh             # lint, variable names, syntax, preflight (static) and rendering of all environments
```

### Secrets

- **One vault identity per environment**, named like the environment. `ansible.cfg` sets
  `vault_id_match = True`, so a value is only decrypted with its own identity.
- **Encrypt values, not files.** Copy `90-vault.yml.example` to `90-vault.yml` and replace each value with the
  output of:

  ```bash
  ansible-vault encrypt_string --vault-id production@prompt --encrypt-vault-id production \
    --name vault_mds_super_user_password
  ```

  Variable names stay reviewable in pull requests, and validation/rendering run without any vault password:
  encrypted values are only decrypted when used, and static validation replaces them with placeholders.
- **Every secret is registered** in `iac_required_secrets` (`shared/base/10-security.yml`; the prod tier adds
  `vault_confluent_license`, `dr` adds `vault_password_encoder_secret`). Preflight refuses to deploy while a
  registered secret is missing or still `CHANGE_ME`.
- **Secret Protection** encrypts the passwords that cp-ansible writes into the properties files. Create the
  master key and the security file once per environment with the Confluent CLI:

  ```bash
  openssl rand -base64 24 > passphrase.txt
  confluent secret master-key generate --local-secrets-file security.properties --passphrase @passphrase.txt
  # store the printed master key as vault_secrets_protection_masterkey (encrypt_string, see above)
  # store security.properties and the passphrase in the secret store of the environment
  ```

- **Control node secret files.** cp-ansible reads these files on the control node and copies them to the
  hosts. Provide them in `$IAC_SECRETS_DIR` (default `.secrets/<environment>`, git-ignored):
  `kafka-<inventory_hostname>.keytab` for every controller and broker, and `security.properties`.
  Preflight checks that all of them exist.
- **Host TLS certificates are expected on the hosts** (`ssl_custom_certs_remote_src: true`, paths under
  `/var/ssl/private/`). The identity provider CA certificate (`iac_control_node_ca_cert`) is read from the
  control node.

## Day-to-day operations

All runs go through `scripts/run.sh <environment> <playbook> [ansible-playbook arguments]`.

```bash
scripts/run.sh dev100 site                                   # deploy or reconfigure an environment
scripts/run.sh dev100 site --tags kafka_broker               # one component
scripts/run.sh qa health_check                               # read-only checks
scripts/run.sh dr support_bundle                             # diagnostics archive
CONFIRM_ENV=production scripts/run.sh production restart --limit site_dc2   # protected environment, one site
ANSIBLE_VAULT_IDENTITY_LIST=preprod@prompt CONFIRM_ENV=preprod scripts/run.sh preprod site --tags kafka_connect
```

`run.sh` accepts secrets and options through environment variables (`ANSIBLE_VAULT_PASSWORD`,
`ANSIBLE_SSH_PRIVATE_KEY`, `SSH_KNOWN_HOSTS`, `CONFIRM_ENV`, `PLAYBOOK_TAGS`, `PLAYBOOK_LIMIT`,
`IAC_SECRETS_DIR`, `IAC_SUPPORT_BUNDLE_DIR`, `AUTO_SUPPORT_BUNDLE`). Secrets are exported instead of being
passed as CLI flags because the support bundle callback starts a new `ansible-playbook` process that only
inherits the environment. When a run fails, that callback collects a support bundle automatically; disable it
with `AUTO_SUPPORT_BUNDLE=false`. `run.sh` executes the guard rails first in a separate process without that
callback, so a refused run never starts collecting diagnostics from the hosts.

`deployment_strategy: rolling` provisions running hosts one at a time through the upstream playbooks.
Upstream warns that rolling can fail while security modes are being changed; use
`-e deployment_strategy=parallel` for such runs.

### Render the effective configuration

```bash
scripts/render-config.sh production          # -> build/rendered/production/<host>/<component>.{properties,env}
scripts/render-config.sh                     # all environments
scripts/config-diff.sh origin/main           # what would change, per host, compared with main
scripts/config-diff.sh origin/main production dr    # limited to some environments
```

Rendering evaluates exactly the variables cp-ansible uses to template `server.properties` and the systemd
overrides, without connecting to any host and without a vault password. Secret-looking keys are masked.

### Add an environment

```bash
scripts/new-env.sh perf nonprod single-site perf.internal.net
# edit environments/perf/hosts.yml and 10-env.yml, create 90-vault.yml, add 'perf' to the CI environment lists
```

## Where does a change go?

| Change | File |
|---|---|
| A broker property for one environment | `environments/<env>/group_vars/all/20-components.yml` → `kafka_broker_custom_properties` |
| The same property for every environment | `shared/base/31-kafka-broker.yml` |
| A property for all production-like environments | `shared/tiers/prod/00-tier.yml` |
| Anything that depends on two data centers | `shared/topologies/stretched-2dc/` |
| Heap of a component | `iac_<component>_heap` (base → tier → environment) |
| A value for one data center | `environments/<env>/group_vars/site_<code>.yml` |
| A value for one server | `environments/<env>/host_vars/<host>.yml` |
| A new secret | `vault_<name>` in every affected `90-vault.yml` + entry in `iac_required_secrets` |
| Corporate CA rotation | new files on the hosts (`/var/ssl/private/`) and on the runners (`iac_control_node_ca_cert`), then `site` |
| Package, Java or collection versions | `shared/base/00-platform.yml`, `collections/requirements.yml` |

## Guard rails

`playbooks/preflight.yml` runs before every changing playbook and never touches the hosts:

- `hash_behaviour` is `merge` and the installed collection equals `iac_cp_ansible_version`;
- protected environments (`preprod`, `production`, `dr`) require `-e confirm_env=<environment>`;
- every host belongs to `env_<environment>`, the inventory directory matches `iac_env`, all layers are loaded;
- KRaft: odd number (≥ 3) of dedicated controllers, pinned and unique `node_id`, enough brokers for the
  internal replication factor;
- topology: stretched hosts belong to exactly one site, both sites host controllers, `broker.rack` matches
  the site; single-site environments have no site groups;
- deploy mode: registered secrets are set, the MDS super user password is not the upstream default, keytabs
  and the Secret Protection security file exist, the master key is never regenerated implicitly, secret
  masking is on in protected environments.

`scripts/validate.sh` adds linting, the variable-name check, syntax checks and rendering for every environment.

## CI/CD

The pipelines are thin wrappers around `scripts/`, so GitHub Actions and Bitbucket Pipelines behave the same.
Both expect **self-hosted Linux runners inside the corporate network** (Nexus and host access) labelled
`kafka-iac`. On an air-gapped GitHub Enterprise Server, make sure `actions/checkout` and
`actions/upload-artifact` are available.

| Trigger | GitHub Actions | Bitbucket Pipelines |
|---|---|---|
| Pull request | `validate.yml`: validation + effective configuration diff in the job summary | `pull-requests`: validation + `build/config-diff.patch` artifact |
| Push to main | `validate.yml` | `branches.main` |
| Operation on an environment | `deploy.yml` (manual, environment/operation/confirmation/tags/limit inputs) | `custom.<environment>` (manual, same inputs as variables) |
| Approvals | GitHub Environments: required reviewers, main only | Deployment environments: deployment permissions, main only |
| Secrets | Environment secrets `ANSIBLE_VAULT_PASSWORD`, `ANSIBLE_SSH_PRIVATE_KEY`; variable `SSH_KNOWN_HOSTS` | Deployment variables with the same names |
| Concurrency | one run per environment (`concurrency` group) | deployment concurrency control of deployment environments |

Fetching keytabs and `security.properties` from the secret store is left as a marked step in both pipelines
(OD-04). `.github/CODEOWNERS` requires platform leads for `preprod`, `production`, `dr` and architects for
`shared/`.

## Upgrading cp-ansible

1. Publish the new collection tarball to Nexus.
2. In one pull request change `collections/requirements.yml` **and** `iac_cp_ansible_version`
   (`shared/base/00-platform.yml`); preflight fails if they differ.
3. Read the pull request's effective configuration diff: it shows, per host, every property the new
   collection version changes in every environment.
4. Roll out environment by environment: `dev100` → `dev` → `test` → `qa` → `preprod` → `production` / `dr`.
