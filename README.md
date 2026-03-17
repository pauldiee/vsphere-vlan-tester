# vSphere VLAN Probe Tester

**Author:** Paul van Dieen  
**Site:** [www.hollebollevsan.nl](https://www.hollebollevsan.nl)  
**Repo:** [github.com/pauldiee/vsphere-vlan-tester](https://github.com/pauldiee/vsphere-vlan-tester)

> A complete toolset for automated network validation in VMware vSphere environments. From VLAN testing on a dedicated probe VM to quick connectivity checks from WSL or Windows — with browser-based config builders and vCenter/NSX data import to make setup fast.

---

## Toolset overview

| Tool | Platform | Purpose |
|------|----------|---------|
| `vlan-test.sh` | Ubuntu probe VM | Full 11-test VLAN battery via vSphere port group rotation |
| `wsl-network-test.sh` | WSL (Ubuntu on Windows) | Lightweight connectivity tester — ping, DNS, HTTP/S, TCP, latency |
| `ps-network-test.ps1` | Windows PowerShell | Ping and DNS tester, reads same target config as WSL script |
| `Get-PortGroupData.ps1` | Windows PowerShell | Pulls port groups and NSX segments from vCenter, writes JSON |
| `Get-VMData.ps1` | Windows PowerShell | Pulls powered-on VM IPs and gateways from vCenter, writes JSON |
| `vlan-config-builder.html` | Browser | Builds `VLANS=()` config block for `vlan-test.sh` |
| `wsl-config-builder.html` | Browser | Builds `TARGETS=()` config block for WSL and PowerShell testers |
| `vlan-test-guide.docx` | — | Full user and configuration guide |

---

## vlan-test.sh

Runs directly on a dedicated Ubuntu probe VM. Uses `govc` (VMware's CLI) to rotate the test NIC between vSphere port groups and runs an 11-test battery for each VLAN. Every test is explicitly bound to the test NIC — none will accidentally route via the management NIC.

### Two-NIC design

The probe VM needs two network adapters:

- **Management NIC** (`ens160`) — configured with DHCP or static IP in Netplan, never touched by the script. Provides a stable terminal session throughout the run.
- **Test NIC** (`ens192`) — left unconfigured in Netplan. The script rotates this between port groups and re-IPs it per VLAN.

### Setup

```bash
# Netplan — leave test NIC bare
network:
  version: 2
  ethernets:
    ens160:
      dhcp4: true
    ens192:
      dhcp4: false

# Install govc
curl -L https://github.com/vmware/govmomi/releases/latest/download/govc_Linux_x86_64.tar.gz | tar -xz && sudo mv govc /usr/local/bin/

# Passwordless sudo
echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/probe
```

### Configuration

```bash
export GOVC_URL="https://vcenter.yourdomain.local"
export GOVC_USERNAME="administrator@vsphere.local"
export GOVC_PASSWORD='yourpassword'   # single quotes — prevents bash interpreting ! and $
export GOVC_INSECURE=1

VM_NAME="ubuntu-probe"
IFACE="ens192"
LATENCY_WARN_MS=50

VLANS=(
  "PG-VLAN10|192.168.10.100/24|192.168.10.1|Server VLAN"
  "PG-VLAN20|192.168.20.100/24|192.168.20.1|User VLAN"
)
```

### Test battery

| # | Test | Tool | Bound to test NIC |
|---|------|------|:-----------------:|
| 1 | Port group switch | govc | — |
| 2 | Interface config | ip addr / ip route | ✓ |
| 3 | Ping gateway | ping `-I $IFACE` | ✓ |
| 4 | Ping extra hosts | ping `-I $IFACE` | ✓ |
| 5 | DNS resolution | dig `-b $SRC_IP` | ✓ |
| 6 | HTTP check | curl `--interface $IFACE` | ✓ |
| 7 | Port scan (top 20 TCP) | nmap `-e $IFACE -S $SRC_IP` | ✓ |
| 8 | MTU test (1400 byte) | ping `-I $IFACE -M do -s 1400` | ✓ |
| 9 | TCP reachability vs ICMP | nc `-s $SRC_IP` | ✓ |
| 10 | UDP test (DNS/53) | dig `-b $SRC_IP +notcp` | ✓ |
| 11 | Latency baseline | ping `-I $IFACE` (10 packets) | ✓ |

### Run

```bash
chmod +x vlan-test.sh
./vlan-test.sh
```

Reports written to `./vlan-reports/` — JSON and interactive HTML.

---

## wsl-network-test.sh

Lightweight connectivity tester for WSL. No vSphere dependency — tests a direct list of IPs and gateways from the Windows host network stack. Produces the same dark HTML report as `vlan-test.sh`.

### Tests per target

| Test | Tool |
|------|------|
| Ping | ping (4 packets, RTT + loss) |
| TCP reachability | nc (ports 80 and 443) |
| ICMP vs TCP detection | flags if ICMP blocked but TCP open |
| DNS resolution | dig (UDP, configurable server) |
| HTTP/HTTPS check | curl (auto-detects protocol, -k for self-signed certs) |
| Latency baseline | ping (10 packets, min/avg/max) |

### Setup

```bash
sudo apt install dnsutils netcat-openbsd
chmod +x wsl-network-test.sh
```

### Configuration

```bash
TARGETS=(
  "Server VLAN|192.168.10.1|192.168.10.1|http://192.168.10.1|200"
  "User VLAN|192.168.20.1|192.168.20.1|https://192.168.20.1|200"
  "DMZ VLAN|192.168.30.1|192.168.30.1||"   # leave HTTP fields empty to skip
)
```

Use `wsl-config-builder.html` to build the TARGETS block visually. The report auto-opens in the Windows browser after each run.

---

## ps-network-test.ps1

Windows PowerShell version of the connectivity tester. Reads the same `wsl-targets-config.txt` exported by `wsl-config-builder.html` — drop it next to the script and it loads automatically. Falls back to the inline `$INLINE_TARGETS` array if no file is found.

### Tests per target

| Test | Tool |
|------|------|
| Ping | `Test-Connection` (4 packets, avg/max RTT, latency threshold warning) |
| Reverse DNS (PTR) | `Resolve-DnsName` on target IP — always runs |
| Forward DNS | `Resolve-DnsName` on label — only if label looks like a hostname, checks result matches target IP |

### Run

```powershell
.\ps-network-test.ps1

# Point at a specific config file
.\ps-network-test.ps1 -ConfigFile "C:\configs\my-targets.txt"
```

Report saved to `ps-reports\` and auto-opened in the default browser.

---

## Get-PortGroupData.ps1

PowerCLI script that connects to vCenter and optionally NSX Manager, pulls all port groups and segments, and writes `portgroups.json`. Load this file into `vlan-config-builder.html` to pre-populate the VLAN list without manual entry.

### Features

- Pulls VDS distributed port groups, VSS standard port groups, and NSX segments
- Captures VLAN ID, subnet, gateway, and description per entry
- Prompts for credentials interactively on first run and saves them encrypted via Windows DPAPI
- Source selection: vCenter only, NSX only, or both

### Run

```powershell
.\Get-PortGroupData.ps1                   # prompts for source selection
.\Get-PortGroupData.ps1 -Source vCenter   # vCenter only, no prompt
.\Get-PortGroupData.ps1 -Source NSX       # NSX only, no prompt
.\Get-PortGroupData.ps1 -Source Both      # both, no prompt
.\Get-PortGroupData.ps1 -Reset            # clear saved credentials
```

---

## Get-VMData.ps1

PowerCLI script that pulls all powered-on VMs from vCenter that have VMware Tools running and a valid IPv4 address. Writes `vmdata.json` which can be loaded into `wsl-config-builder.html` to populate test targets with real VM IPs and gateways.

### Features

- Filters to powered-on VMs with VMware Tools running
- Extracts primary IPv4 address from guest NIC info
- Extracts default gateway from guest OS routing table
- Same DPAPI credential save/load as `Get-PortGroupData.ps1`

### Run

```powershell
.\Get-VMData.ps1         # normal run
.\Get-VMData.ps1 -Reset  # clear saved credentials
```

---

## vlan-config-builder.html

Browser-based tool for building the `VLANS=()` config block for `vlan-test.sh`. Open in any modern browser — no server required.

### Features

- Manual entry with live IP/prefix/gateway validation
- Import from `portgroups.json` with selection modal — auto-derives probe IP from subnet, strips prefix from gateway, falls back to port group name as description
- Source badge per row: VDS, VSS, NSX, or manual
- Export config to `vlans-config.txt` for reuse
- Import previously exported `vlans-config.txt`
- Generate and copy `VLANS=()` block with one click

---

## wsl-config-builder.html

Browser-based tool for building the `TARGETS=()` config block for both `wsl-network-test.sh` and `ps-network-test.ps1`. Open in any modern browser — no server required.

### Features

- Manual entry with live IP/gateway validation
- HTTP/HTTPS URL per target with expected status code
- Import from `vmdata.json` with selection modal showing VM name, IP and gateway
- Import from `portgroups.json` for gateway-per-segment testing
- Export config to `wsl-targets-config.txt` — shared between WSL and PowerShell scripts
- Import previously exported `wsl-targets-config.txt`

---

## Report format

All three test scripts produce the same dark-themed interactive HTML report:

- Summary scorecard: Total / Pass / Warn / Partial / Fail
- Expandable rows per target/VLAN showing individual test results
- PARTIAL status when more than 50% of tests pass but at least one fails
- JSON result file alongside each HTML report for scripted consumption or diff between runs

---

## Requirements

### vlan-test.sh
- Ubuntu 20.04+ probe VM with two NICs
- `govc` installed and in PATH
- Passwordless sudo
- `nmap`, `dnsutils`, `curl` (auto-installed if missing)
- Network access from probe to vCenter on port 443

### wsl-network-test.sh
- WSL (Ubuntu) on Windows
- `sudo apt install dnsutils netcat-openbsd`

### ps-network-test.ps1
- Windows PowerShell 5.1+ or PowerShell 7+
- No extra modules required

### Get-PortGroupData.ps1 / Get-VMData.ps1
- VMware.PowerCLI module
- VMware Tools running on target VMs (for `Get-VMData.ps1` only)

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
| v1.11 | 2026-03-16 | Added PARTIAL status when >50% of tests pass |
| v1.12 | 2026-03-16 | Cleanup: removed duplicate LATENCY_WARN_MS, added PARTIAL to terminal summary |

### wsl-network-test.sh
| Version | Date | Changes |
|---------|------|---------|
| v1.0 | 2026-03-16 | Initial release — ping, DNS, HTTP/HTTPS, TCP, latency baseline |
| v1.1 | 2026-03-16 | Added HTTP/HTTPS detection with -k flag for self-signed certs |
| v1.2 | 2026-03-16 | Fixed HTTP status code comparison |
| v1.3 | 2026-03-16 | Added PARTIAL status when >50% of tests pass |
| v1.4 | 2026-03-16 | Cleanup: fixed summary card order, added PARTIAL to terminal summary |

### ps-network-test.ps1
| Version | Date | Changes |
|---------|------|---------|
| v1.0 | 2026-03-16 | Initial release — ping and DNS via Test-Connection and Resolve-DnsName |
| v1.1 | 2026-03-16 | DNS now does PTR on target IP + forward lookup if label is a hostname |

### Get-PortGroupData.ps1
| Version | Date | Changes |
|---------|------|---------|
| v1.0 | 2026-03-13 | Initial release — vSphere VDS/VSS and NSX segment export |
| v1.1 | 2026-03-13 | Interactive credential prompts with encrypted save/load via DPAPI |
| v1.2 | 2026-03-13 | Fixed null VDSwitch/Notes properties, added -Standard flag to Get-VirtualPortGroup |
| v1.3 | 2026-03-13 | Added source selection prompt (vCenter/NSX/Both) and -Source parameter |

### Get-VMData.ps1
| Version | Date | Changes |
|---------|------|---------|
| v1.0 | 2026-03-16 | Initial release — pulls powered-on VMs with IPs and gateways from vCenter |

### vlan-config-builder.html
| Version | Date | Changes |
|---------|------|---------|
| v1.0 | 2026-03-13 | Initial release |
| v1.1 | 2026-03-13 | Dark mode and larger layout |
| v1.2 | 2026-03-13 | vCenter/NSX JSON import with source badges and selection modal |
| v1.3 | 2026-03-13 | Fixed gateway stripping subnet prefix, IP derived from subnet, description falls back to port group name, source column spacing |
| v1.4 | 2026-03-13 | Updated source column width and badge padding |
| v1.5 | 2026-03-16 | Added export to file and import saved config buttons |

### wsl-config-builder.html
| Version | Date | Changes |
|---------|------|---------|
| v1.0 | 2026-03-16 | Initial release |
| v1.1 | 2026-03-16 | Added export to file button |
| v1.2 | 2026-03-16 | Added import saved config (.txt) button |
| v1.3 | 2026-03-16 | Added Load from vCenter VMs (vmdata.json) with selection modal |

---

*More tools and guides at [www.hollebollevsan.nl](https://www.hollebollevsan.nl)*
