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
- the control node itself configured by a playbook, its secret kept in Ansible Vault
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
| [`controller.yml`](controller.yml) | sets up the weekly update run on the control node | manually, after changes to the run |

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

The playbook never reboots a host, it only reports that a reboot is needed.
Unused Docker images are removed only after 7 days, so a rollback to the
previous image works without pulling it again.

## The weekly run: controller.yml

On the control node, a systemd timer starts the run every Sunday at 03:00.
[`files/ansible-update.sh`](files/ansible-update.sh), protected by `flock`
against overlapping runs, does:

1. `git pull --ff-only`, so the run always uses the committed state and
   never merges anything by itself
2. `ansible-playbook update.yml`
3. a summary to Home Assistant via webhook: `ok` or `failed`, hosts that
   need a reboot or a manual update, failed or unreachable hosts

[`controller.yml`](controller.yml) deploys the script, the
[service](files/ansible-update.service) and the [timer](files/ansible-update.timer)
and enables the timer. The control node is therefore reproducible from the
repository like every other host.

The webhook URL is a secret. It is stored in
[`group_vars/controller.yml`](group_vars/controller.yml), encrypted with
`ansible-vault encrypt_string`. Only this single value is encrypted, so
`update.yml` runs without the vault password. `controller.yml` writes the
URL to `/etc/ansible-update.env` (mode `0600`) with `diff: false`, so it
does not show up in `--diff` output either.

## Backups: not done by Ansible

Backups are done by scheduled backup jobs in Proxmox itself, independent
of Ansible. The weekly job for the containers runs on Sunday at 01:30 in
snapshot mode, 90 minutes before the update, so every update has a fresh
restore point. Backup results are checked in Proxmox, not by this
repository.

## Design decisions

- **Backups belong to Proxmox, not to Ansible.** The first version had a
  `backup.yml` that ran a stop-mode `vzdump` for every guest before the
  update. In practice the wrapper script never called it, and nobody
  noticed, because the update itself succeeded. At the same time the
  Proxmox job had been reduced to a single VM, so the containers went
  six days without a backup. A manual run of `backup.yml` then hung on a
  container whose NFS mount had blocked a process. Lesson: one system
  is responsible for backups, and it is the one that is built for it.
  `backup.yml` was removed (it is still in the git history).
- **Docker updates are opt-in per host.** Stacks where a new release can
  break things (database migrations, breaking changes) are updated by hand
  after reading the release notes. `compose_auto_update` makes this an
  explicit decision in the inventory.
- **Report, don't act.** The run reports reboots and manual updates
  instead of doing them unattended at night.
- **Plain modules and commands over extra collections.** `docker compose`
  is called directly instead of `community.docker`, so the control node
  needs nothing but `ansible-core`.

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

controller:
  hosts:
    ansible01:
      ansible_connection: local

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

To set up the weekly run on the control node, encrypt the webhook URL
and run `controller.yml`. `read -rs` keeps the URL out of the shell history;
`encrypt_string` writes no final newline, so the `echo` adds one for yamllint.

```
read -rs URL && printf '%s' "$URL" | ansible-vault encrypt_string --vault-password-file ~/.ansible-vault-pass --stdin-name ha_webhook_url >> group_vars/controller.yml; unset URL
echo >> group_vars/controller.yml
ansible-playbook controller.yml --vault-password-file ~/.ansible-vault-pass --check --diff
ansible-playbook controller.yml --vault-password-file ~/.ansible-vault-pass
systemctl list-timers ansible-update.timer
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

`update.yml` and `controller.yml` need real containers and the control
node, so CI only lints and syntax-checks them.

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
- [x] Timer, service unit and wrapper script in the repository, deployed by `controller.yml`; webhook URL in Ansible Vault

Out of scope for this project: alerting rules and Alertmanager, Grafana
dashboards, TLS, and creating containers with `community.general.proxmox`.
New containers are cloned from a template in Proxmox and then added to the
inventory.
