---
name: harvester-aws-flex
description: Build, operate, troubleshoot or tear down a 3-node SUSE Harvester (SUSE Virtualization) cluster on AWS EC2 using regular (non-metal) instances with EC2 nested virtualization (default m8i-flex.2xlarge), Longhorn on EBS including RWX, and optional import into Rancher. Use when asked to create or rebuild a Harvester cluster on AWS, add Longhorn RWX storage, import Harvester into Rancher, or fix Harvester-on-EC2 problems (installer never starts, nodes not joining, Longhorn webhook timeouts, VIP unreachable, Rancher showing %harvester...% labels).
---

# Harvester on AWS with nested virtualization

Builds a 3-node Harvester cluster on EC2 VM instances that expose `/dev/kvm`
through EC2 nested virtualization (`--cpu-options NestedVirtualization=enabled`).
Longhorn (built into Harvester) runs on one gp3 EBS volume per node. A
`longhorn-rwx` StorageClass adds NFS-backed RWX. The cluster can be imported
into an existing Rancher.

Everything is parameterized by one `cluster.env` (see
`config/cluster.env.example`). State lives in `./state-<CLUSTER_NAME>/` next to
it. Scripts locate the config via `HAF_CONFIG` (default `./cluster.env`).

## How it works (don't "simplify" these away; each one fixes a real failure)

1. **UEFI iPXE AMI.** Harvester >= v1.8 refuses legacy BIOS. The public iPXE
   AMIs are BIOS-only and can't be copied. `02-build-ipxe-ami.sh` builds a
   `boot-mode=uefi` AMI: a throwaway t3.micro writes an ESP containing
   boot.ipxe.org's `ipxe.efi` and an `autoexec.ipxe` that chains
   `http://169.254.169.254/latest/user-data`, then powers off. One AMI can be
   reused per account/region (`IPXE_AMI_ID`).
2. **IMDSv1 while installing.** iPXE can't do the IMDSv2 PUT, so nodes launch
   with `HttpTokens=optional`. `04` switches them to `required` after install.
3. **User-data is an iPXE script.** It loads the Harvester kernel, initrd and
   rootfs straight from releases.rancher.com, with
   `harvester.install.automatic=true` and `config_url` pointing at S3.
4. **Install config per node in a private S3 bucket.** Its policy allows
   reads only from the nodes' public IPs (presigned URLs exceed the kernel
   cmdline limit). The bucket holds the password and token, so `07` deletes it.
5. **Config details:**
   - NIC matched by `hwAddr` (MAC); the installer resolves the name.
   - Disk given as `/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_vol...`,
     so NVMe ordering can't matter.
   - `mtu: 1500` (see MTU below).
   - `tty: ttyS0`.
   - `skipchecks: true`.
6. **Static IPs.** Node IPs are fixed. The VIP is a *secondary private IP on
   node 1's ENI*, and source/dest check is disabled.
7. **Flannel pinning.** `04` sets
   `flannel.alpha.coreos.com/public-ip-overwrite=<node IP>` on each node as it
   registers (see Flannel below).
8. **Console order.** The kernel cmdline uses `console=tty1 console=ttyS0`.
   The installer only runs automatic mode on the *first* active console, which
   is `tty1`. Kernel and systemd output still goes to the EC2 serial console.

## Workflow

Confirm with the user before anything that spends money or changes shared
systems. Run long waits (`04`, `05`) in the background and report progress.

1. **Gather parameters.** Collect region/AZ, key pair + private key path,
   cluster name, Harvester version, IPs, and whether to import into Rancher.
   Write `cluster.env` from the example.
   - **Instance size:** if the user asks for something smaller than
     8 vCPU / 32 GiB (e.g. c8i-flex.xlarge), explain that Harvester won't
     install or will run out of memory, and recommend m8i-flex.2xlarge.
   - **Version:** pick it to match their Rancher (`kubectl get
     settings.management.cattle.io server-version`). Rancher 2.14 pairs with
     v1.8.x; 2.15 pairs with v1.9.x.
2. **`00-preflight.sh`** (read-only). It checks:
   - credentials
   - UEFI + nested virtualization + size + AZ offering
   - subnet, internet route, IPs inside the CIDR and free
   - key pair matches the private key
   - Harvester artifacts exist
   - vCPU quota and S3 account public-access-block
   - Rancher reachability and agent TLS mode

   It prints the hourly price. **Show the user the cost (~$1.21/hr for 3 ×
   m8i-flex.2xlarge in us-east-2, plus EBS) and get a go-ahead.**
3. **`01-create-infra.sh`**: security group, S3 bucket, `secrets.env`.
4. **`02-build-ipxe-ami.sh`**: builds the UEFI iPXE AMI (~5 min), or
   validates `IPXE_AMI_ID`.
5. **`03-launch-nodes.sh`**: launches all 3 nodes and uploads their configs.
   Joins retry until node 1 is up, so there's no need to stagger.
6. **`04-postinstall.sh`** (15-40 min):
   - waits for the UI and writes the kubeconfig
   - pins flannel and waits for 3 Ready nodes
   - checks MTU/Longhorn/VIP and adds `longhorn-rwx`
   - switches IMDS to `required`
7. **`05-rancher-import.sh`** (optional). See Rancher TLS below. Use
   `--fix-agent-tls` only with explicit user approval, because it changes a
   *global* Rancher setting.
8. **`06-verify-rwx.sh`**: pods on nodes 2 and 3 share a `longhorn-rwx`
   volume.
9. **`07-cleanup-install-configs.sh`**: deletes the bucket.

Then tell the user:
- the UI URL (`https://<node1 public IP>`; the first visit sets the admin
  password)
- the kubeconfig and secrets paths
- that public IPs change on stop/start (`refresh-ips.sh`)
- for failure demos, stop node 2 or 3, not node 1
- the hourly cost

## Day-2 scripts

| Script | Use |
|---|---|
| `status.sh [--console N]` | Read-only snapshot: instances, UI, nodes, Longhorn, flannel endpoints, kube-vip leader, unhealthy pods, optional serial console. Start every investigation here. |
| `refresh-ips.sh` | After starting stopped nodes: new public IPs into state and kubeconfig; warns about flannel or VIP problems. |
| `vip-follow.sh` | Moves the VIP secondary IP to whichever node holds kube-vip leadership. |
| `teardown.sh [--delete-ami] [--remove-from-rancher]` | Deletes only resources tagged `Project=<CLUSTER_NAME>`; requires typing the name. Don't use `--delete-ami` if other clusters reuse the AMI. |

Never touch instances, security groups or Rancher clusters that belong to a
different `CLUSTER_NAME`.

## Troubleshooting

Gather facts first: `status.sh --console 40`. While a node is in the live
installer, `ssh rancher@<ip>` works with password `rancher` (`live_ssh` in
`lib.sh`); the installer log is `/var/log/console.log`. After install, use
key auth as `rancher`.

| Symptom | Cause | Fix |
|---|---|---|
| Console stops after iPXE downloads the initrd; UI never comes up | Normal: kernel output goes to ttyS0 but the installer UI runs on tty1. | Check `/var/log/console.log` over live SSH. Only act if it shows an error or the installer isn't running. |
| Installer log: "Legacy BIOS systems are no longer supported" | Booted BIOS: wrong AMI (public iPXE) or a metal/BIOS-only type. | Use the UEFI AMI from `02`; the instance type must list `uefi`. All x86 `.metal` types are BIOS-only (Harvester <= v1.7.3 only). |
| Installer idle after `my tty is /dev/ttyS0`, no automatic install | Automatic mode only runs on the first console in `/sys/class/tty/console/active`. | Keep `console=tty1 console=ttyS0` order in `templates/ipxe-userdata.tmpl`. |
| No `/dev/kvm`; VMs don't start | Nested virtualization not enabled. | Stop the instance, `aws ec2 modify-instance-cpu-options --instance-id ... --nested-virtualization enabled`, start it. |
| iPXE loops "user-data chain failed" | IMDS set to `required`. | `aws ec2 modify-instance-metadata-options --http-tokens optional` (any re-install needs this). |
| Installer can't fetch config (403) | Bucket policy lacks the node's current public IP, or the bucket was deleted. | Re-run `03-launch-nodes.sh` (re-applies the policy) or re-create with `01` then `03`. |
| Joins hang; rke2-agent logs `failed to get CA certs ... context deadline exceeded`; TCP handshake works but TLS stalls | **MTU:** AWS DHCP gave `mgmt-br` MTU 9001 while NIC/bond are 1500. | Prevented by `mtu: 1500` in the config. Live fix on a node: `sudo nmcli con modify bridge-mgmt 802-3-ethernet.mtu 1500 && sudo nmcli device reapply mgmt-br` (persistent; `/etc/NetworkManager` is bind-mounted from the persistent partition). |
| **Flannel:** image uploads fail with `failed calling webhook "mutator.longhorn.io" ... context deadline exceeded`; Rancher says "cluster agent disconnected"; one node's pods unreachable from the others | That node registered the **VIP** as its flannel VXLAN endpoint (it briefly held the VIP at boot); AWS delivers VIP traffic to node 1. | `kubectl annotate node <n> flannel.alpha.coreos.com/public-ip-overwrite=<node IP> --overwrite`, then delete that node's `rke2-canal` pod. `04` does this preventively. Check with `status.sh` (flannel endpoints). |
| UI unreachable at the VIP / harvester-system services flaky | kube-vip leader isn't node 1, but the VPC only routes the VIP to the ENI that owns it (no gratuitous ARP). | `vip-follow.sh`. Use any node's public IP for the UI meanwhile. |
| RWX PVC on `harvester-longhorn`/`longhorn` won't mount from 2 pods: "invalid controller count 2" | Those classes are `migratable` (block RWX for VM live migration only). | Use `longhorn-rwx` (NFS share-manager). Nodes already have `nfs-client`. |
| Rancher: cattle-cluster-agent CrashLoop "Strict CA verification is enabled but encountered error finding root CA" | Rancher `agent-tls-mode=strict` with a public CA (`cacerts` empty). | With the Rancher owner's OK: `05-rancher-import.sh --fix-agent-tls` (sets `system-store`), and the script re-applies the import manifest. Otherwise put Rancher's CA in `cacerts`. |
| Rancher UI shows `%harvester.dashboard...%` keys / Extensions page: "An error occurred loading the code for this Extension" | Rancher caches extensions in memory per pod. When the ui-plugin-charts repo republishes a version with different contents (e.g. Harvester ext 1.8.2 on 2026-11-04), pods started earlier serve the stale build alongside new ones. | With the Rancher owner's OK: `kubectl -n cattle-system rollout restart deploy/rancher`, then Ctrl+Shift+R in the browser. |
| Import manifest doesn't match versions | Harvester version unsupported by this Rancher. | Rancher 2.14 -> Harvester v1.8.x; 2.15 -> v1.9.x (check the current SUSE support matrix). |
| `aws: ... session has expired` | SSO/`aws login` expired. | Ask the user to run `! aws sso login` (or `aws login`); nothing to fix in the scripts. |

## Facts worth knowing

- **Minimum size:** 8 vCPU / 32 GiB (m8i-flex.2xlarge, ~$0.40/hr in
  us-east-2). Harvester's own services use more than 8 GiB.
- **Disk:** a 350 GB root gives ~173 GB to the OS partitions and the rest
  (`HARV_LH_DEFAULT`, ~177 GB) to Longhorn. Default VM disk class is
  `harvester-longhorn` with 3 replicas.
- **Nested performance:** guest VMs run nested (KVM inside an EC2 VM). That's
  fine for demos and labs; CPU-heavy guests are slower than on metal.
- **VM networking:** VMs on the default management network get pod-network
  addresses. Bridged/VLAN VM networks don't work in a VPC, because AWS drops
  unknown MACs.
- **Stop/start:** stopping all nodes is fine; Longhorn and etcd recover on
  start. Public IPs change; run `refresh-ips.sh`.
