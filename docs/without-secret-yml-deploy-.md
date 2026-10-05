# Sade secret modeli v2: `lookup('env')` + THY'nin tanımladığı servis ortamı + elle yazılmış `${env:}` referansları

Bu doküman `secrets-env-sade-model.md` (v1) dosyasının **yerine geçer**. v1'deki "sunucu ortamını Ansible okusun"
(`host_env_secrets`) ve "Ansible servis ortamını yazsın" (`Environment=` blokları) fikirleri **yok**.

Çalışma dalı: `lab/dev100-host-secrets` (şu an `9c84bc1`: TLS'siz lab bloğu zaten eklenmiş). AWX projesi
`test-dev100-hosts-secrets`, envanter `dev100_host_secret_env`. Hepsini siz uygularsınız, ben hiçbir şey çalıştırmadım.

> **Durum notu.** Değişiklikler çalıştırılıp denenmedi. Bu yüzden iki aşamaya bölündü ve her aşamanın sonunda
> doğrulama var. Aşama 1 çalışıp küme sağlıklı olmadan Aşama 2'ye geçmeyin.

---

## 1. Model

Sistemde **iki ayrı ortam** var ve ikisine de değer gerekiyor:

```
  (A) Ansible'ın ortamı                              (B) Kafka servislerinin ortamı
  ansible-playbook sürecinin ortamı                  her sunucuda systemd'nin başlattığı süreç
  (AWX'te: EE container'ı, elle: kabuğunuz)          
        │                                                   │
        │ lookup('env', 'IAC_SECRET_*')                     │ ${env:IAC_SECRET_*}  (EnvVarConfigProvider)
        ▼                                                   ▼
  15-secrets.yml → vault_* → cp-ansible'ın                server.properties içindeki referanslar
  kendi işleri (SCRAM kullanıcıları, MDS rol
  atamaları, client.properties, düz metin
  türetilmiş değerler)
```

| | Kim tanımlar | Nerede | Neden |
|---|---|---|---|
| **(A)** | THY (lab'da siz) | `ansible-playbook` sürecinin ortamı | cp-ansible kurulum sırasında gerçek parolalara ihtiyaç duyar. `15-secrets.yml` **değişmez**, `lookup('env')` ile okur |
| **(B)** | THY (lab'da siz) | her sunucuda servislerin ortamı | Kafka `${env:X}` referansını kendi sürecinin ortamından çözer. `~/.bashrc` systemd servislerine girmez |

Aynı **9 değişken adı** (`IAC_SECRET_*`) iki yerde de kullanılır. Repoda secret dosyası, `.env`, yardımcı playbook,
`host_env_secrets` yok. Ansible `server.properties`'e yalnızca **referans** yazar (Aşama 2), değeri hiçbir yere yazmaz.

### Bedeli (bilerek kabul edilen)

- `client.properties` (CLI araçları ve cp-ansible sağlık kontrolleri) cp-ansible'ın varsayılanıyla **düz metin**
  parola taşır. Araçlar servisin ortamıyla çalışmaz, orada `${env:}` kullanılamaz.
- Controller PLAIN satırındaki **türetilmiş** kullanıcı parolaları (sha256 değerleri) düz metin yazılır.
- Keystore/truststore parolaları ve Connect'in `master.encryption.key` değeri olduğu gibi kalır.
- (A) için AWX'te EE'nin ortamına değer koymanın bir yolu gerekir (bölüm 2). Bu THY'nin kararı.

---

## 2. (A) tarafı: Ansible'ın ortamı

`lookup('env')` yalnızca `ansible-playbook` sürecinin ortamına bakar. İki yol:

**A1 – Komut satırı (kanıtlanmış yol).** Kabuğunuzda değişkenleri tanımlayıp `ansible-playbook`'u oradan çalıştırırsınız,
kontrol makinesi sizin terminaliniz olur. AWX gerekmez.

**A2 – AWX.** EE container'ının ortamına değer gerekir. Lab için bir yol: Settings → Jobs → **Extra Environment Variables**
(credential değil ama değerler veritabanında **düz metin** ve **tüm işlerde** görünür, yalnızca lab için). JSON'u kendi
kabuğunuzda üretip yapıştırırsınız (ben görmem):

```bash
python3 -c "print(__import__('json').dumps({k: v for k, v in __import__('os').environ.items() if k.startswith('IAC_SECRET_')}))"
```

THY'de bu yerine THY'nin güvenlik kararına göre bir yöntem seçilir (AWX credential injector standart yoldur,
THY kullanmak istemiyor). Bu doküman o kararı sizin yerinize vermez.

---

## 3. Uygulama

### Aşama 1 – Yardımcı playbook'ları kaldır, parolalar düz metin yazılsın

#### Adım 0 – Çalışma klonu

```bash
git clone -b lab/dev100-host-secrets git@github.com:bunyaminonum/enterprise-kafka-iac.git ~/kafka-iac-thysim
```

```bash
cd ~/kafka-iac-thysim
```

Offline doğrulama için venv ve koleksiyonlar (ikisi de `.gitignore`'da):

```bash
ln -s ~/kafka-iac-dev100/.venv .venv
```

```bash
ln -s ~/kafka-iac-dev100/collections/ansible_collections collections/ansible_collections
```

#### Adım 1 – Silinecek dosyalar

```bash
git rm playbooks/config_secrets.yml
```

```bash
git rm playbooks/tasks/config_secrets.yml
```

```bash
git rm playbooks/files/compare_config_secrets.py
```

```bash
git rm playbooks/tasks/host_env_secrets.yml
```

#### Adım 2 – Düzenlenecek dosyalar

**2.1. `playbooks/site.yml`**

```bash
vim playbooks/site.yml
```

`:9,11d` (9. satır `- name: Secrets of the generated ...`, 10. satır `import_playbook: config_secrets.yml`, 11. satır boş). Kalan:

```yaml
---
# Full deployment or reconfiguration of ONE environment.
#   scripts/run.sh <environment> site
#   scripts/run.sh <environment> site --tags kafka_broker          # one component (docs/TAGS.md upstream)
#   scripts/run.sh production site --limit site_ysl                 # one site of a stretched cluster
- name: Preflight
  ansible.builtin.import_playbook: preflight.yml

- name: Confluent Platform (pinned confluent.platform collection)
  ansible.builtin.import_playbook: confluent.platform.all
```

**2.2. `playbooks/preflight.yml`** – sunucu ortamı okuma görevinin import'unu kaldırın.

```bash
vim playbooks/preflight.yml
```

`:26,31d` yazmadan önce `:26` ile kontrol edin: satır `    - name: Secrets from the environment of the automation account on the hosts` olmalı.
Silinen aralık: 26–30 import bloğu ve 31. boş satır. Sonra 23–26. satırlar şöyle görünmeli:

```yaml
    - name: debug
      ansible.builtin.debug:
        var: iac_static_validation
    - name: Replace registered secrets with placeholders (static validation)
```

Güvenlik kontrolleri (`Registered secrets are set`, `SCRAM and PLAIN passwords ...`) **açık kalır**: parola ortamda yoksa iş
hiçbir sunucuya dokunmadan durur.

**2.3. `playbooks/render_config.yml`**

```bash
vim playbooks/render_config.yml
```

`:84` ile kontrol edin (`    - name: Secret references (as site.yml sets them)`), sonra `:84,87d`. `Expose ... role defaults`
görevlerine dokunmayın.

**2.4. `shared/base/10-security.yml`**

```bash
vim shared/base/10-security.yml
```

`:52` ile kontrol edin (`# ---- Passwords in generated files ---`), `:77` satırı `  - '.*sasl.jaas.config'` olmalı. Sonra `:52,77d`.
`secrets_protection_enabled: false` ve `regenerate_masterkey: false` satırlarını **silmeyin** (preflight kullanıyor).
Sonra 9. satırı değiştirin: `:9`, `cc`, şunu yazın, `Esc`:

```
#   passwords in generated files    -> ${env:...} references (EnvVarConfigProvider, 00-base/95-secret-refs.yml)
```

**2.5. `shared/base/33-kafka-connect.yml`** (isteğe bağlı, yorum düzeltme): `:10`, `cc`, şunu yazın, `Esc`:

```
# while the connector itself still reports RUNNING. The values are moved out of the file (95-secret-refs.yml).
```

**2.6. `environments/dev100/group_vars/all/20-components.yml`**

```bash
vim environments/dev100/group_vars/all/20-components.yml
```

13–15. satırları silin (`#secrets come from the environment ...` yorumu, `iac_secrets_from_host_env: true` ve boş satır): `:13,15d`.
Önce `:13` ile kontrol edin. Dosyadaki arşiv ayarları (`confluent_archive_file_source` ...) ve TLS'siz blok **kalır**.

Kaydedin (`:wq`) ve kodda eski mekanizmanın izi kalmadığını doğrulayın (yalnızca docs/README çıkabilir):

```bash
grep -rnI "config_secrets\|iac_config_secrets\|host_env_secrets\|iac_secrets_from_host_env" --exclude-dir=.git --exclude-dir=collections --exclude-dir=docs --exclude=README.md .
```

Çıktı **boş** olmalı.

#### Adım 3 – Offline doğrulama (sunucuya bağlanmaz)

```bash
source .venv/bin/activate
```

```bash
ansible-playbook -i environments/dev100 playbooks/site.yml --syntax-check
```

`playbook: playbooks/site.yml` yazmalı.

```bash
scripts/render-config.sh dev100
```

Başarılıysa `build/rendered/dev100/<sunucu>/` oluşur. Bu aşamada `${env:` referansı **olmamalı** (hepsi `0`):

```bash
grep -rc '\${env:' build/rendered/dev100
```

#### Adım 4 – Gönder

```bash
git add -A
```

```bash
git status --short
```

Beklenen: 4 silme (`D`), `site.yml`, `preflight.yml`, `render_config.yml`, `10-security.yml`, `33-kafka-connect.yml`,
`20-components.yml` için `M`. `build/`, `.venv`, `collections/ansible_collections` görünmemeli.

```bash
git commit -m "Remove config_secrets and host_env_secrets, read secrets with lookup(env) only"
```

```bash
git push origin lab/dev100-host-secrets
```

#### Adım 5 – (A) ortamını hazırlayın ve çalıştırın

1. **Ansible ortamı** (bölüm 2): A2 için Settings → Jobs → Extra Environment Variables'a JSON'u yapıştırın (A1 için bu adımı atlayın).
2. **Kümeyi durdurun** (yarı yapılandırılmış servisler yeni yapılandırma yazılırken sorun çıkarır):

```bash
sudo systemctl stop confluent-server confluent-kcontroller confluent-schema-registry confluent-kafka-connect
```

```bash
ssh cp-node2.lab.local 'sudo systemctl stop confluent-server confluent-kcontroller confluent-schema-registry confluent-kafka-connect'
```

```bash
ssh cp-node3.lab.local 'sudo systemctl stop confluent-server confluent-kcontroller confluent-schema-registry confluent-kafka-connect'
```

3. **AWX'te iki senkron**: Projects → `test-dev100-hosts-secrets` → Sync, sonra Inventories → `dev100_host_secret_env` →
   Sources → `src_hosts_secrets_env` → Sync. (Silinen/eklenen değişkenler envanterin veritabanında durur.)
4. **Şablon `dev100-hosts-secret`:** EE `ee-confluent-thy-env-secret-host-repo` (image `docker.io/library/ee-confluent-thy:1.0`),
   Extra variables: `deployment_strategy: parallel`. `dev100-config-secrets` şablonunu silin.
5. İşi çalıştırın.

A1 ile çalıştırmak isterseniz (kabuğunuzda değişkenler tanımlıyken, klon dizininde, venv açık):

```bash
ansible-playbook -i environments/dev100 playbooks/site.yml -e deployment_strategy=parallel -e support_bundle_auto_collect_on_failure=false
```

#### Adım 6 – Aşama 1 doğrulaması

| Log'da | Beklenen |
|---|---|
| `Registered secrets are set (deploy mode)` | ok (değerler EE ortamından geldi) |
| `Secrets of the generated configuration files` oyunu | **yok** |
| `Kafka Controller Parallel Provisioning` | var |
| `Create Kafka Controller Config`, `Create Kafka Broker Config` | 3 sunucuda changed |
| `Check Kafka Metadata Quorum` | ok |
| Oyun | yeşil |

```bash
systemctl is-active confluent-kcontroller confluent-server
```

Üç sunucuda da `active`, `active`. Bu aşamada parolalar `server.properties`'te düz metin. Sayı (değer yazmaz):

```bash
sudo grep -c 'password=' /opt/confluent/etc/kafka/server.properties
```

`0`'dan büyük normal. Servisler `active` değilse Aşama 2'ye geçmeyin, log'u bana gönderin.

Eski dizin artık kullanılmıyor. `override.conf`'ta `EnvironmentFile` kalmadığını ve `client.properties`'in eski dosyaya bakmadığını doğrulayın, sonra silin:

```bash
sudo grep -c EnvironmentFile /etc/systemd/system/confluent-server.service.d/override.conf
```

`0` olmalı.

```bash
sudo grep -c iac-secrets /opt/confluent/etc/kafka/client.properties
```

`0` olmalı. Sonra (üç sunucuda):

```bash
sudo rm -rf /var/ssl/private/iac-secrets
```

**Aşama 1'in düz metin yapılandırmalarını referans olarak saklayın** (Aşama 2 doğrulaması bunlarla karşılaştıracak). cp-node1'de beş dosya:

```bash
sudo install -m 600 -o root -g root /opt/confluent/etc/kafka/server.properties /root/ref-broker.properties
```

```bash
sudo install -m 600 -o root -g root /opt/confluent/etc/controller/server.properties /root/ref-controller.properties
```

```bash
sudo install -m 600 -o root -g root /opt/confluent/etc/schema-registry/schema-registry.properties /root/ref-schema-registry.properties
```

```bash
sudo install -m 600 -o root -g root /opt/confluent/etc/kafka/connect-distributed.properties /root/ref-connect.properties
```

```bash
sudo install -m 600 -o root -g root /opt/confluent/etc/kafka-rest/kafka-rest.properties /root/ref-rest.properties
```

---

### Aşama 2 – `${env:}` referansları

#### Adım 7 – (B) ortamı: THY servislerin ortamına değişkenleri tanımlar

**Referansları yazmadan ÖNCE** yapın. Aksi halde servisler referansı çözemeyen bir ortamla başlar ve düşer.

En kolay yol, systemd'nin `DefaultEnvironment` ayarı: bir dosya, sunucu başına bir kez, tüm servisler görür. (THY
bunun yerine servis başına drop-in kullanabilir, aşağıda not var.) **Her sunucuda** (ssh ile girip, kendi kabuğunda
`IAC_SECRET_*` değişkenleri tanımlı olan hesapla):

```bash
sudo mkdir -p /etc/systemd/system.conf.d
```

Dosyayı kendi ortamınızdan üretir (değerler terminale yazılmaz, doğrudan dosyaya gider):

```bash
python3 -c "print('[Manager]\nDefaultEnvironment=' + ' '.join('\"%s=%s\"' % kv for kv in sorted(__import__('os').environ.items()) if kv[0].startswith('IAC_SECRET_')))" | sudo tee /etc/systemd/system.conf.d/iac-secrets.conf > /dev/null
```

```bash
sudo chmod 600 /etc/systemd/system.conf.d/iac-secrets.conf
```

Dosyada kaç değişken var (dokuz beklenir, değer yazmaz):

```bash
sudo grep -o 'IAC_SECRET_[A-Z_]*=' /etc/systemd/system.conf.d/iac-secrets.conf | wc -l
```

systemd yönetici sürecini yeniden okutun (çalışan servisleri durdurmaz):

```bash
sudo systemctl daemon-reexec
```

Değişken, bundan sonra **başlatılan** servislerin ortamına girer. Kafka servisleri Aşama 2 koşusunda yeniden başlayacak.

*Notlar.* `DefaultEnvironment` tüm sistem servislerine uygulanır. Yalnızca Kafka servislerine vermek için her birinin
`/etc/systemd/system/<birim>.service.d/` dizinine `[Service]` + `Environment="IAC_SECRET_X=değer"` satırları içeren ayrı bir
dosya konur (cp-ansible'ın `override.conf` dosyasına dokunulmaz). Değerlerde `%`, `"`, `\` karakterleri sorun çıkarır.

#### Adım 8 – Yeni dosya `shared/base/95-secret-refs.yml`

Adı **95**, çünkü aynı dizindeki dosyalar sözcük sırasıyla yüklenir ve bu dosya en son yüklenmeli: `10-security.yml`
LDAP parolasını, `33-kafka-connect.yml` converter parolalarını düz metin tanımlıyor, küçük numaralı bir dosya onları ezemez.

```bash
vim shared/base/95-secret-refs.yml
```

`:set paste`, `i`, yapıştır, `Esc`, `:wq`:

```yaml
---
# =============================================================================
# SECRETS IN THE SERVICE CONFIGURATION: ${env:...} references (Kafka EnvVarConfigProvider)
#
# The services find the variables IAC_SECRET_* in their own process environment. The operator (THY) defines them on
# every host for the services (systemd DefaultEnvironment or a drop-in); nothing here writes a secret to a host.
# Ansible itself still needs the values (SCRAM users, MDS role bindings, client.properties): it reads them with
# lookup('env') in 15-secrets.yml, from the environment of the process that runs ansible-playbook.
#
# Loaded after every other file of 00-base on purpose: the keys below override plain values set earlier.
# Written by hand from the rendered configuration of dev100 (auth_mode ldap, no TLS). Another environment checks the
# key list with scripts/render-config.sh (secret-like keys) before it adopts this file.
# Not covered: keystore/truststore passwords (cp-ansible defaults), Control Center, client.properties (tools).
# =============================================================================

# MDS URLs of the components, as cp-ansible writes them (confluent.metadata.bootstrap.server.urls)
iac_mds_urls: "{% for h in groups['kafka_broker'] %}http{{ 's' if ssl_enabled | bool else '' }}://{{ h }}:8090{{ ',' if not loop.last else '' }}{% endfor %}"

# JAAS lines. Only the password is a reference; user names and the rest come from the same variables cp-ansible uses.
iac_jaas_scram_kafka: 'org.apache.kafka.common.security.scram.ScramLoginModule required username="kafka" password="${env:IAC_SECRET_KAFKA_BROKER_SCRAM_PASSWORD}";'
# PLAIN between the KRaft controllers: the user kafka is the real secret, the other users keep cp-ansible's derived values.
iac_jaas_plain_kafka: >-
  org.apache.kafka.common.security.plain.PlainLoginModule required username="kafka" password="${env:IAC_SECRET_KAFKA_CONTROLLER_PLAIN_PASSWORD}" user_kafka="${env:IAC_SECRET_KAFKA_CONTROLLER_PLAIN_PASSWORD}"{% for u in sasl_plain_users.values() if u.principal != "kafka" %} user_{{ u.principal }}="{{ u.password }}"{% endfor %};
iac_jaas_oauth_schema_registry: >-
  org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required username="{{ schema_registry_ldap_user }}" password="${env:IAC_SECRET_SCHEMA_REGISTRY_LDAP_PASSWORD}" metadataServerUrls="{{ iac_mds_urls }}";
iac_jaas_oauth_connect: >-
  org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required username="{{ kafka_connect_ldap_user }}" password="${env:IAC_SECRET_KAFKA_CONNECT_LDAP_PASSWORD}" metadataServerUrls="{{ iac_mds_urls }}";
iac_jaas_oauth_rest: >-
  org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginModule required username="{{ kafka_rest_ldap_user }}" password="${env:IAC_SECRET_KAFKA_REST_LDAP_PASSWORD}" metadataServerUrls="{{ iac_mds_urls }}";

# ---- Kafka brokers ----------------------------------------------------------------------------------
kafka_broker_custom_properties:
  config.providers: env
  config.providers.env.class: org.apache.kafka.common.config.provider.EnvVarConfigProvider
  config.providers.env.param.allowlist.pattern: '^IAC_SECRET_.*'
  ldap.java.naming.security.credentials: "${env:IAC_SECRET_LDAP_BIND_PASSWORD}"
  confluent.basic.auth.user.info: "{{ schema_registry_ldap_user }}:${env:IAC_SECRET_SCHEMA_REGISTRY_LDAP_PASSWORD}"
  kafka.rest.confluent.metadata.basic.auth.user.info: "{{ kafka_broker_ldap_user }}:${env:IAC_SECRET_KAFKA_BROKER_LDAP_PASSWORD}"
  confluent.metrics.reporter.sasl.jaas.config: "{{ iac_jaas_scram_kafka }}"
  listener.name.broker.scram-sha-512.sasl.jaas.config: "{{ iac_jaas_scram_kafka }}"
  listener.name.controller.scram-sha-512.sasl.jaas.config: "{{ iac_jaas_scram_kafka }}"
  listener.name.controller.plain.sasl.jaas.config: "{{ iac_jaas_plain_kafka }}"

# ---- KRaft controllers ------------------------------------------------------------------------------
kafka_controller_custom_properties:
  config.providers: env
  config.providers.env.class: org.apache.kafka.common.config.provider.EnvVarConfigProvider
  config.providers.env.param.allowlist.pattern: '^IAC_SECRET_.*'
  confluent.metadata.sasl.jaas.config: "{{ iac_jaas_scram_kafka }}"
  confluent.metrics.reporter.sasl.jaas.config: "{{ iac_jaas_scram_kafka }}"
  listener.name.broker.scram-sha-512.sasl.jaas.config: "{{ iac_jaas_scram_kafka }}"
  listener.name.controller.scram-sha-512.sasl.jaas.config: "{{ iac_jaas_scram_kafka }}"
  listener.name.controller.plain.sasl.jaas.config: "{{ iac_jaas_plain_kafka }}"

# ---- Schema Registry --------------------------------------------------------------------------------
schema_registry_custom_properties:
  config.providers: env
  config.providers.env.class: org.apache.kafka.common.config.provider.EnvVarConfigProvider
  config.providers.env.param.allowlist.pattern: '^IAC_SECRET_.*'
  confluent.metadata.basic.auth.user.info: "{{ schema_registry_ldap_user }}:${env:IAC_SECRET_SCHEMA_REGISTRY_LDAP_PASSWORD}"
  kafkastore.sasl.jaas.config: "{{ iac_jaas_oauth_schema_registry }}"

# ---- Kafka Connect ----------------------------------------------------------------------------------
# cp-ansible already enables the provider "secret" (Secret Registry); "env" is added next to it.
kafka_connect_custom_properties:
  config.providers: "secret,env"
  config.providers.env.class: org.apache.kafka.common.config.provider.EnvVarConfigProvider
  config.providers.env.param.allowlist.pattern: '^IAC_SECRET_.*'
  config.providers.secret.param.kafkastore.sasl.jaas.config: "{{ iac_jaas_oauth_connect }}"
  confluent.metadata.basic.auth.user.info: "{{ kafka_connect_ldap_user }}:${env:IAC_SECRET_KAFKA_CONNECT_LDAP_PASSWORD}"
  consumer.confluent.monitoring.interceptor.sasl.jaas.config: "{{ iac_jaas_oauth_connect }}"
  consumer.sasl.jaas.config: "{{ iac_jaas_oauth_connect }}"
  producer.confluent.monitoring.interceptor.sasl.jaas.config: "{{ iac_jaas_oauth_connect }}"
  producer.sasl.jaas.config: "{{ iac_jaas_oauth_connect }}"
  sasl.jaas.config: "{{ iac_jaas_oauth_connect }}"
  key.converter.schema.registry.basic.auth.user.info: "{{ kafka_connect_ldap_user }}:${env:IAC_SECRET_KAFKA_CONNECT_LDAP_PASSWORD}"
  value.converter.schema.registry.basic.auth.user.info: "{{ kafka_connect_ldap_user }}:${env:IAC_SECRET_KAFKA_CONNECT_LDAP_PASSWORD}"

# ---- Kafka REST Proxy -------------------------------------------------------------------------------
# The REST Proxy passes client.* to its Kafka clients, which need their own provider.
kafka_rest_custom_properties:
  config.providers: env
  config.providers.env.class: org.apache.kafka.common.config.provider.EnvVarConfigProvider
  config.providers.env.param.allowlist.pattern: '^IAC_SECRET_.*'
  client.config.providers: env
  client.config.providers.env.class: org.apache.kafka.common.config.provider.EnvVarConfigProvider
  client.config.providers.env.param.allowlist.pattern: '^IAC_SECRET_.*'
  client.confluent.monitoring.interceptor.sasl.jaas.config: "{{ iac_jaas_oauth_rest }}"
  client.sasl.jaas.config: "{{ iac_jaas_oauth_rest }}"
  confluent.metadata.basic.auth.user.info: "{{ kafka_rest_ldap_user }}:${env:IAC_SECRET_KAFKA_REST_LDAP_PASSWORD}"
```

Liste, kümedeki gerçek dosyalardan çıkarıldı (broker 7, controller 5, Schema Registry 2, Connect 9, REST 3 referans).
**Control Center bilerek yok** (cp-node3'te çalışıyor, anahtarlarını görmedim); parolası düz metin kalır. Eklemek için
`scripts/render-config.sh dev100` sonrasında şu komutla anahtarları listeleyip aynı kalıpla ekleyin:

```bash
grep -nE 'password|credentials|jaas|user.info' build/rendered/dev100/cp-node3.lab.local/control_center_next_gen.properties
```

#### Adım 9 – Offline doğrulama

```bash
scripts/render-config.sh dev100
```

Referans sayıları (cp-node1: broker 7, controller 5, schema-registry 2, connect 9, rest 3):

```bash
grep -rc '=\${env:IAC_SECRET_' build/rendered/dev100/cp-node1.lab.local
```

`dict object has no attribute` ya da `undefined variable` gibi bir hata alırsanız mesajı bana gönderin. Bir sonraki adıma geçmeyin.

#### Adım 10 – Gönder, çalıştır

```bash
git add shared/base/95-secret-refs.yml
```

```bash
git commit -m "Reference service secrets as env variables (EnvVarConfigProvider)"
```

```bash
git push origin lab/dev100-host-secrets
```

AWX'te yine **iki senkron** (proje, sonra envanter kaynağı), ardından `dev100-hosts-secret`. Servisler yapılandırma
değiştiği için yeniden başlar ve Adım 7'deki ortamı alır.

#### Adım 11 – Aşama 2 doğrulaması

Yapılandırmada referanslar (cp-node1, broker için `7`):

```bash
sudo grep -c '=\${env:IAC_SECRET_' /opt/confluent/etc/kafka/server.properties
```

Servis sürecinin ortamında değişkenler (dokuz beklenir):

```bash
sudo cat /proc/$(systemctl show -p MainPID --value confluent-server)/environ | tr '\0' '\n' | grep -c '^IAC_SECRET_'
```

Düz metin parola kalmadı mı? Broker'da `listener.name.internal.oauthbearer...` parolasız olduğu için **1** çıkması normal:

```bash
sudo grep -E '^(.*jaas.config|.*user.info|ldap.java.naming.security.credentials)=' /opt/confluent/etc/kafka/server.properties | grep -vc '=\${env:'
```

Controller, Schema Registry, Connect ve REST'te aynı komutla `0` beklenir.

**Asıl doğrulama: referanslar Aşama 1'in düz metin yapılandırmasıyla aynı sonucu veriyor mu?** Elle yazılmış satırlarda
bir kullanıcı adı, adres ya da boşluk farkı, servis çalışsa bile kimlik doğrulamayı bozar. Bu komut, referansları
çalışan servisin ortamıyla çözüp Aşama 1'de sakladığınız düz metin kopyayla karşılaştırır. **Yalnızca anahtar adlarını
ve sayıları yazar, değer yazmaz.** Dosyayı oluşturun:

```bash
vim ~/check-refs.py
```

`:set paste`, `i`, yapıştır, `Esc`, `:wq`:

```python
#!/usr/bin/env python3
"""Resolves ${env:NAME} references of a properties file with the environment of a running service and compares
the result with a plain-text reference copy. Prints key names and counts only, never values.
usage: sudo python3 check-refs.py <systemd-unit> <new.properties> <reference.properties>"""
import re
import subprocess
import sys

unit, new_path, ref_path = sys.argv[1:4]
pid = subprocess.check_output(["systemctl", "show", "-p", "MainPID", "--value", unit], text=True).strip()
with open(f"/proc/{pid}/environ", "rb") as fh:
    env = dict(item.split("=", 1) for item in fh.read().decode().split("\0") if "=" in item)


def load(path):
    props = {}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                props[key] = value
    return props


def norm(value):
    # JAAS lines: the order of the options and the amount of white space do not matter
    return sorted(value.split())


new, ref = load(new_path), load(ref_path)
pattern = re.compile(r"\$\{env:([^}]+)\}")
checked, different = 0, []
for key, value in new.items():
    if "${env:" not in value:
        continue
    checked += 1
    resolved = pattern.sub(lambda m: env.get(m.group(1), "<MISSING " + m.group(1) + ">"), value)
    if norm(resolved) != norm(ref.get(key, "")):
        different.append(key)
print(f"{unit}: {checked} references checked, {len(different)} different")
for key in different:
    print("  DIFFERENT:", key)
```

Beş bileşen için çalıştırın (cp-node1). Her birinde `0 different` beklenir:

```bash
sudo python3 ~/check-refs.py confluent-server /opt/confluent/etc/kafka/server.properties /root/ref-broker.properties
```

```bash
sudo python3 ~/check-refs.py confluent-kcontroller /opt/confluent/etc/controller/server.properties /root/ref-controller.properties
```

```bash
sudo python3 ~/check-refs.py confluent-schema-registry /opt/confluent/etc/schema-registry/schema-registry.properties /root/ref-schema-registry.properties
```

```bash
sudo python3 ~/check-refs.py confluent-kafka-connect /opt/confluent/etc/kafka/connect-distributed.properties /root/ref-connect.properties
```

```bash
sudo python3 ~/check-refs.py confluent-kafka-rest /opt/confluent/etc/kafka-rest/kafka-rest.properties /root/ref-rest.properties
```

`DIFFERENT: <anahtar>` görürseniz o anahtarın yazımında (kullanıcı, `iac_mds_urls`, parola değişkeni adı) hata var.
`<MISSING IAC_SECRET_X>` ise servisin ortamında o değişken yok: Adım 7 eksik.

Son olarak küme sağlığı: `systemctl is-active` (üç sunucuda tüm bileşenler) ve `kafka-metadata-quorum` kontrolü.

---

## 4. Dosya bazlı özet

| Dosya | İşlem |
|---|---|
| `playbooks/config_secrets.yml` | **sil** |
| `playbooks/tasks/config_secrets.yml` | **sil** |
| `playbooks/files/compare_config_secrets.py` | **sil** |
| `playbooks/tasks/host_env_secrets.yml` | **sil** |
| `playbooks/site.yml` | `config_secrets` import'unu kaldır (9–11) |
| `playbooks/preflight.yml` | `host_env_secrets` import'unu kaldır (26–31). Güvenlik kontrolleri kalır |
| `playbooks/render_config.yml` | `Secret references` görevini kaldır (84–87) |
| `shared/base/10-security.yml` | `iac_config_secrets_*` bloğunu sil (52–77), 9. satır yorumu |
| `shared/base/33-kafka-connect.yml` | 10. satır yorumu (isteğe bağlı) |
| `environments/dev100/group_vars/all/20-components.yml` | `iac_secrets_from_host_env` satırlarını sil (13–15) |
| `shared/base/95-secret-refs.yml` | **yeni** (Aşama 2) |
| `shared/base/15-secrets.yml` | **değişmez** (`lookup('env')`) |
| AWX şablonu `dev100-config-secrets` | sil |

---

## 5. Bilinen riskler ve bilinmeyenler

1. **Denenmedi.** Doğrulama adımları (3, 9, 11) bu yüzden zorunlu. Özellikle `check-refs.py`: elle yazılan satırlardaki hataları yakalayan tek şey.
2. **AWX'te (A) ortamı.** `lookup('env')` AWX'te yalnızca EE'nin ortamına değer konursa çalışır. THY'nin credential kullanmama
   kararıyla çelişen bir noktadır. Yöntemi THY seçer (bölüm 2).
3. **Anahtar listesi lab'a özel** (ldap, TLS'siz). `iac_mds_urls` `ssl_enabled`'a bakar: TLS açıkken `https` olur; THY'de
   `ldap_with_oauth` için OAuth sırları ve `ssl.*.password` anahtarları eklenir.
4. **Control Center** Aşama 2'de yok.
5. **KRaft'taki SCRAM parolası.** `kafka` kullanıcısının SCRAM parolası, 4 Ekim'deki iş 138 sırasında (ortam boşken) değişmiş olabilir.
   Broker günlüğünde `invalid credentials with SASL mechanism SCRAM-SHA-512` görürseniz ayrı bir adım gerekir.
6. **MDS anahtarı her AWX koşusunda yeniden üretilir** (EE'deki `generated_ssl_files` geçicidir): `Copy in private pem files`
   her `site`'ta `changed` çıkar, controller/broker yeniden başlar. THY belgesindeki risk bu.
7. Parola değişirse hem (A) hem (B) ortamı güncellenir, sonra `site` çalıştırılır ve servisler yeniden başlar.

---

## 6. THY'ye taşırken

- TLS açık kalır: lab'ın TLS'siz bloğu eklenmez. `iac_mds_urls` otomatik `https` olur.
- `ldap_with_oauth`: zorunlu sır sayısı 14'e çıkar, OAuth istemci sırlarının geçtiği JAAS anahtarları listeye eklenir.
- (B) için THY servis başına drop-in ya da `DefaultEnvironment` seçer. Değer kaynağı THY'nin sır yönetimidir, repoda hiçbir yerde yok.
- (A) için THY'nin güvenlik kararı gerekir (bölüm 2).

---

## 7. Sorun giderme

| Belirti | Olası sebep |
|---|---|
| `Registered secrets are set` hatası | (A) ortamı boş: EE'de/kabukta `IAC_SECRET_*` yok |
| `dict object has no attribute 'principal'` (render/iş) | `sasl_plain_users` yapısı farklı: `iac_jaas_plain_kafka` satırını kontrol edin |
| Servis `failed`, günlükte referans çözülemedi | (B) ortamı eksik: Adım 7 ve `grep -c '^IAC_SECRET_'` kontrolü; servis `daemon-reexec` sonrası yeniden başlamamış |
| `check-refs.py` → `<MISSING IAC_SECRET_X>` | Servis ortamında değişken yok (Adım 7) |
| `check-refs.py` → `DIFFERENT: <anahtar>` | O anahtarın referans satırında kullanıcı adı, adres ya da değişken adı farkı |
| Controller `Authorizer did not start up within the timeout` | Broker'lar 10 dakika içinde başlamadı ya da TLS uyumsuzluğu (`ssl_enabled` her yerde aynı olmalı) |
| `invalid credentials with SASL mechanism SCRAM-SHA-512` | KRaft'taki SCRAM parolası ortamdakiyle uyuşmuyor (Bölüm 5, madde 5) |
| Connect `config.providers` hatası | `config.providers: "secret,env"` ya da `secret` sağlayıcısının sırası değişmiş olabilir |
