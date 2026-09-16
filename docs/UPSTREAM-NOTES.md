# Upstream notes (cp-ansible 8.3.1)

Behaviours of the `confluent.platform` collection that shaped this repository. File references are relative
to the collection root (`collections/ansible_collections/confluent/platform/`). Re-check this list when the
collection is upgraded.

## Configuration model

- **Hash merging is mandatory.** `roles/common/tasks/main.yml` asserts `hash_behaviour = merge`. The layered
  model of this repository depends on it: dictionaries merge across layers, scalars and lists are replaced.
- **Final properties = computed properties + `<component>_custom_properties`**
  (`roles/variables/vars/main.yml`, `*_final_properties`). The templates write
  `{{ key }}={{ value }}` for every key in `dictsort` order; `playbooks/render_config.yml` reproduces exactly
  this output.
- **Controllers only read `kafka_controller_custom_properties`.** The upstream sample
  `docs/sample_environments/c3-next-gen-active-active-setup` places the controller copy of the second Control
  Center exporter under `kafka_broker_custom_properties` in the controller group, which has no effect on
  controllers. `shared/topologies/stretched-2dc/10-control-center-ha.yml` sets both dictionaries.
- **Two Control Center Next Gen hosts** require `skip_control_center_next_gen_host_count_validation: true`
  (`roles/common/tasks/config_validations.yml`), a second telemetry exporter on brokers and controllers and
  per-host settings for the second instance (`confluent.controlcenter.id`, Prometheus/Alertmanager URLs).

## Variable names

- **Unknown variables are silently ignored.** For example `broker_rack` is not a cp-ansible variable; the rack
  must be set as `broker.rack` inside `kafka_broker_custom_properties`. `scripts/check-vars.py` rejects every
  override name that does not occur in the collection.
- **The `cp_` prefix is taken.** The collection uses names such as `cp_cluster`, `cp_package` and
  `cp_credential`; project variables therefore use the `iac_` prefix.

## KRaft

- **`kafka_controller_quorum_voters` is derived from the host order** (`index + 9991`) in
  `roles/variables/defaults/main.yml`, not from `node_id`. With pinned node ids, reordering controllers
  would produce a wrong voter set, so `shared/base/30-kafka-controller.yml` derives it from `node_id`.
- **Controllers and brokers read the same `node_id` host variable** (`node.id` in both
  `kafka_controller_final_properties` and `kafka_broker_final_properties`). A host that is in both groups
  gets the same id twice, which KRaft does not allow; preflight therefore rejects co-location.
- **Internal replication factor.** `default_internal_replication_factor` is 3; the upstream comment recommends
  4 when a cluster spans two data centers with four or more brokers. Applied in the `stretched-2dc` topology
  only, because `dr` is a prod-tier environment with three brokers.

## Paths that live on the control node

- **Kerberos keytabs**: `roles/kerberos/tasks/main.yml` copies `*_kerberos_keytab_path` from the control node
  (`copy` without `remote_src`) to `*_keytab_path` on the host.
- **IdP certificate**: `roles/common/tasks/idp_certs.yml` copies `oauth_idp_cert_path` from the control node.
- Host TLS material can stay on the hosts with `ssl_custom_certs_remote_src: true`.

## Defaults that do not fit an air-gapped, hardened installation

| Variable | Upstream default | This repository |
|---|---|---|
| `confluent_cli_repository_baseurl` | public AWS S3 bucket | Nexus |
| `confluent_common/clients/independent_repository_baseurl` | `https://packages.confluent.io` | Nexus mirror with the same layout |
| `redhat_java_package_name` | `java-25-openjdk` | `java-21-openjdk` |
| `confluent_control_center_next_gen_package_version` | `2.2.0` | `2.5.0` (OD-09) |
| `mds_super_user_password` | `password` | vault value, preflight rejects `password` |
| `whitelist_explicit_oauth_urls` | `false` → `-Dorg.apache.kafka.sasl.oauthbearer.allowed.urls=*` | `true` → token and JWKS URIs only |
| `jolokia_version` | `1.6.2` | Jolokia disabled |
| `jmxexporter_version` | `1.0.1` | kept (do not downgrade to 0.12.0) |

## Secret Protection

- `secrets_protection_enabled: true` encrypts password-like values (JAAS configs, basic auth user info, LDAP
  credentials) in every generated properties file; Kafka's FileConfigProvider alone only covers the keys that
  are rewritten by hand.
- With `secrets_protection_masterkey` empty and `regenerate_masterkey: true` (both defaults) the collection
  generates a new master key and security file on every run (`roles/common/tasks/masterkey.yml`). This
  repository pins the master key in vault and sets `regenerate_masterkey: false`.
- `secrets_protection_security_file` is a control node path. Secret Protection needs the Confluent CLI 3.0.0
  or newer on the hosts (`roles/common/tasks/config_validations.yml`).

## Dependencies

- `galaxy.yml` declares only `ansible.posix`, but `playbooks/support_bundle.yml` and
  `roles/common/tasks/fetch_logs.yml` use the `archive` module, which ansible-core redirects to
  `community.general.archive`. With ansible-core alone (no `ansible` community package) the support bundle
  playbook does not even pass a syntax check, so `community.general` is pinned in
  `collections/requirements.yml`.
- `meta/runtime.yml` requires ansible-core >= 2.16. `bcrypt` is needed on the control node when Control Center
  Prometheus basic authentication is enabled (`plugins/filter/filters.py`).

## Support bundle callback

`plugins/callback/support_bundle_on_failure.py` runs after a failed playbook and starts a **new**
`ansible-playbook` process:

- it runs `support_bundle.yml` from the directory of the playbook that failed, hence
  `playbooks/support_bundle.yml` in this repository;
- the new process does not receive the CLI flags of the original run (`--vault-id`, `-e`, ...) but inherits
  the environment, hence `scripts/run.sh` passes secrets as environment variables;
- it reacts to every failed playbook, including a run refused by the guard rails; `scripts/run.sh` therefore
  runs `playbooks/preflight.yml` first in a separate process without the callback;
- the switch `support_bundle_auto_collect_on_failure` is only read from CLI extra vars or variables written
  directly in the inventory file under `all.vars` — not from `group_vars/all` files. `scripts/run.sh`
  passes it as an extra var when `AUTO_SUPPORT_BUNDLE=false`.

## Execution

- **Use the upstream playbooks, not the roles directly.** `playbooks/kafka_broker.yml` (and the other component
  playbooks) first find the service state and then provision running hosts with `serial: 1`. Importing the
  roles directly skips this: `deployment_strategy: rolling` has no effect and a configuration change restarts
  every broker at the same time. `playbooks/site.yml` imports `confluent.platform.all`.
- **`stdout_callback = yaml` breaks every run** with community.general 12 or newer (`community.general.yaml` was
  removed). `ansible.cfg` uses `ansible.builtin.default` with `callback_result_format = yaml` instead.

- `deployment_strategy: rolling` provisions hosts whose service is already running one at a time; hosts that
  are not running yet are always provisioned in parallel. Upstream warns that rolling can fail while
  security modes are changed.
- `playbooks/restart.yml` restarts one host at a time unless `restart_strategy=parallel` is passed.
- Some computed properties are built from Python sets (e.g. `sasl.enabled.mechanisms`,
  `rest.extension.classes`), so their order changes between processes for the same configuration.
  Static runs set `PYTHONHASHSEED=0` so that configuration diffs only show real changes.
- Rendering `*_final_properties` needs a few OS facts (`systemd_base_dir` uses `ansible_os_family`);
  `playbooks/render_config.yml` provides stand-ins instead of gathering facts.
