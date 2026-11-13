# Harvester on AWS: Claude Code skill

A [Claude Code skill](https://docs.claude.com/en/docs/claude-code/skills) and
shell scripts that build a 3-node **SUSE Harvester** (SUSE Virtualization)
cluster on regular AWS EC2 instances using **EC2 nested virtualization**.
The cluster includes **Longhorn on EBS** with filesystem **RWX**, and can
optionally be imported into **Rancher**.

| | |
|---|---|
| Default nodes | 3 × m8i-flex.2xlarge (8 vCPU / 32 GiB), nested virtualization on |
| Cost | ~$1.21/hr for the 3 nodes in us-east-2, plus EBS (vs ~$12/hr on bare metal) |
| Harvester | v1.8.x (pick the version that matches your Rancher) |
| Storage | One 350 GB gp3 volume per node; Longhorn, plus a `longhorn-rwx` StorageClass |
| Build time | ~30-45 min, mostly waiting on the Harvester install |

## Install the skill

```bash
git clone <this-repo-url> harvester-skills
mkdir -p ~/.claude/skills
ln -s "$PWD/harvester-skills/harvester-aws-flex" ~/.claude/skills/harvester-aws-flex
```

Symlinking means a `git pull` updates the skill. For a single project, link it
into that project's `.claude/skills/` instead.

Then ask Claude Code, for example:

> Build me a Harvester cluster on AWS called lab-hv using my key pair `my-key`.

Claude follows [`harvester-aws-flex/SKILL.md`](harvester-aws-flex/SKILL.md):
1. It runs read-only preflight checks.
2. It shows you the hourly cost and waits for your go-ahead.
3. It builds the cluster and reports back.

It asks before changing anything shared, such as global Rancher settings.

## Use the scripts without Claude

The scripts run on their own. See
[`harvester-aws-flex/README.md`](harvester-aws-flex/README.md) for
requirements, the `00`-`07` build steps, and day-2 commands: `status.sh`,
`refresh-ips.sh`, `vip-follow.sh` and `teardown.sh`.

## Repository layout

```
harvester-aws-flex/
  SKILL.md        workflow + troubleshooting (what Claude reads; useful for humans too)
  README.md       manual usage
  config/         cluster.env.example: every parameter
  scripts/        00-07 build steps, day-2 tools, lib.sh
  templates/      iPXE boot script, Harvester install config, UEFI ESP builder,
                  longhorn-rwx StorageClass, RWX test
```

## Why it's built this way

Running Harvester on EC2 hits several non-obvious problems. The skill handles
each one, and `SKILL.md` explains why:

- **UEFI boot:** Harvester >= v1.8 needs UEFI. AWS's x86 bare-metal types and
  the public iPXE AMIs are BIOS-only, so the scripts build a UEFI iPXE AMI.
- **MTU:** AWS DHCP's MTU 9001 breaks node joins unless MTU is pinned to 1500.
- **Flannel and the VIP:** a node can register the VIP as its flannel
  endpoint, which cuts off its pod network. Endpoints are pinned per node.
- **VIP routing:** the VIP only works on the node that owns it in AWS (no
  gratuitous ARP in a VPC). `vip-follow.sh` moves it.
- **Longhorn RWX:** Harvester's built-in storage classes only do block RWX
  (VM live migration), so the skill adds an NFS-backed `longhorn-rwx` class.
- **Rancher import:** includes fixes for strict agent TLS and stale UI
  extension caches.

## Security

- Each cluster's state lives in its working directory, under
  `state-<cluster>/`: node password, cluster token, kubeconfig, instance IDs.
  It's created owner-only (`0600`/`0700`) and is git-ignored here.
- Install configs are served from a temporary S3 bucket readable only from
  the nodes' public IPs. `07-cleanup-install-configs.sh` deletes it.
- Admin ports (443, 22, 6443) are open only to your IP / `ADMIN_CIDR`.
- Nodes switch to IMDSv2-only after install.

Don't commit `cluster.env` files or `state-*` directories.
