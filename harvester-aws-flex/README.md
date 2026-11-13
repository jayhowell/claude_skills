# harvester-aws-flex

A 3-node **SUSE Harvester** cluster on regular AWS EC2 instances using
**EC2 nested virtualization**. Default is m8i-flex.2xlarge, about $1.21/hr for
all three in us-east-2, versus about $12/hr for bare metal. It includes:

- **Longhorn on EBS**, including filesystem **RWX**
- optional import into **Rancher**
- a **Claude Code skill** (`SKILL.md`), so Claude can build, operate and
  troubleshoot it for you

## Install the skill

```bash
# personal (all projects)
mkdir -p ~/.claude/skills && cp -r harvester-aws-flex ~/.claude/skills/
# or per project
mkdir -p .claude/skills && cp -r harvester-aws-flex .claude/skills/
```

Then ask Claude something like *"build me a Harvester cluster on AWS called
lab-hv"*. It reads `SKILL.md` and runs the scripts, confirming cost and any
shared-system changes with you first.

## Requirements

- AWS CLI v2 with credentials (admin or equivalent EC2/S3/SSM rights)
- An EC2 key pair, with its private key on your machine
- `jq`, `curl`, `kubectl`, `openssl`, `ssh` (OpenSSH >= 8.4)
- For the Rancher import: a kubectl context pointing at the Rancher *local*
  cluster

## Build

```bash
mkdir my-cluster && cd my-cluster
cp /path/to/harvester-aws-flex/config/cluster.env.example cluster.env
$EDITOR cluster.env                 # key pair, cluster name, IPs, version
S=/path/to/harvester-aws-flex/scripts
$S/00-preflight.sh                  # read-only checks + price
$S/01-create-infra.sh               # security group, bucket, secrets
$S/02-build-ipxe-ami.sh             # UEFI iPXE AMI (once per account/region)
$S/03-launch-nodes.sh               # 3 nodes, nested virt on
$S/04-postinstall.sh                # waits ~15-40 min, fixes + longhorn-rwx
$S/05-rancher-import.sh             # optional
$S/06-verify-rwx.sh                 # RWX test across nodes
$S/07-cleanup-install-configs.sh    # delete bucket holding password/token
```

## Day 2

| Command | What it does |
|---|---|
| `status.sh [--console 40]` | Health snapshot (start here when something's wrong) |
| `refresh-ips.sh` | After a stop/start: public IPs change |
| `vip-follow.sh` | Moves the VIP to the kube-vip leader |
| `teardown.sh` | Deletes the cluster |

Stop the nodes between sessions to pay only for EBS:
`aws ec2 stop-instances --instance-ids <ids from state-*/state.env>`.

## What's in here

```
SKILL.md                      instructions + troubleshooting for Claude (read this too)
config/cluster.env.example    all parameters
scripts/                      00-07 build steps, day-2 tools, lib.sh
templates/                    iPXE script, Harvester config, ESP builder,
                              longhorn-rwx StorageClass, RWX test
```

## Storage classes

| Class | Use |
|---|---|
| `harvester-longhorn` (default) | VM disks. Block RWX, which is what VM live migration uses. |
| `longhorn-rwx` (added) | Shared filesystems for pods (NFS share-manager). |

## Caveats

- The VIP lives on node 1's ENI (VPCs ignore gratuitous ARP). For failure
  demos, stop node 2 or 3.
- Guest VMs run nested, so they're slower than on metal. Fine for demos and
  labs.
- VM VLAN/bridge networks don't work in a VPC. Use the management network.
