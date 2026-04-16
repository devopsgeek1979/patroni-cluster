# Changelog

All notable changes to this project are documented in this file.

## [v1.0.0] - 2026-04-17

### Added

- Production-ready documentation for 3-node Patroni cluster with HAProxy.
- Node sizing guidance for CPU, RAM, disk, and network planning.
- Separate configuration folders and files for Patroni, HAProxy, and etcd.
- Deployment automation script: `scripts/deploy-configs.sh`.
- etcd NFS backup automation script: `scripts/etcd-backup-nfs.sh`.
- etcd log rotation policy: `configs/etcd/logrotate-etcd`.
- MIT license in `LICENSE`.

### Changed

- HAProxy primary application endpoint exposed on `192.168.192.128:5432`.
- README updated with backup, recovery, deployment, and licensing sections.
