# Migration from the previous layout

This document describes what changed compared with the first version of this repository
(commit `8184bae`), why, and what has to be done after merging.

## Structure

| Previous layout | New layout | Why |
|---|---|---|
| 8 per-file symlinks in every `group_vars/all/` (`00-base.yml`, `10-security.yml`, ..., `35-performance.yml`) | 3 directory symlinks: `00-base`, `05-tier`, `06-topology` | The base feature files (10–35) were loaded AFTER the tier (05) and topology (06) layers, so a tier could not override a base value (a prod-tier `num.io.threads: 32` stayed `16`). A new base file also needed 7 new symlinks. |
| `10-env.yml` (`environment_name`, `cp_*`) | `10-env.yml` (`iac_env`, directory, Kerberos and identity provider endpoints, cluster names) | `cp_*` names are used by the collection itself (`cp_cluster`, `cp_package`, ...). |
| `95-overrides.yml` | `20-components.yml` | Every shared layer is now loaded before the environment files, no "last word" file is needed. |
| `90-vault.yml` committed in plain text (dev100 with real values) | `90-vault.yml.example` + per-value encrypted `90-vault.yml` (not part of the repository) | Reviewable pull requests, validation without vault passwords, no secrets in git. |
| `shared/base/00-global.yml` | `shared/base/00-platform.yml` | Package installation from the internal mirror, pinned versions, shared JVM options. |
| `shared/base/10-security.yml`, `20-identity-ldap.yml`, `25-file-config-provider.yml` | `shared/base/10-security.yml` | One security baseline: Kerberos (hardened, AD-compatible), LDAPS/Active Directory, OAuth, RBAC, Secret Protection. |
| `shared/base/30-observability.yml` | `shared/base/20-observability.yml` | JMX exporter enabled, ports pinned. |
| `shared/base/35-performance.yml` | `shared/base/31-kafka-broker.yml` + commented tuning block in `shared/tiers/prod/00-tier.yml` | Tuning without a load test is not a baseline (OD-08). |
| — | `shared/base/30-kafka-controller.yml`, `32-schema-registry.yml`, `33-kafka-connect.yml`, `34-kafka-rest.yml`, `35-control-center.yml` | One file per component, heap parameters for every component. |
| `shared/tiers/*/05-sizing.yml` | `shared/tiers/*/00-tier.yml` | Heaps as `iac_*_heap` parameters (G1 options kept), retention, license requirement for prod. |
| `shared/topologies/*/06-replication.yml` | `shared/topologies/*/00-topology.yml`, `stretched-2dc/10-control-center-ha.yml` | Replication is no longer lowered in the single-site topology; stretched clusters use RF 4 for all internal topics, rack awareness and one Control Center per site. |
| `broker_rack` host variable | `group_vars/site_dc1.yml`, `site_dc2.yml` (`broker.rack`) | `broker_rack` is not a cp-ansible variable and was silently ignored. |
| `playbooks/00_preflight.yml` | `playbooks/preflight.yml`, imported by every changing playbook | The deploy playbook did not run the guard rails. |
| `playbooks/01_deploy_cluster.yml` | `playbooks/site.yml` (imports `confluent.platform.all`) | Direct role imports skipped the upstream serial/rolling logic. |
| `playbooks/02_health_check.yml` | `playbooks/health_check.yml` (upstream health checks) | |
| `playbooks/00_distribute_secrets.yml` | removed | Replaced by Secret Protection. |
| — | `playbooks/restart.yml`, `validate_hosts.yml`, `support_bundle.yml`, `render_config.yml` | Operations, diagnostics and configuration rendering. |
| — | `scripts/`, `.github/`, `bitbucket-pipelines.yml`, `requirements*.txt`, `.yamllint`, `.ansible-lint`, `docs/` | Tooling, CI/CD, pinned toolchain, linting, documentation. |

## Findings fixed

1. **Every run failed**: `stdout_callback = yaml` refers to `community.general.yaml`, removed in
   community.general 12.0.0. `ansible.cfg` now uses the built-in callback with `callback_result_format = yaml`.
2. **No rack awareness in the stretched clusters**: `broker_rack` was ignored; `broker.rack` is now set per site
   and checked by preflight.
3. **No rolling behaviour and no guard rails on deploy**: the roles were imported directly, so running hosts
   were not provisioned one at a time and a configuration change restarted every broker at once; the preflight
   playbook was not imported.
4. **Duplicate KRaft node ids in dev100**: controllers and brokers shared hosts and `node_id` values.
   Controllers now run on dedicated hosts with unique ids (preflight enforces both).
5. **Layer order**: see "Structure".
6. **Plain-text secrets**: FileConfigProvider only covered the LDAP bind password; SR, Connect and REST JAAS
   configurations and MDS credentials were still written in plain text. Secret Protection now encrypts all of
   them; the vault file is no longer committed.
7. **Replication**: RF 1 in the single-site topology (inherited by `dr`), RF 3 with `min.insync.replicas=2` in
   the stretched topology, and internal topics with mixed RF (offsets 4, metadata/license/balancer 3).
   Now: RF 3 everywhere, RF 4 (2 per site) and `default_internal_replication_factor: 4` for stretched clusters.
8. **Preflight could never pass** (`java_version` undefined), did not protect `dr` and did not check id
   uniqueness or the collection version.
9. **Security model**: plain LDAP on a cluster host, OpenLDAP schema, RFC 8009-only Kerberos enctypes,
   MDS super user without separation. Now: LDAPS to Active Directory (OpenLDAP variant documented in dev100),
   AD-compatible enctypes, dedicated `svc-kafka-mds`, `ldap_with_oauth` with restricted OAuth URLs.
10. **Hygiene**: `host_key_checking = False`, hidden deprecation warnings, global Python interpreter,
    unpinned toolchain and collections, JMX exporter disabled, Control Center missing in production-like
    environments, old Control Center package version (2.2.0), only one controller in dev and test.

## Behaviour changes to be aware of

- Installation method is `package` (internal mirror of packages.confluent.io) instead of `archive`
  (the archive variant is kept as a comment in `shared/base/00-platform.yml`).
- Nonprod clusters replicate with RF 3 instead of 1.
- The prod-tier broker heap is 6 GB (Confluent production guidance) instead of 16 GB; other heaps keep the
  previous sizing.
- `auth_mode` is `ldap_with_oauth` against Active Directory instead of `ldap` against OpenLDAP.
- Every environment has a Control Center; stretched environments have one per site.
- Host names follow `<env>-[<site>-]<role>-<nn>`; dev and test have three controllers.

## After merging

1. **Rotate the credentials** that were committed in `environments/dev100/group_vars/all/90-vault.yml`.
   They stay in the git history; remove them from the history only in coordination with everybody who
   cloned the repository (e.g. `git filter-repo --path environments/dev100/group_vars/all/90-vault.yml
   --invert-paths`, followed by a force push).
2. Publish `confluent.platform` 8.3.1, `ansible.posix` 2.1.0 and `community.general` 12.6.5 to the Nexus raw
   repository (README, "Publish the collections").
3. Replace the placeholder host names, domains and endpoints (`hosts.yml`, `10-env.yml`, `shared/base`).
4. Create one vault identity per environment and the per-value encrypted `90-vault.yml` files.
5. Generate the Secret Protection master key and `security.properties` per environment, and provide the
   keytabs; wire both into the pipelines (OD-04).
6. Configure the CI system: self-hosted runners labelled `kafka-iac`, one environment per inventory directory,
   secrets, `SSH_KNOWN_HOSTS`, approvals for `preprod`, `production`, `dr`.
7. If the lab directory is OpenLDAP, enable the override prepared in
   `environments/dev100/group_vars/all/20-components.yml`.
