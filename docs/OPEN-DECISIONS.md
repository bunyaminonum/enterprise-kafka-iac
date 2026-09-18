# Open decisions

Placeholders in this repository are marked with `TODO(OD-xx)`. Each item below blocks or shapes a part of
the configuration; the "Where" column points to the files that change once it is decided.

| ID | Decision | Why it matters | Where |
|---|---|---|---|
| OD-01 | Naming convention of the directory service accounts (`ldap-bind-user`, `svc-kafka-*`) | Accounts must exist in the directory before the first secured deployment | `shared/base/10-security.yml` |
| OD-02 | Authentication mode: `ldap_with_oauth` (default here) or OAuth only | Decides which identity provider clients and LDAP settings are needed and how users log in to Control Center | `shared/base/10-security.yml`, `10-env.yml` (`iac_oauth_*`) |
| OD-03 | MDS topology: MDS on every cluster or a central MDS; behaviour after a DR failover | Without MDS and identical role bindings on `dr`, a promoted cluster cannot authorize clients | `shared/base/10-security.yml`, `environments/dr/` |
| OD-04 | Source of TLS certificates and Kerberos keytabs (Vault, CyberArk, ...) and how pipelines fetch them | cp-ansible reads the keytabs on the control node; the pipelines contain a placeholder step. Password-like values come from vault and are written to the hosts as FileConfigProvider files; moving them to a central provider later only changes `${file:...}` into that provider's reference | `shared/base/10-security.yml`, `playbooks/file_secrets.yml`, `.github/workflows/deploy.yml`, `bitbucket-pipelines.yml` |
| OD-05 | Identity of the MDS super user (`svc-kafka-mds`) and who may use it | Administrative identity, separate from the read-only LDAP bind account | `shared/base/10-security.yml` |
| OD-06 | Observer placement for the stretched clusters (Multi-Region Clusters): placement constraints, promotion policy, `min.insync.replicas` | Determines durability and availability when a data center is lost | `shared/topologies/stretched-2dc/00-topology.yml` |
| OD-07 | Control Center in the stretched clusters: both instances active (cp-ansible pattern) with load-balancer routing, or a cold standby | cp-ansible only offers active-active | `shared/topologies/stretched-2dc/10-control-center-ha.yml`, `host_vars/` |
| OD-08 | Sizing (heaps, disks, partitions, network tuning) per tier and environment | Heap values follow general guidance; the commented tuning block in the prod tier needs a load test | `shared/tiers/*/00-tier.yml`, `20-components.yml` |
| OD-09 | Exact Control Center Next Gen package version available in the mirror | The collection default (2.2.0) is older than the pinned 2.5.0 | `shared/base/00-platform.yml` |
| OD-10 | Schema governance: compatibility level, schema replication to `dr` (`_schemas`, schema IDs) | Replicated data cannot be deserialized after a failover if schema IDs differ | `shared/base/32-schema-registry.yml`, `environments/dr/` |
| OD-11 | Tiered storage (object store, retention) | Prepared but commented out | `shared/tiers/prod/00-tier.yml` |
| OD-12 | Cluster Linking direction (destination- or source-initiated) and `password.encoder.secret` placement | The cluster that stores the link needs the encoder secret | `environments/dr/group_vars/all/20-components.yml` |
| OD-13 | Control node toolchain: ansible-core version supported by Confluent for cp-ansible 8.3.x, Python version of the runners | Validated with ansible-core 2.18, which is at the end of its maintenance window; bump `requirements.txt` in one pull request | `requirements.txt`, `collections/requirements.yml` |
| OD-14 | Real host names and endpoints (directory, identity provider, KDC, Nexus) | Every `internal.net` / `lab.local` value is a placeholder | `hosts.yml`, `10-env.yml`, `shared/base/*` |
