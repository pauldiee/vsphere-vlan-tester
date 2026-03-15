# vSphere VLAN Probe Tester

**Author:** Paul van Dieen  
**Site:** [www.hollebollevsan.nl](https://www.hollebollevsan.nl)

> Automated end-to-end VLAN validation for VMware vSphere environments. Runs an 11-test battery across every port group you define and produces an interactive HTML report.

---

## Files

| File | Description |
|------|-------------|
| `vlan-test.sh` | Main test script — runs locally on the Ubuntu probe VM |
| `Get-PortGroupData.ps1` | PowerCLI script — pulls port groups and NSX segments, writes `portgroups.json`. Prompts for credentials on first run and saves them encrypted. |
| `vlan-config-builder.html` | Browser-based tool — builds the `VLANS=()` config block. Supports manual entry and JSON import from `portgroups.json`. |
| `vlan-test-guide.docx` | Full user and configuration guide |

---

## How it works

1. A dedicated Ubuntu VM with two NICs acts as a network probe
2. `vlan-test.sh` uses `govc` to rotate the test NIC between port groups
3. For each VLAN it assigns an IP locally and runs 11 tests — all bound to the test NIC
4. Results are written to a JSON file and an interactive HTML report

---

## Quick start

### 1. Set up the probe VM

The probe needs two NICs:

- **Management NIC** (`ens160`) — configure with DHCP or static IP in Netplan, never touched by the script
- **Test NIC** (`ens192`) — leave unconfigured in Netplan, the script manages it

```yaml
# /etc/netplan/00-installer-config.yaml
network:
  version: 2
  ethernets:
    ens160:
      dhcp4: true
    ens192:
      dhcp4: false
```

Install govc:

```bash
curl -L https://github.com/vmware/govmomi/releases/latest/download/govc_Linux_x86_64.tar.gz | tar -xz && sudo mv govc /usr/local/bin/
```

Enable passwordless sudo:

```bash
echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/probe
```

### 2. Build your VLAN list

Option A — open `vlan-config-builder.html` in a browser and fill in manually.

Option B — run `Get-PortGroupData.ps1` on a Windows machine with PowerCLI. It will prompt for vCenter and NSX credentials on first run and save them encrypted for subsequent runs. Load the resulting `portgroups.json` into the config builder using the "Load from vCenter / NSX" button. To reset saved credentials run `Get-PortGroupData.ps1 -Reset`.

### 3. Configure the script

Edit the config block at the top of `vlan-test.sh`:

```bash
export GOVC_URL="https://vcenter.yourdomain.local"
export GOVC_USERNAME="administrator@vsphere.local"
export GOVC_PASSWORD='yourpassword'   # single quotes required for special characters
export GOVC_INSECURE=1

VM_NAME="ubuntu-probe"
IFACE="ens192"

VLANS=(
  "PG-VLAN10|192.168.10.100/24|192.168.10.1|Server VLAN"
  "PG-VLAN20|192.168.20.100/24|192.168.20.1|User VLAN"
)
```

### 4. Run

```bash
chmod +x vlan-test.sh
./vlan-test.sh
```

Reports are written to `./vlan-reports/`.

---

## Test battery

| # | Test | Tool | Bound to test NIC |
|---|------|------|:-----------------:|
| 1 | Port group switch | govc | — |
| 2 | Interface config | ip addr / ip route | ✓ |
| 3 | Ping gateway | ping `-I $IFACE` | ✓ |
| 4 | Ping extra hosts | ping `-I $IFACE` | ✓ |
| 5 | DNS resolution | dig `-b $SRC_IP` | ✓ |
| 6 | HTTP check | curl `--interface $IFACE` | ✓ |
| 7 | Port scan | nmap `-e $IFACE -S $SRC_IP` | ✓ |
| 8 | MTU test (1400 byte) | ping `-I $IFACE -M do -s 1400` | ✓ |
| 9 | TCP reachability vs ICMP | nc `-s $SRC_IP` | ✓ |
| 10 | UDP test (DNS/53) | dig `-b $SRC_IP +notcp` | ✓ |
| 11 | Latency baseline | ping `-I $IFACE` (10 packets) | ✓ |

---

## Changelog

### vlan-test.sh
| Version | Date | Changes |
|---------|------|---------|
| v1.0 | | Initial release — basic port group switch + ping test |
| v1.1 | | Added richer test battery: DNS, HTTP, port scan, MTU |
| v1.2 | | Added HTML report with interactive expand/collapse and JSON output |
| v1.3 | | Added management NIC static/DHCP mode support |
| v1.4 | | Moved execution to run locally on probe VM, removed SSH dependency |
| v1.5 | | Removed management NIC setup — user preconfigures it |
| v1.6 | | Fixed HTML report row expand (overflow:hidden on table) |
| v1.7 | | Fixed MTU test result label (large -> 1400-byte) |
| v1.8 | | Added script header with author, site, changelog |
| v1.9 | | Added TCP reachability, ICMP vs TCP comparison, UDP test, latency baseline |
| v1.10 | 2026-03-13 | Bound all tests to test NIC |

### Get-PortGroupData.ps1
| Version | Date | Changes |
|---------|------|---------|
| v1.0 | 2026-03-13 | Initial release — vSphere VDS/VSS and NSX segment export |
| v1.1 | 2026-03-13 | Interactive credential prompts with encrypted save/load via DPAPI |
| v1.2 | 2026-03-13 | Fixed null VDSwitch/Notes properties, added -Standard flag to Get-VirtualPortGroup |
| v1.3 | 2026-03-13 | Added source selection prompt (vCenter/NSX/Both) and -Source parameter |

### vlan-config-builder.html
| Version | Date | Changes |
|---------|------|---------|
| v1.0 | 2026-03-13 | Initial release |
| v1.1 | 2026-03-13 | Dark mode and larger layout |
| v1.2 | 2026-03-13 | vCenter/NSX JSON import with source badges and selection modal |
| v1.3 | 2026-03-13 | Fixed gateway stripping subnet prefix, IP derived from subnet, description falls back to port group name, source column spacing |
| v1.4 | 2026-03-13 | Updated source column width and badge padding |

---

## Requirements

- Ubuntu 20.04+ probe VM
- govc installed on the probe VM
- Passwordless sudo on the probe VM
- nmap, dnsutils, curl (auto-installed by the script if missing)
- PowerCLI (Windows, for `Get-PortGroupData.ps1` only)
- Network access from probe VM to vCenter on port 443

---

*More tools and guides at [www.hollebollevsan.nl](https://www.hollebollevsan.nl)*
