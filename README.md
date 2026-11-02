# ansible-prometheus

[![CI](https://github.com/mrasdev/ansible-prometheus/actions/workflows/ci.yml/badge.svg)](https://github.com/mrasdev/ansible-prometheus/actions/workflows/ci.yml)

Ansible playbooks for a Proxmox homelab: Prometheus and node_exporter with
monitoring targets generated from the inventory, plus a weekly unattended
update run for the LXC containers.

## Scope

This is a learning project. The goal is to understand the core concepts
by building something I actually run at home:

- inventory, groups and group variables
- playbooks with several plays
- idempotent tasks using the `apt`, `systemd_service` and `template` modules
- Jinja2 templates generated from inventory data
- handlers that restart a service only when its configuration changed
- unattended runs from a systemd timer, with the result reported to Home Assistant
- testing and linting playbooks in GitHub Actions, including an idempotence check

Prometheus and node_exporter are installed from the Debian packages.
Grafana, Alertmanager and TLS are out of scope for now.

## How this project was built

Concepts and design were worked out in a discussion with Claude
(Anthropic). The decisions are mine. Most of the code was written by
Claude Opus 5.5, and then reviewed, tested in CI and committed by me.
This is part of the exercise: learning a new tool by specifying,
understanding and reviewing AI-written code.

## Playbooks

| Playbook | Does | Used |
|---|---|---|
| [`site.yml`](site.yml) | installs node_exporter and Prometheus, generates the scrape configuration | manually, after inventory changes |
| [`update.yml`](update.yml) | upgrades Debian packages and, where enabled, Docker Compose stacks | weekly by systemd timer |
| [`backup.yml`](backup.yml) | stop-mode backup of every guest on the Proxmox host | currently not used, see below |

## Monitoring: site.yml

```
Ansible control node (LXC)
 │  SSH
 ├─► every host in group "nodes"      → node_exporter (port 9100)
 └─► the host in group "monitoring"   → Prometheus (port 9090)
                                         └─ scrapes every node on :9100
```

| Play | Hosts | Does |
|---|---|---|
| 1 | `nodes` | installs, starts and enables `prometheus-node-exporter` |
| 2 | `monitoring` | installs Prometheus, deploys `prometheus.yml` from a template, starts and enables the service |

In the homelab, `nodes` contains the Proxmox host and, as a child group,
every container in `apt`. node_exporter therefore runs on all managed
hosts. The Prometheus server monitors itself as well.

### Scrape targets from the inventory

[`templates/prometheus.yml.j2`](templates/prometheus.yml.j2) loops over
`groups['nodes']` and writes one target per host, using `ansible_host` as
the address and the inventory name as a `host` label. Adding a host to the
inventory and running the playbook is all it takes to monitor it. There is
no second list to keep in sync.

Before the file is deployed, it is checked with `promtool check config`.
If the check fails, the old configuration stays in place. Prometheus is
restarted by a handler, and only when the generated file has changed, so
a second run reports `changed=0`.

## Updates: update.yml

`update.yml` upgrades all packages on the hosts in group `apt`. For hosts
in group `docker`, the variable `compose_auto_update` decides:

- `true`: pull new images, recreate the containers, remove unused images
- `false`: no change, the run only prints a reminder for a manual update

On the control node, a systemd timer starts the run every Sunday at 03:00.
A wrapper script, protected by `flock` against overlapping runs, does:

1. `git pull --ff-only` (the control node has a read-only deploy key)
2. `ansible-playbook update.yml`
3. a summary to Home Assistant via webhook: success or failure, hosts that
   need a reboot or a manual update, failed hosts

The timer, the service unit and the script are not in this repository
yet (see roadmap).

## Backups: not done by Ansible

Backups are done by scheduled backup jobs in Proxmox itself, independent
of Ansible. The weekly job for the containers runs on Sunday at 01:30 in
snapshot mode, 90 minutes before the update, so every update has a fresh
restore point.

Ansible does not check this yet. If the backup job fails, the update
still runs.

`backup.yml` was the first approach (stop-mode `vzdump` per guest,
triggered by Ansible). It stays in the repository as a reference and is
still linted in CI, but it is not called by the update run.

## Usage

Requirements:

- a Linux control node with Ansible (`apt install ansible`)
- Debian-based targets reachable via SSH with key authentication
- root login or a user with sudo rights on the targets

Create your inventory from the example. `inventory/hosts.yml` is
git-ignored, so real addresses are never committed.
[`ansible.cfg`](ansible.cfg) points to it, so `-i` is not needed.

```
cp inventory/hosts.example.yml inventory/hosts.yml
```

```yaml
all:
  vars:
    ansible_user: root

monitoring:
  hosts:
    prometheus01:

nodes:
  hosts:
    pve01:
      ansible_host: 192.0.2.20
  children:
    apt:

apt:
  hosts:
    prometheus01:
      ansible_host: 192.0.2.10
    app01:
      ansible_host: 192.0.2.30

docker:
  hosts:
    app01:
      compose_file: /root/docker-compose.yml
      compose_auto_update: true
```

Check the inventory and the connection, do a dry run, then apply:

```
ansible-inventory --graph
ansible all -m ping
ansible-playbook site.yml --check --diff
ansible-playbook site.yml
```

Afterwards, `http://<prometheus-host>:9090/targets` lists every node.
All of them should be `UP`.

node_exporter has no authentication. Keep port 9100 reachable only from
the local network.

## Continuous integration

The [CI workflow](.github/workflows/ci.yml) has two jobs. `test` only runs
when `lint` passes.

**lint**

- `yamllint --strict` with the rules ansible-lint expects ([`.yamllint`](.yamllint))
- `ansible-lint` with the `production` profile ([`.ansible-lint`](.ansible-lint))
- `ansible-playbook --syntax-check` for every playbook

**test** runs `site.yml` on the GitHub runner itself.
[`inventory/local.yml`](inventory/local.yml) puts `localhost` into both
groups and uses a local connection without SSH.

1. first run: installs and configures everything
2. second run: must report `changed=0` (idempotence)
3. Prometheus (`/-/ready`) and node_exporter (`/metrics`) respond
4. the Prometheus API reports the node target as `health=up`, which proves
   that the generated configuration works

`update.yml` and `backup.yml` need real containers and a Proxmox host,
so CI only lints and syntax-checks them.

The workflow token is read-only, `actions/checkout` is pinned to a
commit hash and credentials are not persisted in the checkout.

The runner is Ubuntu, while the targets at home are Debian. Both use the
same packages, but the CI is not a full substitute for a run against the
real hosts.

## Status and roadmap

- [x] Prometheus and node_exporter via apt, CI with idempotence check
- [x] Separate groups for monitored hosts and the Prometheus server
- [x] Scrape configuration generated from the inventory, validated with promtool
- [x] Handler: restart only on configuration changes
- [x] CI hardening: pinned actions, read-only token
- [x] Deployment to the homelab: node_exporter on the Proxmox host and all containers
- [x] Weekly unattended update run via systemd timer, result reported to Home Assistant
- [x] Linting in CI: yamllint, ansible-lint (production profile), syntax check
- [ ] Timer, service unit and wrapper script in the repository, deployed by a play; webhook URL kept out of git
- [ ] Before updating, check that a fresh backup exists; otherwise skip the update and report failure
- [ ] Alerting rules and Alertmanager
- [ ] Grafana with Prometheus as data source
- [ ] Create LXC containers with `community.general.proxmox`
