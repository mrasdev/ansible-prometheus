# ansible-prometheus

Ansible playbook that installs Prometheus and node_exporter in a Proxmox
homelab. The monitoring targets are generated from the Ansible inventory.

## Scope

This is a learning project. I started with no prior Ansible experience,
and the goal is to understand the core concepts by building something I
actually run at home:

- inventory, groups and group variables
- playbooks with several plays
- idempotent tasks using the `apt`, `systemd_service` and `template` modules
- Jinja2 templates generated from inventory data
- handlers that restart a service only when its configuration changed
- testing a playbook in GitHub Actions, including an idempotence check

Prometheus and node_exporter are installed from the Debian packages.
Grafana, Alertmanager and TLS are out of scope for now.

## How this project was built

Concepts and design were worked out in a discussion with Claude (Anthropic):
what Ansible does and does not do, how it relates to Prometheus, and why
the scrape configuration should be generated from the inventory rather
than maintained by hand.

The decisions are mine. Most of the code was written by Claude Opus 5.5,
explained step by step, and then reviewed, tested in CI and committed by
me. This is stated openly because it is part of the exercise: learning a
new tool by specifying, understanding and reviewing AI-written code.

## How it works

```
Ansible control node (LXC)
 │  SSH
 ├─► every host in group "nodes"      → node_exporter (port 9100)
 └─► the host in group "monitoring"   → Prometheus (port 9090)
                                         └─ scrapes every node on :9100
```

The playbook [`site.yml`](site.yml) contains two plays:

| Play | Hosts | Does |
|---|---|---|
| 1 | `nodes` | installs, starts and enables `prometheus-node-exporter` |
| 2 | `monitoring` | installs Prometheus, deploys `prometheus.yml` from a template, starts and enables the service |

A host can be in both groups. The Prometheus server normally monitors
itself as well.

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

## Usage

Requirements:

- a Linux control node with Ansible (`apt install ansible`)
- Debian-based targets reachable via SSH with key authentication
- root login or a user with sudo rights on the targets

Create your inventory from the example. `inventory/hosts.yml` is
git-ignored, so real addresses are never committed.

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
      ansible_host: 192.0.2.10

nodes:
  hosts:
    prometheus01:
    pve01:
      ansible_host: 192.0.2.20
```

Check the inventory and the connection, do a dry run, then apply:

```
ansible-inventory -i inventory/hosts.yml --graph
ansible all -i inventory/hosts.yml -m ping
ansible-playbook -i inventory/hosts.yml site.yml --check --diff
ansible-playbook -i inventory/hosts.yml site.yml
```

Afterwards, `http://<prometheus-host>:9090/targets` lists every node.
All of them should be `UP`.

node_exporter has no authentication. Keep port 9100 reachable only from
the local network.

## Continuous integration

The [CI workflow](.github/workflows/ci.yml) runs the playbook on the
GitHub runner itself. [`inventory/local.yml`](inventory/local.yml) puts
`localhost` into both groups and uses a local connection without SSH.

1. first run: installs and configures everything
2. second run: must report `changed=0` (idempotence)
3. Prometheus (`/-/ready`) and node_exporter (`/metrics`) respond
4. the Prometheus API reports the node target as `health=up`, which proves
   that the generated configuration works

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
- [ ] First deployment to the homelab (Proxmox, Debian LXCs)
- [ ] `ansible-lint` in CI
- [ ] Second playbook: backup and update of LXCs and Docker containers
