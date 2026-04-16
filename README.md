# 🐘 Patroni PostgreSQL HA Cluster (3 Nodes) + ⚖️ HAProxy Load Balancer

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)

This guide documents a **production-ready baseline** for:

- 3 PostgreSQL nodes managed by **Patroni**
- 3-member **etcd** DCS (co-located with DB nodes)
- 1 **HAProxy** node exposing static endpoints for external applications

It is based on your `patroni_cluster_setup.txt`, corrected for consistency and hardened for real-world operations.

## 🧭 Target Topology (Static IP Plan)

| Role | Hostname | IP | Services |
| --- | --- | --- | --- |
| DB Node 1 | `db1` | `192.168.192.129` | `etcd`, `patroni`, `postgresql` |
| DB Node 2 | `db2` | `192.168.192.130` | `etcd`, `patroni`, `postgresql` |
| DB Node 3 | `db3` | `192.168.192.131` | `etcd`, `patroni`, `postgresql` |
| LB Node | `haproxy1` | `192.168.192.128` | `haproxy` |

## 🌐 External Application Endpoints

- **Primary (read/write):** `192.168.192.128:5432`
- **Replicas (read-only):** `192.168.192.128:5001`
- **HAProxy stats UI:** `http://192.168.192.128:7000/`

---

## ✅ Prerequisites

- OS: **RHEL 8 / compatible** on all four nodes
- Time sync configured (`chronyd`/NTP)
- DNS or `/etc/hosts` mappings are correct on all nodes
- Root or sudo access
- Private network connectivity between all nodes

## 🖥️ Node Sizing Requirements (Production Baseline)

Use the following as a practical starting point; increase based on workload, retention, and TPS profile.

| Node Type | vCPU | RAM | System Disk | Data Disk | Network |
| --- | --- | --- | --- | --- | --- |
| Patroni DB Node (`db1`/`db2`/`db3`) | 4 vCPU minimum (8 recommended) | 16 GB minimum (32 GB recommended) | 100 GB SSD | 500 GB+ NVMe/SSD dedicated for PG data/WAL | 1 Gbps minimum (10 Gbps recommended) |
| HAProxy Node (`haproxy1`) | 2 vCPU minimum (4 recommended) | 4 GB minimum (8 GB recommended) | 40 GB SSD | N/A | 1 Gbps minimum |

### 📈 Capacity Planning Notes

- For write-heavy workloads, prioritize faster storage IOPS/latency over raw CPU.
- Keep PostgreSQL `data` and WAL/archive paths on fast dedicated volumes.
- Ensure all 3 DB nodes have similar hardware to avoid failover performance skew.
- Reserve at least 20% free disk for autovacuum growth and maintenance operations.
- If expected steady connections exceed 2k+, scale HAProxy CPU/RAM accordingly.

### 📌 Recommended `/etc/hosts` entries (all nodes)

```bash
192.168.192.128 haproxy1
192.168.192.129 db1
192.168.192.130 db2
192.168.192.131 db3
```

---

## 🔐 Production Security Baseline

Before deployment, apply these controls:

- Use **strong unique passwords** (never `qaz123` in production).
- Restrict `pg_hba` to trusted CIDRs only (no global `0.0.0.0/0` unless absolutely required).
- Prefer keeping **SELinux enforcing** with proper policy; only set permissive/disabled if your org standard allows it.
- Keep firewall enabled and only open required ports.
- Limit HAProxy stats endpoint exposure (`7000`) to admin subnet.
- Store secrets in Vault/Ansible vars/KMS (not plain files in git).

---

## 🧱 Required Ports

| Port | Protocol | Source | Destination | Purpose |
| --- | --- | --- | --- | --- |
| 2379 | TCP | DB nodes | DB nodes | etcd client |
| 2380 | TCP | DB nodes | DB nodes | etcd peer |
| 5432 | TCP | HAProxy + DB nodes | DB nodes | PostgreSQL |
| 8008 | TCP | HAProxy + DB nodes | DB nodes | Patroni REST checks |
| 5432 | TCP | App clients | HAProxy | Primary traffic |
| 5001 | TCP | App clients | HAProxy | Replica traffic |
| 7000 | TCP | Admin subnet | HAProxy | HAProxy stats |

---

## 🛠️ Step 1: Base Preparation (Run on `db1`, `db2`, `db3`)

```bash
sudo useradd postgres || true
sudo usermod -aG postgres root

sudo dnf update -y
sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm
sudo dnf update -y
sudo dnf config-manager --set-enabled codeready-builder-for-rhel-8-x86_64-rpms
sudo dnf install -y vim wget nano curl git watchdog yum-utils jq

sudo dnf module disable -y postgresql

sudo yum install -y https://repo.percona.com/yum/percona-release-latest.noarch.rpm
sudo percona-release enable ppg-16 release
sudo yum install -y percona-ppg-server16 percona-patroni etcd python3-python-etcd

sudo systemctl stop etcd patroni postgresql || true
sudo systemctl disable etcd patroni postgresql || true
```

### 🐕 Step 1.1: Configure watchdog (all DB nodes)

```bash
sudo sed -i 's|^#watchdog-device.*|watchdog-device = /dev/watchdog|' /etc/watchdog.conf
sudo mknod /dev/watchdog c 10 130 || true
sudo modprobe softdog
sudo chown postgres:postgres /dev/watchdog
```

---

## 🧩 Step 2: Configure etcd (all DB nodes)

Use a full 3-node static cluster definition on each node.

### `db1` (`192.168.192.129`) — `/etc/etcd/etcd.conf`

```yaml
name: 'node1'
initial-cluster-token: PostgreSQL_HA_Cluster_1
initial-cluster-state: new
initial-cluster: node1=http://192.168.192.129:2380,node2=http://192.168.192.130:2380,node3=http://192.168.192.131:2380
data-dir: /var/lib/etcd
initial-advertise-peer-urls: http://192.168.192.129:2380
listen-peer-urls: http://192.168.192.129:2380
advertise-client-urls: http://192.168.192.129:2379
listen-client-urls: http://192.168.192.129:2379
```

### `db2` (`192.168.192.130`) — `/etc/etcd/etcd.conf`

```yaml
name: 'node2'
initial-cluster-token: PostgreSQL_HA_Cluster_1
initial-cluster-state: new
initial-cluster: node1=http://192.168.192.129:2380,node2=http://192.168.192.130:2380,node3=http://192.168.192.131:2380
data-dir: /var/lib/etcd
initial-advertise-peer-urls: http://192.168.192.130:2380
listen-peer-urls: http://192.168.192.130:2380
advertise-client-urls: http://192.168.192.130:2379
listen-client-urls: http://192.168.192.130:2379
```

### `db3` (`192.168.192.131`) — `/etc/etcd/etcd.conf`

```yaml
name: 'node3'
initial-cluster-token: PostgreSQL_HA_Cluster_1
initial-cluster-state: new
initial-cluster: node1=http://192.168.192.129:2380,node2=http://192.168.192.130:2380,node3=http://192.168.192.131:2380
data-dir: /var/lib/etcd
initial-advertise-peer-urls: http://192.168.192.131:2380
listen-peer-urls: http://192.168.192.131:2380
advertise-client-urls: http://192.168.192.131:2379
listen-client-urls: http://192.168.192.131:2379
```

### Start etcd on all DB nodes

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now etcd
sudo systemctl status etcd --no-pager
```

### Verify etcd membership (run from any DB node)

```bash
etcdctl --write-out=table --endpoints=192.168.192.129:2379,192.168.192.130:2379,192.168.192.131:2379 member list
```

---

## 🗄️ etcd Log Rotation + Automated NFS Backup

This section adds production-safe `etcd` snapshot backups to a network NFS server and rotates local `etcd` log files.

### 1) NFS backup target assumptions

- **NFS backup server IP:** `192.168.192.140`
- **NFS export path:** `/exports/etcd-backups`
- **Client mount path on DB nodes:** `/mnt/etcd-backups`

Install NFS tools on each DB node:

```bash
sudo dnf install -y nfs-utils
sudo mkdir -p /mnt/etcd-backups
```

Add persistent mount in `/etc/fstab` (all DB nodes):

```bash
192.168.192.140:/exports/etcd-backups /mnt/etcd-backups nfs defaults,_netdev,nofail 0 0
```

Mount and validate:

```bash
sudo mount -a
mountpoint /mnt/etcd-backups
```

### 2) Deploy backup script

Use the included script `scripts/etcd-backup-nfs.sh` on each DB node (or from your config management pipeline).

```bash
sudo install -m 750 -o root -g root scripts/etcd-backup-nfs.sh /usr/local/bin/etcd-backup-nfs.sh
```

Run a manual backup test:

```bash
sudo ETCD_ENDPOINTS="192.168.192.129:2379,192.168.192.130:2379,192.168.192.131:2379" \
         NFS_MOUNT="/mnt/etcd-backups" \
         CLUSTER_NAME="cluster_1" \
         RETENTION_DAYS="14" \
         /usr/local/bin/etcd-backup-nfs.sh
```

### 3) Automate backups (cron)

Example: run every 30 minutes on `db1` (or your designated backup node):

```bash
sudo crontab -e
```

```cron
*/30 * * * * ETCD_ENDPOINTS="192.168.192.129:2379,192.168.192.130:2379,192.168.192.131:2379" NFS_MOUNT="/mnt/etcd-backups" CLUSTER_NAME="cluster_1" RETENTION_DAYS="14" /usr/local/bin/etcd-backup-nfs.sh >> /var/log/etcd-backup.log 2>&1
```

### 4) Configure etcd log rotation

If etcd logs are written to files under `/var/log/etcd/`, deploy this logrotate policy:

```bash
sudo mkdir -p /var/log/etcd
sudo cp configs/etcd/logrotate-etcd /etc/logrotate.d/etcd
sudo logrotate -f /etc/logrotate.d/etcd
```

For `journald`-only environments, also set journal retention in `/etc/systemd/journald.conf` (for example `SystemMaxUse=1G`) and restart `systemd-journald`.

### 5) etcd backup/recovery scenarios

#### Scenario A: NFS share is unavailable during backup

- The script detects unmounted NFS and writes snapshot to local fallback path: `/var/backups/etcd/local-spool`.
- It exits with status `2` so monitoring can alert.
- After NFS recovery, sync fallback snapshots to NFS and clear old local files.

Example sync:

```bash
sudo rsync -av --remove-source-files /var/backups/etcd/local-spool/ /mnt/etcd-backups/cluster_1/
```

#### Scenario B: Single etcd node data loss (member still healthy elsewhere)

1. Stop etcd on failed node.
2. Remove old local data dir on failed node.
3. Recreate member from healthy cluster (`etcdctl member add ...`) and update node config.
4. Start etcd and verify with `etcdctl member list`.

#### Scenario C: Quorum loss / full etcd restore from snapshot

1. Stop etcd on all 3 DB nodes.
2. Select latest valid snapshot from NFS and verify checksum.
3. On each node, run `etcdctl snapshot restore` using that snapshot and node-specific `--name`, `--initial-cluster`, and `--initial-advertise-peer-urls`.
4. Replace old `data-dir` with restored directory.
5. Start etcd nodes and confirm quorum.
6. Validate Patroni cluster health after DCS recovery.

Snapshot restore example (adapt per node):

```bash
ETCDCTL_API=3 etcdctl snapshot restore /mnt/etcd-backups/cluster_1/etcd-snapshot-YYYY-MM-DD_HHMMSS.db \
    --name node1 \
    --data-dir /var/lib/etcd \
    --initial-cluster "node1=http://192.168.192.129:2380,node2=http://192.168.192.130:2380,node3=http://192.168.192.131:2380" \
    --initial-advertise-peer-urls "http://192.168.192.129:2380" \
    --initial-cluster-token PostgreSQL_HA_Cluster_1
```

Post-restore verification:

```bash
etcdctl --endpoints=192.168.192.129:2379,192.168.192.130:2379,192.168.192.131:2379 endpoint health
sudo -u postgres patronictl -c /etc/patroni/patroni.yml list
```

---

## 🐘 Step 3: Configure Patroni (all DB nodes)

```bash
sudo mkdir -p /etc/patroni /var/lib/pgsql/data /var/lib/pgsql/archived
sudo chown -R postgres:postgres /etc/patroni /var/lib/pgsql
sudo chmod 700 /var/lib/pgsql/data
```

### 🔑 Generate strong passwords once

Set values and reuse in all node configs:

- `POSTGRES_SUPERUSER_PASSWORD`
- `REPLICATOR_PASSWORD`
- `ADMIN_PASSWORD`
- `PERCONA_PASSWORD`

### Patroni config template (adjust `name` and `connect_address` per node)

Create `/etc/patroni/patroni.yml` on each DB node:

```yaml
scope: cluster_1
name: db1

restapi:
    listen: 0.0.0.0:8008
    connect_address: 192.168.192.129:8008

etcd3:
    hosts: 192.168.192.129:2379,192.168.192.130:2379,192.168.192.131:2379

bootstrap:
    dcs:
        ttl: 30
        loop_wait: 10
        retry_timeout: 10
        maximum_lag_on_failover: 1048576
        postgresql:
            use_pg_rewind: true
            use_slots: true
            parameters:
                wal_level: replica
                hot_standby: "on"
                max_wal_senders: 10
                max_replication_slots: 10
                wal_log_hints: "on"
                logging_collector: "on"
                max_wal_size: "10GB"
                archive_mode: "on"
                archive_timeout: 600s
                archive_command: "cp -f %p /var/lib/pgsql/archived/%f"

    initdb:
        - encoding: UTF8
        - data-checksums

    pg_hba:
        - host replication replicator 192.168.192.0/24 md5
        - host all all 192.168.192.0/24 md5
        - host all all 127.0.0.1/32 md5

    users:
        admin:
            password: "<ADMIN_PASSWORD>"
            options: [createrole, createdb]
        percona:
            password: "<PERCONA_PASSWORD>"
            options: [createrole, createdb]

postgresql:
    cluster_name: cluster_1
    listen: 0.0.0.0:5432
    connect_address: 192.168.192.129:5432
    data_dir: /var/lib/pgsql/data/
    bin_dir: /usr/pgsql-16/bin
    pgpass: /tmp/pgpass0
    authentication:
        replication:
            username: replicator
            password: "<REPLICATOR_PASSWORD>"
        superuser:
            username: postgres
            password: "<POSTGRES_SUPERUSER_PASSWORD>"
    parameters:
        unix_socket_directories: "/var/run/postgresql/"
    create_replica_methods:
        - basebackup
    basebackup:
        checkpoint: fast

tags:
    nofailover: false
    noloadbalance: false
    clonefrom: false
    nosync: false

watchdog:
    mode: required
    device: /dev/watchdog
    safety_margin: 5
```

### 🧷 Patroni systemd unit

Create `/etc/systemd/system/patroni.service`:

```ini
[Unit]
Description=Patroni PostgreSQL HA Cluster Manager
After=network.target

[Service]
Type=simple
User=postgres
Group=postgres
ExecStart=/bin/patroni /etc/patroni/patroni.yml
ExecReload=/bin/kill -s HUP $MAINPID
KillMode=process
TimeoutSec=30
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

### Start Patroni on all DB nodes

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now patroni
sudo systemctl status patroni --no-pager
```

---

## ⚖️ Step 4: Configure HAProxy (`haproxy1` - `192.168.192.128`)

```bash
sudo yum install -y percona-haproxy
```

Create `/etc/haproxy/haproxy.cfg`:

```cfg
global
        log 127.0.0.1 local2
        chroot /var/lib/haproxy
        pidfile /var/run/haproxy.pid
        maxconn 10000
        user haproxy
        group haproxy
        daemon
        stats socket /var/lib/haproxy/stats

defaults
        mode tcp
        log global
        option tcplog
        retries 3
        timeout queue 1m
        timeout connect 10s
        timeout client 1m
        timeout server 1m
        timeout check 10s
        maxconn 900

listen stats
        mode http
        bind 192.168.192.128:7000
        stats enable
        stats uri /

listen primary
    bind 192.168.192.128:5432
        option httpchk OPTIONS /master
        http-check expect status 200
        default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
        server db1 192.168.192.129:5432 maxconn 1000 check port 8008
        server db2 192.168.192.130:5432 maxconn 1000 check port 8008
        server db3 192.168.192.131:5432 maxconn 1000 check port 8008

listen standby
        bind 192.168.192.128:5001
        balance roundrobin
        option httpchk OPTIONS /replica
        http-check expect status 200
        default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
        server db1 192.168.192.129:5432 maxconn 1000 check port 8008
        server db2 192.168.192.130:5432 maxconn 1000 check port 8008
        server db3 192.168.192.131:5432 maxconn 1000 check port 8008
```

Start HAProxy:

```bash
sudo systemctl enable --now haproxy
sudo systemctl restart haproxy
sudo systemctl status haproxy --no-pager
```

---

## 🚀 Optional: Deploy Configs with Script

This repo includes `scripts/deploy-configs.sh` to copy the right config to each node.

Usage format:

```bash
./scripts/deploy-configs.sh <db1|db2|db3|haproxy> [repo_root] [--check-only] [--restart]
```

```bash
# On db1
./scripts/deploy-configs.sh db1

# On db2
./scripts/deploy-configs.sh db2

# On db3
./scripts/deploy-configs.sh db3

# On haproxy1
./scripts/deploy-configs.sh haproxy
```

If running from another directory, pass the repo path as second argument:

```bash
./scripts/deploy-configs.sh db1 /path/to/patroni-repo
```

Validate target file and required config keys without deploying:

```bash
# Check deployed Patroni config on db1
./scripts/deploy-configs.sh db1 --check-only

# Check deployed HAProxy config
./scripts/deploy-configs.sh haproxy --check-only
```

Deploy and restart only the relevant service for that role:

```bash
# Deploy db2 Patroni config and restart patroni service
./scripts/deploy-configs.sh db2 --restart

# Deploy HAProxy config and restart haproxy service
./scripts/deploy-configs.sh haproxy --restart
```

Manual restart alternative:

```bash
sudo systemctl restart patroni
sudo systemctl restart haproxy
```

---

## 🧪 Validation Checklist

### 1) Patroni cluster state

```bash
sudo -u postgres patronictl -c /etc/patroni/patroni.yml list
```

Expected: one `Leader`, two `Replica` nodes.

### 2) HAProxy health checks

```bash
curl -I http://192.168.192.129:8008/master
curl -I http://192.168.192.130:8008/replica
curl -I http://192.168.192.131:8008/replica
```

### 3) App connectivity tests

```bash
# Write endpoint (should always hit leader)
psql "host=192.168.192.128 port=5432 dbname=postgres user=postgres"

# Read endpoint (round-robin across replicas)
psql "host=192.168.192.128 port=5001 dbname=postgres user=postgres"
```

---

## 🚨 Operations Runbook

### Planned switchover

```bash
sudo -u postgres patronictl -c /etc/patroni/patroni.yml switchover
```

### Unplanned failover (simulate leader outage)

```bash
sudo systemctl stop patroni
```

Confirm a new leader is elected and `192.168.192.128:5432` continues serving writes.

### Node recovery

```bash
sudo systemctl start patroni
sudo -u postgres patronictl -c /etc/patroni/patroni.yml list
```

---

## 🛡️ Hardening Checklist (Production)

- Enable TLS for PostgreSQL client and replication traffic.
- Enable TLS/ACL for etcd.
- Restrict Patroni REST API (`8008`) to internal management subnet.
- Add `nofile`, memory, and kernel tuning for PostgreSQL workload profile.
- Integrate backups (pgBackRest / WAL archiving to object storage).
- Add monitoring: Patroni, PostgreSQL, HAProxy, etcd exporters + alerting.
- Add log rotation and central aggregation.

---

## 📎 Notes from Source File Alignment

- The source file had mixed backend IP references (`.129/.130/.131` and `.130/.131/.132`); this guide standardizes DB nodes to `.129/.130/.131`.
- The source used permissive auth (`trust` + `0.0.0.0/0`); this guide replaces it with scoped `md5` examples.

---

## 🧰 Quick Troubleshooting

- `journalctl -u etcd -n 100 -f`
- `journalctl -u patroni -n 100 -f`
- `journalctl -u haproxy -n 100 -f`
- `ss -tulnp | egrep '2379|2380|5432|8008|5001|7000'`

If cluster bootstrap fails, validate:

- same `scope` on all nodes
- unique `name` per node
- correct `connect_address` per node
- etcd quorum is healthy before starting Patroni

---

## 📄 License

This project is licensed under the `MIT` License. See the `LICENSE` file for full text.
