# Upstream notes (cp-ansible 8.3.2)

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

## Rootless deployment (cp-ansible >= 8.3.2)

- `rootless_enabled: true` skips every task that needs root (`when: not (rootless_enabled | bool)`; tags
  `privileged`, `package`, `systemd`, `sysctl`, `logrotate`) and generates `systemd --user` units instead:
  `~/.config/systemd/user/cp-<component>.service` with `Restart=on-failure` and
  `EnvironmentFile=<rootless_deployment_path>/rootless-bin/<component>.env` (the `*_service_environment_overrides`).
  `*_service_overrides` become extra `[Service]` lines (`roles/common/templates/rootless.service.j2`), which is how
  the secret `EnvironmentFile` of `playbooks/config_secrets.yml` reaches the units.
- With `rootless_deployment_path` set, cp-ansible derives the installation, configuration, keystore
  (`<path>/ssl`), CLI and JMX exporter paths from it; users and groups become `deployment_user` and
  `deployment_group`. Data and log directories are overridden in this repository (`iac_data_dir`, `iac_log_dir`).
- Confluent validated the mode on single nodes ("multi-node needs per-host supervision (future work)",
  `ROOTLESS_DEPLOYMENT_STEPS.md` of the collection). This repository's multi-node lab run is the reference.
- `custom_java_path` becomes `JAVA_HOME` of every component; `keytool` is taken from the `PATH`.
- PyYAML on the hosts: cp-ansible tries `pip install --user PyYAML` when it is missing, which fails without
  internet access; the host bootstrap installs `python3-pyyaml`.

## SCRAM with KRaft

- `kafka_controller_sasl_protocol: plain,scram` is the documented setting: SCRAM is not supported between KRaft
  controllers. The first value is also what the brokers use towards the controllers
  (`sasl.mechanism.controller.protocol`); this repository sets it to `SCRAM-SHA-512` for the brokers
  (`shared/base/31-kafka-broker.yml`), so PLAIN only remains between the controllers.
- `roles/kafka_controller/tasks/get_meta_properties.yml` formats the controllers with
  `kafka-storage format --add-scram` for `sasl_scram_users_final.admin`; `roles/kafka_broker/tasks/main.yml`
  creates every `sasl_scram_users_final` entry with `kafka-configs` afterwards. The collection's default users
  (`client`, `schema_registry`, ...) come with public default passwords, as do the default `sasl_plain_users`;
  `shared/base/10-security.yml` derives their passwords from the secret ones.
- `super.users` gets `User:<admin principal>` of the first mechanism of each listener
  (`roles/*/tasks/set_principal.yml`); both admin users are called `kafka` so that the controllers also accept the
  brokers' SCRAM identity.

## Paths that live on the control node

- **IdP certificate**: `roles/common/tasks/idp_certs.yml` copies `oauth_idp_cert_path` from the control node.
- Host TLS material can stay on the hosts with `ssl_custom_certs_remote_src: true`.

## Defaults that do not fit an air-gapped, hardened installation

| Variable | Upstream default | This repository |
|---|---|---|
| `confluent_cli_repository_baseurl` | public AWS S3 bucket | Nexus |
| `confluent_common/clients/independent_repository_baseurl` | `https://packages.confluent.io` | Nexus mirror with the same layout |
| Java | `java-25-openjdk` installed by the collection | Java 21 from the host bootstrap, `custom_java_path` |
| `confluent_control_center_next_gen_package_version` | `2.2.0` | `2.5.0` (OD-09) |
| `mds_super_user_password` | `password` | vault value, preflight rejects `password` |
| `whitelist_explicit_oauth_urls` | `false` → `-Dorg.apache.kafka.sasl.oauthbearer.allowed.urls=*` | `true` → token and JWKS URIs only |
| `jolokia_version` | `1.6.2` | Jolokia disabled |
| `jmxexporter_version` | `1.0.1` | kept (do not downgrade to 0.12.0) |

## Secret Protection is not used

- `secrets_protection_enabled` stays `false`. The password-like values are taken out of the properties files by
  `playbooks/config_secrets.yml` and resolved by a Kafka config provider instead (`shared/base/10-security.yml`).
- Reason: Secret Protection needs a master key on every host, and cp-ansible writes it as
  `Environment="CONFLUENT_SECURITY_MASTER_KEY=..."` into the systemd override. systemd exposes `Environment=`
  lines to unprivileged users (`systemctl show <unit> -p Environment`), so on the host the encryption adds little
  over file permissions — while adding a key that has to be kept and rotated.
- The key selection is taken from `roles/common/tasks/secrets_protection.yml` (`.*password.*`,
  `.*basic.auth.user.info.*`, `^ldap.java.naming.security.credentials$`, `^confluent.license$`,
  `.*sasl.jaas.config`), so the coverage is identical. The KRaft controller `client.properties`, which Secret
  Protection leaves in plain text, is covered as well.
- Going back to Secret Protection: `iac_config_secrets_enabled: false`, `secrets_protection_enabled: true` and
  the `secrets_protection_masterkey` / `secrets_protection_security_file` pair (see the git history of
  `shared/base/10-security.yml`). Preflight then requires the security file again and the hosts need the
  Confluent CLI 3.0.0 or newer (`roles/common/tasks/config_validations.yml`).

## EnvVarConfigProvider (default provider)

- `org.apache.kafka.common.config.provider.EnvVarConfigProvider` (KIP-887) ships with every component of this
  release: CP 8.3.1 (broker, controller, Schema Registry, Connect, REST Proxy) and Control Center Next Gen 2.5.0
  (kafka-clients 8.2.0). `config.providers.env.param.allowlist.pattern` limits it to `CP_SECRET_*`.
- The values reach the process through a systemd `EnvironmentFile` (root, `0600`). The unit property
  `Environment` stays empty and `EnvironmentFiles` shows only the path; the values are visible to root and to
  the service user in `/proc/<pid>/environ`, like a secret file readable by that user.
- File format: every value in double quotes, `\ " $` and backquote escaped with a backslash. Verified with
  `systemd-run` and EnvVarConfigProvider for JAAS configs, `$`, quotes, backslashes, empty values and leading or
  trailing spaces. Line breaks are rejected by `config_secrets.yml`.
- The override is set through `<component>_service_overrides` (`EnvironmentFile`), which the upstream
  `override.conf.j2` writes into `[Service]` next to the existing keys (`ExecStart`, ...).
- `client.properties` stays on FileConfigProvider: the kafka-* CLI tools and the cp-ansible health checks
  (`kafka-metadata-quorum` for controllers, `kafka-topics` for brokers) read it without the environment of the
  service.
- Kafka Connect shares its worker config providers with connector configurations. Whoever may create
  connectors (RBAC `ResourceOwner` on `Connector`) could reference `${env:CP_SECRET_...}` of the worker — the
  same holds for FileConfigProvider and Secret Protection. Keep connector creation to trusted principals.

## Broker health check and rolling restarts

- `roles/kafka_broker/tasks/health_check.yml` skips the under-replicated-partition check when `rbac_enabled`
  is true and Secret Protection is off. A rolling `site` run and `confluent.platform.restart` then continue to
  the next broker after a fixed delay (`kafka_broker_health_check_delay`, 20 s) without waiting for the
  replicas of the restarted broker. With `min.insync.replicas=2` that can stop `acks=all` producers.
- `playbooks/restart.yml` therefore waits for in-sync replicas itself
  (`playbooks/tasks/wait_for_in_sync_replicas.yml`), and configuration changes on running clusters are applied
  as `site -e skip_restarts=true` followed by `restart` (README, "Day-to-day operations").
- `confluent.platform.restart` starts with an "Import all variables" play that gathers facts implicitly; the
  component paths (`kafka_broker.config_file`, ...) are derived from `ansible_os_family`. `playbooks/restart.yml`
  keeps that play for the same reason.

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
- Tower: the inventory sync stores `group_vars/all` as inventory variables and the job receives them as
  `all.vars` of a generated inventory, so `support_bundle_auto_collect_on_failure: false` in
  `shared/base/00-platform.yml` switches the callback off there (the bundle would stay in the job's container).
  Tower passes extra variables as a file (`-e @...`), which the callback does not read.

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
