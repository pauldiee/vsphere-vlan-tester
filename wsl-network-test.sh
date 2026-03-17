#!/bin/bash
# ============================================================
#  wsl-network-test.sh
#
#  Description:
#    Lightweight network connectivity tester for WSL.
#    Tests reachability of IPs and gateways directly from
#    the Windows host via WSL — no vSphere or govc needed.
#    Runs ping, DNS, HTTP/HTTPS and TCP checks and produces the
#    same interactive HTML report as vlan-test.sh.
#
#  Author : Paul van Dieen
#  Site   : https://www.hollebollevsan.nl
#  Repo   : https://github.com/pauldiee/vsphere-vlan-tester
#
#  Requirements:
#    - WSL (Ubuntu) on Windows
#    - curl, dig, nc
#      Install: sudo apt install dnsutils netcat-openbsd
#
#  Usage:
#    chmod +x wsl-network-test.sh
#    ./wsl-network-test.sh
#
#  Changelog:
#    v1.0  2026-03-16  Initial release
#    v1.1  2026-03-16  Added HTTP/HTTPS detection, -k flag for self-signed certs
#    v1.2  2026-03-16  Fixed HTTP status code comparison (quote stripping)
#    v1.3  2026-03-16  Added PARTIAL status when >50% of tests pass
#    v1.4  2026-03-16  Cleanup: fixed summary card order, added PARTIAL
#                      count to terminal summary
# ============================================================

# --- DNS settings ---
DNS_SERVER="8.8.8.8"
DNS_HOSTNAME="google.com"

# --- Latency warning threshold (ms) ---
LATENCY_WARN_MS=50

# --- Targets to test ---
# Format: "Label|IP|Gateway|HTTP_URL|Expected_HTTP_code"
# HTTP_URL can be http:// or https:// — leave empty to skip HTTP/S test
# For HTTPS with self-signed certs the test uses curl -k (insecure)
TARGETS=(
  "Server VLAN|192.168.10.1|192.168.10.1|http://192.168.10.1|200"
  "User VLAN|192.168.20.1|192.168.20.1|https://192.168.20.1|200"
  "DMZ VLAN|192.168.30.1|192.168.30.1||"
)

# --- Output ---
REPORT_DIR="$(pwd)/wsl-reports"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
JSON_FILE="$REPORT_DIR/results_$TIMESTAMP.json"
HTML_FILE="$REPORT_DIR/report_$TIMESTAMP.html"
mkdir -p "$REPORT_DIR"

# ============================================================
#  Helpers
# ============================================================
PASS="PASS"
FAIL="FAIL"
WARN="WARN"  # used in append_result calls

log()  { echo "[$(date +%H:%M:%S)] $*"; }
pass() { echo "    ✓ $*"; }
fail() { echo "    ✗ $*"; }

# ============================================================
#  JSON builder
# ============================================================
JSON_RESULTS="[]"

append_result() {
  local label="$1" test="$2" status="$3" detail="$4"
  JSON_RESULTS=$(echo "$JSON_RESULTS" | python3 -c "
import json, sys
data = json.load(sys.stdin)
data.append({'label': '$label', 'test': '$test', 'status': '$status', 'detail': $(echo "$detail" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read().strip()))")})
print(json.dumps(data))
")
}

# ============================================================
#  Pre-flight
# ============================================================
log "Pre-flight: checking required tools..."
MISSING=()
for tool in ping curl dig nc python3; do
  command -v "$tool" &>/dev/null || MISSING+=("$tool")
done
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "ERROR: Missing tools: ${MISSING[*]}"
  echo "  Install with: sudo apt install curl dnsutils netcat-openbsd"
  exit 1
fi

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║        WSL Network Tester                ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "  Targets : ${#TARGETS[@]}"
echo "  DNS     : $DNS_SERVER"
echo ""

# ============================================================
#  Main test loop
# ============================================================
for i in "${!TARGETS[@]}"; do
  IFS='|' read -r LABEL IP GW HTTP_URL HTTP_EXPECTED <<< "${TARGETS[$i]}"

  echo "┌─────────────────────────────────────────"
  echo "│  [$((i+1))/${#TARGETS[@]}] $LABEL"
  echo "│  IP: $IP  GW: $GW"
  echo "└─────────────────────────────────────────"

  # 1. Ping target IP
  log "Ping $IP..."
  PING_OUT=$(ping -c 4 -W 2 "$IP" 2>&1)
  PING_LOSS=$(echo "$PING_OUT" | grep -oP '\d+(?=% packet loss)')
  if [ "$PING_LOSS" = "0" ]; then
    RTT=$(echo "$PING_OUT" | grep -oP 'rtt.*= \K[\d.]+(?=/)' | head -1)
    pass "Reachable (RTT: ${RTT}ms, 0% loss)"
    append_result "$LABEL" "Ping" "$PASS" "0% loss, RTT ${RTT}ms"
  elif [ -n "$PING_LOSS" ] && [ "$PING_LOSS" -lt 100 ]; then
    fail "Partially reachable ($PING_LOSS% loss)"
    append_result "$LABEL" "Ping" "$WARN" "${PING_LOSS}% packet loss"
  else
    fail "Unreachable ($IP)"
    append_result "$LABEL" "Ping" "$FAIL" "100% packet loss"
  fi

  # 2. TCP reachability (ports 80, 443)
  log "TCP reachability (ports 80, 443)..."
  TCP_RESULT=""
  for PORT in 80 443; do
    if nc -zw3 "$IP" "$PORT" 2>/dev/null; then
      TCP_RESULT="port $PORT open"
      break
    fi
  done
  if [ -n "$TCP_RESULT" ]; then
    pass "TCP reachable via $TCP_RESULT"
    append_result "$LABEL" "TCP Reachability" "$PASS" "Reachable via TCP $TCP_RESULT"
    if [ "$PING_LOSS" = "100" ]; then
      fail "ICMP blocked but TCP works — host filters ping"
      append_result "$LABEL" "ICMP vs TCP" "$WARN" "ICMP blocked, TCP open"
    fi
  else
    fail "TCP ports 80 and 443 both unreachable on $IP"
    append_result "$LABEL" "TCP Reachability" "$FAIL" "No response on TCP 80 or 443"
  fi

  # 3. DNS resolution
  log "DNS resolution (via $DNS_SERVER)..."
  DNS_OUT=$(dig @"$DNS_SERVER" "$DNS_HOSTNAME" +short +time=3 2>&1)
  if echo "$DNS_OUT" | grep -qP '^\d+\.\d+\.\d+\.\d+'; then
    pass "DNS resolved $DNS_HOSTNAME → $(echo "$DNS_OUT" | head -1)"
    append_result "$LABEL" "DNS Resolution" "$PASS" "$DNS_HOSTNAME → $(echo "$DNS_OUT" | head -1)"
  else
    fail "DNS resolution failed"
    append_result "$LABEL" "DNS Resolution" "$FAIL" "$DNS_OUT"
  fi

  # 4. HTTP / HTTPS check (optional)
  if [ -n "$HTTP_URL" ]; then
    # Detect protocol and set label + curl flags accordingly
    if [[ "$HTTP_URL" == https://* ]]; then
      PROTO_LABEL="HTTPS"
      HTTP_OUT=$(curl -s -o /dev/null -w %{http_code} --connect-timeout 5 -k "$HTTP_URL" 2>/dev/null)
    else
      PROTO_LABEL="HTTP"
      HTTP_OUT=$(curl -s -o /dev/null -w %{http_code} --connect-timeout 5 "$HTTP_URL" 2>/dev/null)
    fi
    log "$PROTO_LABEL test: $HTTP_URL (expect $HTTP_EXPECTED)..."
    if [ "$HTTP_OUT" = "$HTTP_EXPECTED" ]; then
      pass "$PROTO_LABEL $HTTP_URL → $HTTP_OUT"
      append_result "$LABEL" "$PROTO_LABEL $HTTP_URL" "$PASS" "Got $PROTO_LABEL $HTTP_OUT"
    else
      fail "$PROTO_LABEL $HTTP_URL → got $HTTP_OUT, expected $HTTP_EXPECTED"
      append_result "$LABEL" "$PROTO_LABEL $HTTP_URL" "$FAIL" "Got $HTTP_OUT, expected $HTTP_EXPECTED"
    fi
  fi

  # 5. Latency baseline (10 pings)
  log "Latency baseline (10 pings to $IP)..."
  LAT_OUT=$(ping -c 10 -W 2 -i 0.2 "$IP" 2>&1)
  LAT_STATS=$(echo "$LAT_OUT" | grep -oP 'rtt.*= \K[\d.]+/[\d.]+/[\d.]+')
  if [ -n "$LAT_STATS" ]; then
    LAT_MIN=$(echo "$LAT_STATS" | cut -d'/' -f1)
    LAT_AVG=$(echo "$LAT_STATS" | cut -d'/' -f2)
    LAT_MAX=$(echo "$LAT_STATS" | cut -d'/' -f3)
    LAT_LOSS=$(echo "$LAT_OUT" | grep -oP '\d+(?=% packet loss)')
    LAT_DETAIL="min=${LAT_MIN}ms avg=${LAT_AVG}ms max=${LAT_MAX}ms loss=${LAT_LOSS}%"
    OVER_THRESHOLD=$(awk "BEGIN { print ($LAT_AVG > $LATENCY_WARN_MS) ? 1 : 0 }")
    if [ "$OVER_THRESHOLD" = "1" ]; then
      fail "High latency: avg ${LAT_AVG}ms exceeds ${LATENCY_WARN_MS}ms threshold"
      append_result "$LABEL" "Latency Baseline" "$WARN" "$LAT_DETAIL — avg exceeds ${LATENCY_WARN_MS}ms threshold"
    else
      pass "Latency OK: $LAT_DETAIL"
      append_result "$LABEL" "Latency Baseline" "$PASS" "$LAT_DETAIL"
    fi
  else
    fail "Latency baseline failed — no ping response"
    append_result "$LABEL" "Latency Baseline" "$FAIL" "No response from $IP"
  fi

  echo ""
done

# ============================================================
#  Save JSON
# ============================================================
echo "$JSON_RESULTS" | python3 -m json.tool > "$JSON_FILE"
log "JSON results saved: $JSON_FILE"

# ============================================================
#  Generate HTML Report
# ============================================================
log "Generating HTML report..."

PASS_COUNT=$(grep -o '"status": "PASS"' "$JSON_FILE" | wc -l)
FAIL_COUNT=$(grep -o '"status": "FAIL"' "$JSON_FILE" | wc -l)
WARN_COUNT=$(grep -o '"status": "WARN"' "$JSON_FILE" | wc -l)
PARTIAL_COUNT=$(python3 -c "
import json
results=json.load(open('$JSON_FILE'))
groups={}
for r in results:
    g=r['label']
    groups.setdefault(g,[]).append(r)
print(sum(1 for t in groups.values() if any(r['status']=='FAIL' for r in t) and sum(1 for r in t if r['status']=='PASS')>len(t)/2))
")

python3 << PYEOF
import json, datetime

with open("$JSON_FILE") as f:
    results = json.load(f)

ts       = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
pass_c   = sum(1 for r in results if r['status'] == 'PASS')
fail_c   = sum(1 for r in results if r['status'] == 'FAIL')
warn_c   = sum(1 for r in results if r['status'] == 'WARN')
total    = len(results)

# Group by label
groups = {}
for r in results:
    lb = r['label']
    if lb not in groups:
        groups[lb] = {'tests': []}
    groups[lb]['tests'].append(r)

partial_c = sum(1 for data in groups.values()
    if sum(1 for t in data['tests'] if t['status'] == 'FAIL') > 0
    and sum(1 for t in data['tests'] if t['status'] == 'PASS') > len(data['tests']) / 2)

rows = ""
for lb, data in groups.items():
    lb_pass = sum(1 for t in data['tests'] if t['status'] == 'PASS')
    lb_fail = sum(1 for t in data['tests'] if t['status'] == 'FAIL')
    lb_warn = sum(1 for t in data['tests'] if t['status'] == 'WARN')
    lb_total  = lb_pass + lb_fail + lb_warn
    if lb_fail == 0:
        lb_status = 'WARN' if lb_warn > 0 else 'PASS'
    elif lb_pass > lb_total / 2:
        lb_status = 'PARTIAL'
    else:
        lb_status = 'FAIL'
    rows += f'''
    <tr class="pg-header" data-pg="{lb}" onclick="toggleGroup(this)">
      <td class="pg-name">&#9658; {lb}</td>
      <td colspan="2"><span class="badge badge-pass">{lb_pass} pass</span> <span class="badge badge-warn">{lb_warn} warn</span> <span class="badge badge-fail">{lb_fail} fail</span></td>
      <td><span class="status-pill pill-{lb_status.lower()}">{lb_status}</span></td>
    </tr>'''
    for t in data['tests']:
        s    = t['status'].lower()
        icon = '✓' if t['status'] == 'PASS' else ('⚠' if t['status'] == 'WARN' else '✗')
        rows += f'''
    <tr class="test-row" data-group="{lb}" style="display:none">
      <td class="indent">&#8627; {t["test"]}</td>
      <td colspan="2">{t["detail"]}</td>
      <td><span class="status-pill pill-{s}">{icon} {t["status"]}</span></td>
    </tr>'''

html = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>WSL Network Test Report - {ts}</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;600&family=IBM+Plex+Sans:wght@300;400;600&display=swap');
  :root {{ --bg:#0d1117; --surface:#161b22; --border:#21262d; --text:#c9d1d9; --muted:#8b949e; --pass:#3fb950; --fail:#f85149; --warn:#d29922; --accent:#58a6ff; }}
  * {{ box-sizing:border-box; margin:0; padding:0; }}
  body {{ background:var(--bg); color:var(--text); font-family:'IBM Plex Sans',sans-serif; font-size:14px; line-height:1.6; padding:40px; }}
  header {{ border-bottom:1px solid var(--border); padding-bottom:24px; margin-bottom:32px; display:flex; justify-content:space-between; align-items:flex-end; }}
  header h1 {{ font-family:'IBM Plex Mono',monospace; font-size:22px; font-weight:600; color:#fff; letter-spacing:-0.5px; }}
  header .meta {{ font-family:'IBM Plex Mono',monospace; font-size:11px; color:var(--muted); text-align:right; line-height:1.8; }}
  .summary {{ display:grid; grid-template-columns:repeat(5,1fr); gap:16px; margin-bottom:32px; }}
  .stat-card {{ background:var(--surface); border:1px solid var(--border); border-radius:8px; padding:20px 24px; }}
  .stat-card .label {{ font-size:11px; text-transform:uppercase; letter-spacing:1px; color:var(--muted); margin-bottom:6px; font-family:'IBM Plex Mono',monospace; }}
  .stat-card .value {{ font-size:32px; font-weight:600; font-family:'IBM Plex Mono',monospace; }}
  .stat-card.s-pass .value {{ color:var(--pass); }} .stat-card.s-fail .value {{ color:var(--fail); }}
  .stat-card.s-warn .value {{ color:var(--warn); }} .stat-card.s-total .value {{ color:var(--accent); }} .stat-card.s-partial .value {{ color:var(--accent); }}
  table {{ width:100%; border-collapse:collapse; background:var(--surface); border:1px solid var(--border); border-radius:8px; }}
  thead th {{ background:#1c2128; font-family:'IBM Plex Mono',monospace; font-size:11px; text-transform:uppercase; letter-spacing:1px; color:var(--muted); padding:12px 16px; text-align:left; border-bottom:1px solid var(--border); }}
  td {{ padding:11px 16px; border-bottom:1px solid var(--border); vertical-align:middle; }}
  tr:last-child td {{ border-bottom:none; }}
  .pg-header {{ cursor:pointer; background:#1c2128; }} .pg-header:hover {{ background:#21262d; }}
  .pg-name {{ font-family:'IBM Plex Mono',monospace; font-weight:600; color:var(--accent); font-size:13px; }}
  .indent {{ font-family:'IBM Plex Mono',monospace; font-size:12px; color:var(--muted); padding-left:32px; }}
  .test-row {{ background:var(--bg); }} .test-row td {{ font-size:13px; }}
  .status-pill {{ display:inline-block; padding:2px 10px; border-radius:20px; font-family:'IBM Plex Mono',monospace; font-size:11px; font-weight:600; letter-spacing:0.5px; }}
  .pill-pass {{ background:rgba(63,185,80,0.15); color:var(--pass); border:1px solid rgba(63,185,80,0.3); }}
  .pill-fail {{ background:rgba(248,81,73,0.15); color:var(--fail); border:1px solid rgba(248,81,73,0.3); }}
  .pill-warn {{ background:rgba(210,153,34,0.15); color:var(--warn); border:1px solid rgba(210,153,34,0.3); }}
  .pill-partial {{ background:rgba(88,166,255,0.15); color:var(--accent); border:1px solid rgba(88,166,255,0.3); }}
  .badge {{ display:inline-block; padding:1px 7px; border-radius:4px; font-size:11px; font-family:'IBM Plex Mono',monospace; margin-right:4px; }}
  .badge-pass {{ background:rgba(63,185,80,0.1); color:var(--pass); }} .badge-fail {{ background:rgba(248,81,73,0.1); color:var(--fail); }} .badge-warn {{ background:rgba(210,153,34,0.1); color:var(--warn); }}
  footer {{ margin-top:40px; padding-top:20px; border-top:1px solid var(--border); font-size:11px; color:var(--muted); font-family:'IBM Plex Mono',monospace; text-align:center; }}
</style>
</head>
<body>
<header>
  <div>
    <h1>&#11041; WSL Network Test Report</h1>
    <div style="color:var(--muted);font-size:13px;margin-top:4px;">hollebollevsan.nl</div>
  </div>
  <div class="meta">Generated: {ts}<br>Targets tested: {len(groups)}<br>Total checks: {total}</div>
</header>
<div class="summary">
  <div class="stat-card s-total"><div class="label">Total Checks</div><div class="value">{total}</div></div>
  <div class="stat-card s-pass"><div class="label">Passed</div><div class="value">{pass_c}</div></div>
  <div class="stat-card s-warn"><div class="label">Warnings</div><div class="value">{warn_c}</div></div>
  <div class="stat-card s-partial"><div class="label">Partial</div><div class="value">{partial_c}</div></div>
  <div class="stat-card s-fail"><div class="label">Failed</div><div class="value">{fail_c}</div></div>
</div>
<table>
  <thead><tr><th>Target / Test</th><th colspan="2">Detail</th><th>Status</th></tr></thead>
  <tbody>{rows}</tbody>
</table>
<footer>wsl-network-test.sh &nbsp;·&nbsp; {ts} &nbsp;·&nbsp; click target rows to expand tests</footer>
<script>
function toggleGroup(header) {{
  const pg = header.getAttribute('data-pg');
  const nameCell = header.querySelector('.pg-name');
  const allRows = Array.from(document.querySelectorAll('.test-row'));
  const rows = allRows.filter(r => r.getAttribute('data-group') === pg);
  const visible = rows.length > 0 && rows[0].style.display !== 'none';
  rows.forEach(r => r.style.display = visible ? 'none' : 'table-row');
  if (nameCell) nameCell.innerHTML = (visible ? '&#9658; ' : '&#9660; ') + pg;
}}
</script>
</body></html>"""

with open("$HTML_FILE", "w") as f:
    f.write(html)
PYEOF

log "HTML report saved: $HTML_FILE"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║              Test Complete               ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "  ✓ PASS  : $PASS_COUNT"
echo "  ⚠ WARN  : $WARN_COUNT"
echo "  ✗ FAIL  : $FAIL_COUNT"
echo ""
echo "  JSON   → $JSON_FILE"
echo "  Report → $HTML_FILE"
echo ""

# Open report in Windows browser from WSL
if command -v explorer.exe &>/dev/null; then
  WINDOWS_PATH=$(wslpath -w "$HTML_FILE")
  explorer.exe "$WINDOWS_PATH"
  log "Report opened in Windows browser"
fi
