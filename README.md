# Architectural Specification: Enterprise Confluent Platform Orchestrator

## 1. Executive Summary & Design Motivation

Deploying Confluent Platform across enterprise environments introduces significant operational and governance challenges. In multi-cluster organizations, infrastructure automation frequently degenerates into one of two dangerous architectural anti-patterns:

1. **The Monolithic Inventory Trap:** Maintaining a single, multi-thousand-line `hosts.yml` that aggregates all environments. Any syntax error, variable collision, or unintended flag during execution exposes production systems to accidental modification.
2. **The Copy-Paste Proliferation Anti-Pattern:** Forking upstream Ansible roles or cloning entire directories per environment (`dev/`, `test/`, `prod/`). When upstream updates occur (e.g., upgrading from Confluent Platform 8.3.0 to 8.3.1), administrators must manually reconcile changes across dozens of detached files, causing configuration drift and operational debt.

This repository implements a **Decoupled Orchestration Architecture**. It separates the immutable upstream execution engine (`cp-ansible 8.3.1`) from environment configuration state.

By combining **inventory-adjacent variable resolution**, **deterministic symlink layering**, and **deep dictionary merging (`hash_behaviour = merge`)**, this architecture guarantees:

* **Zero Upstream Modifications (DRY Principle):** The official Confluent collection is consumed as an external immutable dependency.
* **Hermetic Environment Isolation:** Each of the seven environments (`dev100`, `dev`, `test`, `qa`, `preprod`, `production`, `dr`) is a self-contained execution boundary.
* **Audit-Compliant Credential Masking:** Eliminates plaintext passwords on disk by integrating Apache Kafka’s `FileConfigProvider`.
* **Dynamic Topology & Quorum Resolution:** Prevents KRaft quorum collapse caused by static host indexing.

---

## 2. Structural Taxonomy & Repository Blueprint

The directory layout enforces a strict unidirectional dependency flow: **Universal Baseline $\rightarrow$ Hardware Tier Profile $\rightarrow$ Geographic Topology $\rightarrow$ Environment Identity $\rightarrow$ Local Overrides**.

```text
enterprise-kafka-iac/
├── ansible.cfg                          # Engine settings: collection paths, merge behaviour, strict callbacks
├── collections/
│   └── requirements.yml                 # Pinned upstream version (confluent.platform: 8.3.1)
├── shared/                              # Single Source of Truth (SSOT) architectural modules
│   ├── base/                            # Universal platform baseline applied across all clusters
│   │   ├── 00-global.yml                # Confluent package versions, archive extraction roots, dynamic voters
│   │   ├── 10-security.yml              # TLS paths, Kerberos realms/ciphers, isolated dual listeners
│   │   ├── 20-identity-ldap.yml         # RBAC authorizer chaining, OpenLDAP/Active Directory query filters
│   │   ├── 25-file-config-provider.yml  # Kafka runtime variable substitution rules (${file:...})
│   │   ├── 30-observability.yml         # Standardized Prometheus JMX Exporter ports (7071–7075)
│   │   └── 35-performance.yml           # TCP network buffers, thread pools, broker IO limits
│   ├── tiers/                           # Hardware profiles & JVM sizing policies
│   │   ├── nonprod/05-sizing.yml        # Constrained environments: 1G-3G JVM heaps
│   │   └── prod/05-sizing.yml           # High-throughput environments: 16G G1GC heaps, paused-tuned
│   └── topologies/                      # Fault tolerance & replication profiles
│       ├── single-site/06-replication.yml    # Standard topologies (RF: 1 or 3, Min ISR: 1 or 2)
│       └── stretched-2dc/06-replication.yml  # Multi-datacenter topologies (RF: 4, Min ISR: 2, Balancer enabled)
├── environments/                        # Isolated execution boundaries per environment
│   ├── dev100/                          # Local sandbox / active validation cluster
│   │   ├── hosts.yml                    # Concrete host mappings, node IDs, and connection adapters
│   │   └── group_vars/all/              # Deterministic evaluation chain (ASCII-ordered symlinks & files):
│   │       ├── 00-base.yml              -> ../../../../shared/base/00-global.yml
│   │       ├── 05-tier.yml              -> ../../../../shared/tiers/nonprod/05-sizing.yml
│   │       ├── 06-topology.yml          -> ../../../../shared/topologies/single-site/06-replication.yml
│   │       ├── 10-env.yml               # Cluster network domain, Kerberos KDC, and cluster names
│   │       ├── 10-security.yml          -> ../../../../shared/base/10-security.yml
│   │       ├── 20-identity-ldap.yml     -> ../../../../shared/base/20-identity-ldap.yml
│   │       ├── 25-file-config-provider.yml -> ../../../../shared/base/25-file-config-provider.yml
│   │       ├── 30-observability.yml     -> ../../../../shared/base/30-observability.yml
│   │       ├── 35-performance.yml       -> ../../../../shared/base/35-performance.yml
│   │       ├── 90-vault.yml             # Encrypted credentials for MDS, LDAP, and services
│   │       └── 95-overrides.yml         # Environment-specific exceptions (highest precedence)
│   ├── dev/
│   ├── test/
│   ├── qa/
│   ├── preprod/
│   ├── production/
│   └── dr/
└── playbooks/
    ├── 00_distribute_secrets.yml        # Provisions /var/ssl/private/security.properties (chmod 0600)
    ├── 00_preflight.yml                 # Guardrail validating node_ids and aborting unconfirmed prod executions
    ├── 01_deploy_cluster.yml            # Multi-tier Confluent Platform deployment sequence
    └── 02_health_check.yml              # Systemd daemon inspection across controllers, brokers, and apps

```

---

## 3. The Layered Variable Engine & Deterministic Precedence

### Inventory-Adjacent Variable Scoping

Ansible natively inspects the filesystem relative to the target inventory passed via the `-i` flag. When issuing:

```bash
ansible-playbook -i environments/production/hosts.yml playbooks/01_deploy_cluster.yml

```

Ansible binds its runtime context to `environments/production/`. It detects the `group_vars/all/` directory and loads every file inside it for all hosts in the inventory.

### ASCII Evaluation Hierarchy

Ansible parses files inside `group_vars/all/` in strict ASCII lexical order. We use zero-padded numeric prefixes to build an immutable inheritance pipeline:

```text
[00-base.yml] ──► [05-tier.yml] ──► [06-topology.yml] ──► [10-env.yml] ──► [10..35 Features] ──► [90-vault.yml] ──► [95-overrides.yml]
  (Baseline)        (Hardware)       (Replication)        (Endpoints)       (Security/LDAP)         (Secrets)           (Final Say)

```

### Deep Merging in Action (`hash_behaviour = merge`)

Under default Ansible settings (`hash_behaviour = replace`), defining a key in a later file discards the entire parent dictionary. Because `cp-ansible` relies on large configuration dictionaries like `kafka_broker_custom_properties`, replacing dictionaries breaks the platform.

With `hash_behaviour = merge`, Ansible retains every preceding key-value pair and overrides only identical keys.

#### Concrete Evaluation Trace for `kafka_broker_custom_properties`:

1. **`06-topology.yml` (from `shared/topologies/stretched-2dc/`):**
```yaml
kafka_broker_custom_properties:
  default.replication.factor: 3
  offsets.topic.replication.factor: 4
  log.retention.hours: 168

```


2. **`35-performance.yml` (from `shared/base/`):**
```yaml
kafka_broker_custom_properties:
  num.network.threads: 12
  message.max.bytes: 33554816

```


3. **`95-overrides.yml` (local to `dev100`):**
```yaml
kafka_broker_custom_properties:
  log.retention.hours: 12

```



**Final Resolved State on Managed Host:**

```yaml
kafka_broker_custom_properties:
  default.replication.factor: 3          # Inherited from 06-topology.yml
  offsets.topic.replication.factor: 4    # Inherited from 06-topology.yml
  num.network.threads: 12                # Inherited from 35-performance.yml
  message.max.bytes: 33554816            # Inherited from 35-performance.yml
  log.retention.hours: 12                # Successfully overridden by 95-overrides.yml

```

---

## 4. Enterprise Security & Governance Architecture

### Dual-Listener Network Segregation

To satisfy strict network isolation policies, cluster traffic is partitioned into two distinct security protocols:

```text
                      [ External Client Applications ]
                                     │  (SASL_SSL / OAUTHBEARER)
                                     ▼
                  ┌─────────────────────────────────────┐
                  │   Kafka Broker (Port 9092: INTERNAL)│
                  │   - Auth: OAuth / LDAP Tokens       │
                  │   - Authorizer: Confluent MDS RBAC  │
                  └──────────────────┬──────────────────┘
                                     │
                                     │  (SASL_SSL / Kerberos GSSAPI)
                                     │  Private Infrastructure Network
                                     ▼
                  ┌─────────────────────────────────────┐
                  │   Kafka Broker (Port 9091: BROKER)  │
                  │   KRaft Controller (Port 9093)      │
                  └─────────────────────────────────────┘

```

* **Client / Application Tier (`INTERNAL`, Port 9092):** Listens for external application traffic. It enforces `SASL_SSL` using `OAUTHBEARER` tokens validated against Confluent Metadata Service (MDS) and directory infrastructure.
* **Control Plane / Inter-Broker Tier (`BROKER`, Port 9091):** Dedicated exclusively to replication and consensus traffic. It enforces `SASL_SSL` with mutual Kerberos (`GSSAPI`) machine authentication. External applications cannot reach this listener.

### Audit-Compliant Credential Masking (`FileConfigProvider`)

Standard automation often writes LDAP bind passwords and service credentials in plaintext into `/etc/kafka/server.properties`. If an unauthorized process or user reads this configuration, enterprise directory credentials are compromised.

This architecture eliminates plaintext secrets on disk:

```text
Step 1: Playbook Execution (00_distribute_secrets.yml)
   Vault File (90-vault.yml) ──► Target Node: /var/ssl/private/security.properties (chmod 0600, root:root)

Step 2: Component Configuration Injection (server.properties)
   config.providers=file
   config.providers.file.class=org.apache.kafka.common.config.provider.FileConfigProvider
   ldap.java.naming.security.credentials=${file:/var/ssl/private/security.properties:ldap_bind_password}

Step 3: Runtime JVM Bootstrap
   JVM loads FileConfigProvider ──► Resolves ${file:...} reference from memory ──► Binds to LDAP securely

```

Any inspection of `server.properties` or `connect-distributed.properties` shows only the `${file:...}` reference, satisfying security and compliance requirements.

### Resilient KRaft Quorum Resolution

Upstream `cp-ansible` constructs the `controller.quorum.voters` configuration string by indexing hosts in the order they appear in the inventory group array. If an inventory changes order or nodes are added asynchronously, voter IDs drift and prevent KRaft controllers from electing an active leader.

This framework replaces index-based discovery with a deterministic Jinja2 expression anchored to host-level `node_id` definitions:

```yaml
kafka_controller_quorum_voters: >-
  {%- for h in groups['kafka_controller'] -%}
  {{ hostvars[h].node_id }}@{{ h }}:{{ kafka_controller_port }}{{ '' if loop.last else ',' }}
  {%- endfor -%}

```

Regardless of array order or inventory format, `node_id: 1` will always map to its designated host and voter endpoint.

### Production Safety Guardrail

Accidentally running an automated playbook against a production cluster while testing a change can cause catastrophic downtime. `playbooks/00_preflight.yml` serves as a deployment gatekeeper:

```yaml
- name: Enforce Explicit Confirmation for Critical Environments
  ansible.builtin.fail:
    msg: "FATAL: Deploying to '{{ environment_name }}' requires explicit confirmation: -e confirm_env={{ environment_name }}"
  when:
    - environment_name in ['production', 'preprod']
    - confirm_env is not defined or confirm_env != environment_name

```

Executing against `production` without `-e confirm_env=production` terminates the Ansible run immediately before inspecting or altering target hosts.

---

## 5. Lifecycle Environment Matrix

The architecture defines seven decoupled environments across three profiles:

| Environment | Primary Role | Hardware Profile (`shared/tiers/`) | Topology Matrix (`shared/topologies/`) | Data Durability Settings |
| --- | --- | --- | --- | --- |
| **`dev100`** | Local Sandbox / Testing | `nonprod` (3GB Broker / 1GB Controller) | `single-site` | `RF: 1`, `min.isr: 1`, `retention: 12h` |
| **`dev`** | Shared Engineering | `nonprod` (3GB Broker / 1GB Controller) | `single-site` | `RF: 1`, `min.isr: 1`, `retention: 24h` |
| **`test`** | Integration Testing | `nonprod` (3GB Broker / 1GB Controller) | `single-site` | `RF: 1`, `min.isr: 1`, `retention: 48h` |
| **`qa`** | Performance / Load QA | `nonprod` (3GB Broker / 1GB Controller) | `single-site` | `RF: 1`, `min.isr: 1`, `retention: 72h` |
| **`preprod`** | Production Mirror | `prod` (16GB G1GC Broker / 4GB Controller) | `stretched-2dc` | `RF: 4`, `min.isr: 2`, `retention: 168h` |
| **`production`** | Core Streaming Cluster | `prod` (16GB G1GC Broker / 4GB Controller) | `stretched-2dc` | `RF: 4`, `min.isr: 2`, `retention: 168h` |
| **`dr`** | Disaster Recovery Site | `prod` (16GB G1GC Broker / 4GB Controller) | `single-site` | `RF: 3`, `min.isr: 2`, `retention: 168h` |

> **Architectural Note on `dr` vs `production`:**
> While `production` spans two active datacenters (requiring `offsets.topic.replication.factor: 4` across DC1 and DC2), the `dr` cluster operates as a stand-alone 3-node system at a secondary site. If `dr` inherited the stretched topology, an offset replication factor of 4 on a 3-node cluster would prevent the cluster from forming. The symlink architecture allows `dr` to inherit `prod` hardware sizing while binding to the `single-site` topology (RF: 3), preserving cluster stability.

---

## 6. Operational Workflows & Scenarios

### Scenario A: Rotating a Corporate CA Certificate Globally

* **Objective:** Update the Root CA certificate across all seven environments without touching environment-specific inventories.
* **Execution:**
1. Place the new CA certificate at `pki/ca/ca.crt`.
2. If the certificate path or mutual TLS policies change, update `shared/base/10-security.yml`.
3. Because all environments link to `10-security.yml`, running `01_deploy_cluster.yml` propagates the truststore updates universally with zero variable duplication.



### Scenario B: Profiling Broker Memory in the QA Cluster

* **Objective:** Increase Broker heap to 8GB and enable JMX debugging flags exclusively in `qa` to support a load test.
* **Execution:**
1. Open `environments/qa/group_vars/all/95-overrides.yml`.
2. Append the target JVM heap overrides:
```yaml
kafka_broker_service_environment_overrides:
  KAFKA_HEAP_OPTS: "-Xms8g -Xmx8g -XX:+PrintGCDetails"

```


3. Deploy using `ansible-playbook -i environments/qa/hosts.yml playbooks/01_deploy_cluster.yml`.
4. Ansible merges this configuration at layer `95-`, overriding the baseline 3GB sizing from `05-tier.yml` for `qa` without affecting `dev`, `test`, or `production`.



### Scenario C: Provisioning an Eighth Environment (`stage`)

* **Objective:** Spin up a new staging environment matching pre-production standards.
* **Execution:**
1. Create the target structure:
```bash
mkdir -p environments/stage/group_vars/all

```


2. Establish relative symlinks to existing shared standards:
```bash
cd environments/stage/group_vars/all
ln -s ../../../../shared/base/00-global.yml 00-base.yml
ln -s ../../../../shared/tiers/prod/05-sizing.yml 05-tier.yml
ln -s ../../../../shared/topologies/stretched-2dc/06-replication.yml 06-topology.yml
ln -s ../../../../shared/base/10-security.yml 10-security.yml
ln -s ../../../../shared/base/20-identity-ldap.yml 20-identity-ldap.yml
ln -s ../../../../shared/base/25-file-config-provider.yml 25-file-config-provider.yml
ln -s ../../../../shared/base/30-observability.yml 30-observability.yml
ln -s ../../../../shared/base/35-performance.yml 35-performance.yml

```


3. Add the environment identity in `10-env.yml`, create `90-vault.yml`, populate `environments/stage/hosts.yml`, and the new cluster is immediately operational.
