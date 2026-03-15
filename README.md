# ⬡ vSphere VLAN Probe Tester

Automated end-to-end VLAN validation for VMware vSphere environments.  
Runs directly on a Ubuntu probe VM — no jumphost or SSH dependency needed.

**Author:** Paul van Dieen · [hollebollevsan.nl](https://www.hollebollevsan.nl)

---

## Overview

`vlan-test.sh` loops through a list of vSphere port groups you define. For each one it:

1. Uses **govc** to move the probe VM's test NIC onto that port group
2. Reconfigures the local test interface with the correct IP and gateway
3. Runs a full battery of network tests — all explicitly bound to the test NIC
4. Collects pass / warn / fail results and writes a **JSON file** + a **dark-themed interactive HTML report**

---

## Two-NIC Design

The probe VM requires **two network adapters**:

| NIC | Port Group | Purpose |
|-----|-----------|---------|
| `ens160` | Management PG | Stable terminal session — DHCP or static, never touched by the script |
| `ens192` | Rotated per VLAN | Test NIC — script moves this between port groups and re-IPs it each run |

> ⚠️ Never use a single-NIC probe. Switching the port group of your only NIC will drop your session mid-run.

---

## Prerequisites

- Ubuntu 20.04 or later on the probe VM
- **govc** installed and in PATH
- **passwordless sudo** for the probe user
- `nmap`, `dnsutils`, `curl` — auto-installed on first run if missing
- Network access from the management NIC to vCenter

**Install govc:**
```bash
curl -L https://github.com/vmware/govmomi/releases/latest/download/govc_Linux_x86_64.tar.gz | tar -xz
sudo mv govc /usr/local/bin/
govc version
```

**Netplan — leave the test NIC unconfigured:**
```yaml
# /etc/netplan/00-installer-config.yaml
network:
  version: 2
  ethernets:
    ens160:       # management NIC — DHCP or static
      dhcp4: true
    ens192:       # test NIC — leave bare
      dhcp4: false
```

---

## Installation

```bash
git clone https://github.com/pauldiee/vsphere-vlan-tester.git
cd vsphere-vlan-tester
chmod +x vlan-test.sh
```

---

## Configuration

All configuration is at the top of `vlan-test.sh` — no external config file needed.

### vCenter connection
```bash
export GOVC_URL="https://vcenter.lab.local"
export GOVC_USERNAME="administrator@vsphere.local"
export GOVC_PASSWORD='yourpassword'
export GOVC_INSECURE=1
```

### VM & interface
```bash
VM_NAME="ubuntu-probe"   # exact VM name as shown in vCenter
IFACE="ens192"           # test NIC — rotated between VLANs by the script
```

### VLANs to test
```bash
# Format: "PortGroupName|IP/prefix|Gateway|Description"
VLANS=(
  "PG-VLAN10|192.168.10.100/24|192.168.10.1|Server VLAN"
  "PG-VLAN20|192.168.20.100/24|192.168.20.1|User VLAN"
  "PG-VLAN30|192.168.30.100/24|192.168.30.1|DMZ VLAN"
)
```

### Optional: extra ping targets
```bash
EXTRA_PING=(
  "PG-VLAN10|192.168.10.10 192.168.10.20"
  "PG-VLAN20|192.168.20.10"
)
```

### Optional: HTTP checks
```bash
# Index matches VLANS array (0-based)
HTTP_TESTS=(
  "http://192.168.10.1|200"
  "http://192.168.20.1|200"
)
```

---

## Usage

```bash
./vlan-test.sh
```

Example terminal output:

```
╔══════════════════════════════════════════╗
║        vSphere VLAN Probe Tester         ║
╚══════════════════════════════════════════╝

┌─────────────────────────────────────────
│  [1/3] PG-VLAN10 — Server VLAN
│  IP: 192.168.10.100/24  GW: 192.168.10.1
└─────────────────────────────────────────
[10:42:01] Switching ens192 to port group: PG-VLAN10
    ✓ Port group switched
    ✓ Interface configured: 192.168.10.100/24 via 192.168.10.1
    ✓ Gateway reachable (RTT: 0.8ms, 0% loss)
    ✓ DNS resolved google.com → 142.250.179.174
    ✓ HTTP http://192.168.10.1 → 200
    ✓ Open ports on 192.168.10.1: 22/tcp 80/tcp 443/tcp
    ✓ MTU 1400 OK
    ✓ TCP reachable via port 443 open
    ✓ UDP reachable — DNS/UDP responded in 12ms
    ✓ Latency OK: min=0.4ms avg=0.8ms max=1.2ms loss=0%
```

---

## Test Battery

Every test is explicitly bound to the test NIC — none will accidentally route via the management NIC.

| Test | Tool | What it checks | PASS | FAIL / WARN |
|------|------|---------------|------|-------------|
| **Port Group Switch** | govc | Moves test NIC to target port group in vCenter | NIC moved | govc error — VLAN skipped |
| **Interface Config** | ip addr / ip route | Assigns IP, adds gateway host route scoped to test NIC | Correct IP assigned | ip failure (WARN) |
| **Ping Gateway** | ping -I $IFACE | ICMP bound to test NIC, records RTT and loss | 0% loss | Partial = WARN, 100% = FAIL |
| **Ping Extra Hosts** | ping -I $IFACE | ICMP to optional extra IPs | 0% loss | Any loss = FAIL |
| **DNS Resolution** | dig -b $SRC_IP | DNS query sourced from test NIC IP | Valid A record returned | No IP = FAIL |
| **HTTP Check** | curl --interface | HTTP fetch bound to test NIC | Code matches expected | Different code = FAIL |
| **Port Scan** | nmap -e $IFACE | TCP scan bound to test NIC and source IP | Open ports found | No open ports = WARN |
| **MTU Test** | ping -M do -s 1400 | 1400-byte DF ping bound to test NIC | Packets received | Dropped = WARN |
| **TCP Reachability** | nc -s $SRC_IP | TCP connect ports 80/443 from test NIC. Flags ICMP-blocked-but-TCP-open | TCP port responds | Both unreachable = FAIL |
| **UDP Test** | dig +notcp -b $SRC_IP | DNS/UDP query forced over UDP from test NIC IP | NOERROR response | Timeout = FAIL |
| **Latency Baseline** | ping -I $IFACE (10 pkts) | Min/avg/max RTT, warns if avg exceeds threshold | Within threshold | Avg exceeds threshold = WARN |

---

## Output

Results are written to a `vlan-reports/` directory after each run:

| File | Contents |
|------|----------|
| `results_TIMESTAMP.json` | Machine-readable array of every test result |
| `report_TIMESTAMP.html` | Dark-themed interactive HTML report — click port group rows to expand |

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `govc: cannot connect to vCenter` | Check `GOVC_URL`, credentials, and set `GOVC_INSECURE=1` for self-signed certs |
| `sudo: password prompt appears mid-run` | Add probe user to sudoers: `echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' \| sudo tee /etc/sudoers.d/probe` |
| `govc vm.network.change: no NIC named ethernet-1` | Run `govc device.info -vm <VM_NAME>` to find the correct NIC device name |
| Management NIC loses connectivity during run | Script only flushes routes scoped to the test NIC — never the global default route |
| Interface up but no traffic flows | Allow 3–5s after port group switch for vSwitch to update. Check ESXi host uplink trunking |
| MTU test fails on all VLANs | Check MTU settings on vSwitch, pNIC, and physical switch port |
| JSON parse error in report | Ensure `python3` is available — report generator uses standard library only |

---

## Changelog

| Version | Date | Changes |
|---------|------|---------|
| v1.0 | | Initial release — basic port group switch + ping test |
| v1.1 | | Added DNS, HTTP, port scan, MTU tests |
| v1.2 | | Added interactive HTML report and JSON output |
| v1.3 | | Added management NIC static/DHCP mode support |
| v1.4 | | Moved execution to run locally on probe VM, removed SSH dependency |
| v1.5 | | Removed management NIC setup — user preconfigures it |
| v1.6 | | Fixed HTML report row expand (overflow:hidden on table) |
| v1.7 | | Fixed MTU test result label |
| v1.8 | | Added script header with author, site, changelog |
| v1.9 | | Added TCP reachability, ICMP vs TCP comparison, UDP test, latency baseline |
| v1.10 | 2026-03-13 | Bound all tests to test NIC using `-I`, `--interface`, `-b`, `-s`, `-e` flags |

---

## License

MIT — free to use, modify, and share.
