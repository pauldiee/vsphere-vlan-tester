# ============================================================
#  ps-network-test.ps1
#
#  Description:
#    Lightweight network connectivity tester for Windows.
#    Runs ping, reverse DNS (PTR) and optional forward DNS
#    lookups against a list of targets and
#    produces console output plus an interactive HTML report.
#
#    Target list is read from wsl-targets-config.txt if found
#    next to this script, otherwise falls back to the inline
#    TARGETS array defined below.
#
#  Author : Paul van Dieen
#  Site   : https://www.hollebollevsan.nl
#  Repo   : https://github.com/pauldiee/vsphere-vlan-tester
#
#  Requirements:
#    - Windows PowerShell 5.1+ or PowerShell 7+
#    - No additional modules needed
#
#  Usage:
#    .\ps-network-test.ps1
#    .\ps-network-test.ps1 -ConfigFile "C:\path\to\targets.txt"
#
#  Changelog:
#    v1.0  2026-03-16  Initial release
#    v1.1  2026-03-16  DNS now does PTR on target IP + forward lookup
#                      if label looks like a hostname
# ============================================================

param(
    [string]$ConfigFile = ""
)

# --- DNS settings ---
$DNS_SERVER   = "8.8.8.8"
# --- Latency warning threshold (ms) ---
$LATENCY_WARN_MS = 50

# --- Inline fallback targets ---
# Format: "Label|IP|Gateway|HTTP_URL|Expected_HTTP_code"
$INLINE_TARGETS = @(
    "Server VLAN|192.168.10.1|192.168.10.1||"
    "User VLAN|192.168.20.1|192.168.20.1||"
    "DMZ VLAN|192.168.30.1|192.168.30.1||"
)

# --- Output ---
$ReportDir  = Join-Path (Get-Location) "ps-reports"
$Timestamp  = Get-Date -Format "yyyyMMdd_HHmmss"
$HtmlFile   = Join-Path $ReportDir "report_$Timestamp.html"
$null = New-Item -ItemType Directory -Force -Path $ReportDir

# ============================================================
#  Load targets
# ============================================================
function Parse-Targets {
    param([string[]]$Lines)
    $targets = @()
    foreach ($line in $Lines) {
        $line = $line.Trim()
        if ($line -match '"([^"]+)\|([^"]+)\|([^"]+)\|([^"]*)\|([^"]*)"') {
            $targets += [PSCustomObject]@{
                Label    = $Matches[1]
                IP       = $Matches[2]
                Gateway  = $Matches[3]
                HttpUrl  = $Matches[4]
                HttpCode = $Matches[5]
            }
        }
    }
    return $targets
}

$configPath = if ($ConfigFile) { $ConfigFile } else { Join-Path $PSScriptRoot "wsl-targets-config.txt" }

if (Test-Path $configPath) {
    Write-Host "[Config] Loading targets from $configPath" -ForegroundColor DarkGray
    $rawLines = Get-Content $configPath
    $targets  = Parse-Targets $rawLines
    if ($targets.Count -eq 0) {
        Write-Warning "[Config] No valid targets found in file - falling back to inline targets"
        $targets = Parse-Targets $INLINE_TARGETS
    }
} else {
    Write-Host "[Config] Config file not found - using inline targets" -ForegroundColor DarkGray
    $targets = Parse-Targets $INLINE_TARGETS
}

# ============================================================
#  Helpers
# ============================================================
$results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Result {
    param($Label, $Test, $Status, $Detail)
    $results.Add([PSCustomObject]@{
        Label  = $Label
        Test   = $Test
        Status = $Status
        Detail = $Detail
    })
}

function Write-Pass { param($msg) Write-Host "    v $msg" -ForegroundColor Green }
function Write-Fail { param($msg) Write-Host "    x $msg" -ForegroundColor Red }
function Write-Warn { param($msg) Write-Host "    ! $msg" -ForegroundColor Yellow }

# ============================================================
#  Banner
# ============================================================
Write-Host ""
Write-Host "  +==========================================+" -ForegroundColor Cyan
Write-Host "  |     Windows Network Tester               |" -ForegroundColor Cyan
Write-Host "  |     hollebollevsan.nl                    |" -ForegroundColor Cyan
Write-Host "  +==========================================+" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Targets : $($targets.Count)"
Write-Host "  DNS server : $DNS_SERVER"
Write-Host ""

# ============================================================
#  Main test loop
# ============================================================
foreach ($target in $targets) {
    $label = $target.Label
    $ip    = $target.IP

    Write-Host "+------------------------------------------" -ForegroundColor DarkGray
    Write-Host "| $label" -ForegroundColor White
    Write-Host "| IP: $ip  GW: $($target.Gateway)" -ForegroundColor DarkGray
    Write-Host "+------------------------------------------" -ForegroundColor DarkGray

    # 1. Ping
    Write-Host "[$(Get-Date -Format HH:mm:ss)] Ping $ip..." -ForegroundColor DarkGray
    try {
        $pingResults = Test-Connection -ComputerName $ip -Count 4 -ErrorAction Stop
        $avgRtt  = [math]::Round(($pingResults | Measure-Object -Property ResponseTime -Average).Average, 1)
        $maxRtt  = ($pingResults | Measure-Object -Property ResponseTime -Maximum).Maximum
        $loss    = [math]::Round((($pingResults | Where-Object { $_.StatusCode -ne 0 }).Count / 4) * 100)
        $detail  = "0% loss, avg ${avgRtt}ms max ${maxRtt}ms"

        if ($loss -eq 0) {
            if ($avgRtt -gt $LATENCY_WARN_MS) {
                Write-Warn "Reachable but high latency: $detail"
                Add-Result $label "Ping" "WARN" "High latency: $detail"
            } else {
                Write-Pass "Reachable: $detail"
                Add-Result $label "Ping" "PASS" $detail
            }
        } else {
            Write-Warn "Partial loss ($loss%): $detail"
            Add-Result $label "Ping" "WARN" "${loss}% packet loss, avg ${avgRtt}ms"
        }
    } catch {
        Write-Fail "Unreachable ($ip)"
        Add-Result $label "Ping" "FAIL" "Host unreachable"
    }

    # 2a. Reverse DNS (PTR) on the target IP
    Write-Host "[$(Get-Date -Format HH:mm:ss)] Reverse DNS (PTR) for $ip via $DNS_SERVER..." -ForegroundColor DarkGray
    try {
        $ptrResult = Resolve-DnsName -Name $ip -Server $DNS_SERVER -Type PTR -ErrorAction Stop
        $ptrNames  = ($ptrResult | Where-Object { $_.Type -eq 'PTR' } | Select-Object -ExpandProperty NameHost) -join ", "
        if ($ptrNames) {
            Write-Pass "PTR $ip -> $ptrNames"
            Add-Result $label "Reverse DNS (PTR)" "PASS" "$ip -> $ptrNames"
        } else {
            Write-Warn "No PTR record for $ip"
            Add-Result $label "Reverse DNS (PTR)" "WARN" "No PTR record found for $ip"
        }
    } catch {
        Write-Warn "No PTR record for $ip (no reverse DNS configured)"
        Add-Result $label "Reverse DNS (PTR)" "WARN" "PTR lookup failed: $($_.Exception.Message)"
    }

    # 2b. Forward DNS — only if the label looks like a hostname (contains a dot, not an IP)
    $looksLikeHostname = ($label -match '\.' -and $label -notmatch '^\d+\.\d+\.\d+\.\d+$')
    if ($looksLikeHostname) {
        Write-Host "[$(Get-Date -Format HH:mm:ss)] Forward DNS for $label via $DNS_SERVER..." -ForegroundColor DarkGray
        try {
            $fwdResult  = Resolve-DnsName -Name $label -Server $DNS_SERVER -Type A -ErrorAction Stop
            $fwdIPs     = ($fwdResult | Where-Object { $_.Type -eq 'A' } | Select-Object -ExpandProperty IPAddress) -join ", "
            if ($fwdIPs) {
                $matches_ip = $fwdIPs -split ", " | Where-Object { $_ -eq $ip }
                if ($matches_ip) {
                    Write-Pass "Forward DNS $label -> $fwdIPs (matches target IP)"
                    Add-Result $label "Forward DNS" "PASS" "$label -> $fwdIPs (matches target IP)"
                } else {
                    Write-Warn "Forward DNS $label -> $fwdIPs (does not match target IP $ip)"
                    Add-Result $label "Forward DNS" "WARN" "$label -> $fwdIPs (expected $ip)"
                }
            } else {
                Write-Fail "No A records for $label"
                Add-Result $label "Forward DNS" "FAIL" "No A records returned for $label"
            }
        } catch {
            Write-Fail "Forward DNS failed for $label"
            Add-Result $label "Forward DNS" "FAIL" "Forward lookup failed: $($_.Exception.Message)"
        }
    }

    Write-Host ""
}

# ============================================================
#  Console summary
# ============================================================
$passCount    = ($results | Where-Object { $_.Status -eq 'PASS' }).Count
$warnCount    = ($results | Where-Object { $_.Status -eq 'WARN' }).Count
$failCount    = ($results | Where-Object { $_.Status -eq 'FAIL' }).Count
$partialCount = 0

$groups = $results | Group-Object -Property Label
foreach ($group in $groups) {
    $gPass = ($group.Group | Where-Object { $_.Status -eq 'PASS' }).Count
    $gFail = ($group.Group | Where-Object { $_.Status -eq 'FAIL' }).Count
    $gTotal = $group.Group.Count
    if ($gFail -gt 0 -and $gPass -gt ($gTotal / 2)) { $partialCount++ }
}

Write-Host "+==========================================+" -ForegroundColor Cyan
Write-Host "|            Test Complete                 |" -ForegroundColor Cyan
Write-Host "+==========================================+" -ForegroundColor Cyan
Write-Host ""
Write-Host "  v PASS    : $passCount"    -ForegroundColor Green
Write-Host "  ! WARN    : $warnCount"    -ForegroundColor Yellow
Write-Host "  ~ PARTIAL : $partialCount" -ForegroundColor Blue
Write-Host "  x FAIL    : $failCount"    -ForegroundColor Red
Write-Host ""

# ============================================================
#  Generate HTML report
# ============================================================
Write-Host "[Report] Generating HTML report..." -ForegroundColor DarkGray

$ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$total = $results.Count

# Build grouped rows
$groupedRows = ""
$groups = $results | Group-Object -Property Label
foreach ($group in $groups) {
    $lb       = $group.Name
    $lbPass   = ($group.Group | Where-Object { $_.Status -eq 'PASS' }).Count
    $lbFail   = ($group.Group | Where-Object { $_.Status -eq 'FAIL' }).Count
    $lbWarn   = ($group.Group | Where-Object { $_.Status -eq 'WARN' }).Count
    $lbTotal  = $group.Group.Count
    if ($lbFail -eq 0) {
        $lbStatus = if ($lbWarn -gt 0) { 'WARN' } else { 'PASS' }
    } elseif ($lbPass -gt ($lbTotal / 2)) {
        $lbStatus = 'PARTIAL'
    } else {
        $lbStatus = 'FAIL'
    }

    $groupedRows += @"
    <tr class="pg-header" data-pg="$lb" onclick="toggleGroup(this)">
      <td class="pg-name">&#9658; $lb</td>
      <td colspan="2"><span class="badge badge-pass">$lbPass pass</span> <span class="badge badge-warn">$lbWarn warn</span> <span class="badge badge-fail">$lbFail fail</span></td>
      <td><span class="status-pill pill-$($lbStatus.ToLower())">$lbStatus</span></td>
    </tr>
"@
    foreach ($r in $group.Group) {
        $s    = $r.Status.ToLower()
        $icon = if ($r.Status -eq 'PASS') { '&#10003;' } elseif ($r.Status -eq 'WARN') { '&#9888;' } else { '&#10007;' }
        $groupedRows += @"
    <tr class="test-row" data-group="$lb" style="display:none">
      <td class="indent">&#8627; $($r.Test)</td>
      <td colspan="2">$($r.Detail)</td>
      <td><span class="status-pill pill-$s">$icon $($r.Status)</span></td>
    </tr>
"@
    }
}

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Windows Network Test Report - $ts</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;600&family=IBM+Plex+Sans:wght@300;400;600&display=swap');
  :root { --bg:#0d1117; --surface:#161b22; --border:#21262d; --text:#c9d1d9; --muted:#8b949e; --pass:#3fb950; --fail:#f85149; --warn:#d29922; --accent:#58a6ff; }
  * { box-sizing:border-box; margin:0; padding:0; }
  body { background:var(--bg); color:var(--text); font-family:'IBM Plex Sans',sans-serif; font-size:14px; line-height:1.6; padding:40px; }
  header { border-bottom:1px solid var(--border); padding-bottom:24px; margin-bottom:32px; display:flex; justify-content:space-between; align-items:flex-end; }
  header h1 { font-family:'IBM Plex Mono',monospace; font-size:22px; font-weight:600; color:#fff; letter-spacing:-0.5px; }
  header .meta { font-family:'IBM Plex Mono',monospace; font-size:11px; color:var(--muted); text-align:right; line-height:1.8; }
  .summary { display:grid; grid-template-columns:repeat(5,1fr); gap:16px; margin-bottom:32px; }
  .stat-card { background:var(--surface); border:1px solid var(--border); border-radius:8px; padding:20px 24px; }
  .stat-card .label { font-size:11px; text-transform:uppercase; letter-spacing:1px; color:var(--muted); margin-bottom:6px; font-family:'IBM Plex Mono',monospace; }
  .stat-card .value { font-size:32px; font-weight:600; font-family:'IBM Plex Mono',monospace; }
  .stat-card.s-pass .value { color:var(--pass); } .stat-card.s-fail .value { color:var(--fail); }
  .stat-card.s-warn .value { color:var(--warn); } .stat-card.s-total .value { color:var(--accent); } .stat-card.s-partial .value { color:var(--accent); }
  table { width:100%; border-collapse:collapse; background:var(--surface); border:1px solid var(--border); border-radius:8px; }
  thead th { background:#1c2128; font-family:'IBM Plex Mono',monospace; font-size:11px; text-transform:uppercase; letter-spacing:1px; color:var(--muted); padding:12px 16px; text-align:left; border-bottom:1px solid var(--border); }
  td { padding:11px 16px; border-bottom:1px solid var(--border); vertical-align:middle; }
  tr:last-child td { border-bottom:none; }
  .pg-header { cursor:pointer; background:#1c2128; } .pg-header:hover { background:#21262d; }
  .pg-name { font-family:'IBM Plex Mono',monospace; font-weight:600; color:var(--accent); font-size:13px; }
  .indent { font-family:'IBM Plex Mono',monospace; font-size:12px; color:var(--muted); padding-left:32px; }
  .test-row { background:var(--bg); } .test-row td { font-size:13px; }
  .status-pill { display:inline-block; padding:2px 10px; border-radius:20px; font-family:'IBM Plex Mono',monospace; font-size:11px; font-weight:600; letter-spacing:0.5px; }
  .pill-pass { background:rgba(63,185,80,0.15); color:var(--pass); border:1px solid rgba(63,185,80,0.3); }
  .pill-fail { background:rgba(248,81,73,0.15); color:var(--fail); border:1px solid rgba(248,81,73,0.3); }
  .pill-warn { background:rgba(210,153,34,0.15); color:var(--warn); border:1px solid rgba(210,153,34,0.3); }
  .pill-partial { background:rgba(88,166,255,0.15); color:var(--accent); border:1px solid rgba(88,166,255,0.3); }
  .badge { display:inline-block; padding:1px 7px; border-radius:4px; font-size:11px; font-family:'IBM Plex Mono',monospace; margin-right:4px; }
  .badge-pass { background:rgba(63,185,80,0.1); color:var(--pass); } .badge-fail { background:rgba(248,81,73,0.1); color:var(--fail); } .badge-warn { background:rgba(210,153,34,0.1); color:var(--warn); }
  footer { margin-top:40px; padding-top:20px; border-top:1px solid var(--border); font-size:11px; color:var(--muted); font-family:'IBM Plex Mono',monospace; text-align:center; }
</style>
</head>
<body>
<header>
  <div>
    <h1>&#11041; Windows Network Test Report</h1>
    <div style="color:var(--muted);font-size:13px;margin-top:4px;">hollebollevsan.nl</div>
  </div>
  <div class="meta">Generated: $ts<br>Targets tested: $($groups.Count)<br>Total checks: $total</div>
</header>
<div class="summary">
  <div class="stat-card s-total"><div class="label">Total Checks</div><div class="value">$total</div></div>
  <div class="stat-card s-pass"><div class="label">Passed</div><div class="value">$passCount</div></div>
  <div class="stat-card s-warn"><div class="label">Warnings</div><div class="value">$warnCount</div></div>
  <div class="stat-card s-partial"><div class="label">Partial</div><div class="value">$partialCount</div></div>
  <div class="stat-card s-fail"><div class="label">Failed</div><div class="value">$failCount</div></div>
</div>
<table>
  <thead><tr><th>Target / Test</th><th colspan="2">Detail</th><th>Status</th></tr></thead>
  <tbody>$groupedRows</tbody>
</table>
<footer>ps-network-test.ps1 &nbsp;&#183;&nbsp; $ts &nbsp;&#183;&nbsp; click target rows to expand tests</footer>
<script>
function toggleGroup(header) {
  const pg = header.getAttribute('data-pg');
  const nameCell = header.querySelector('.pg-name');
  const allRows = Array.from(document.querySelectorAll('.test-row'));
  const rows = allRows.filter(r => r.getAttribute('data-group') === pg);
  const visible = rows.length > 0 && rows[0].style.display !== 'none';
  rows.forEach(r => r.style.display = visible ? 'none' : 'table-row');
  if (nameCell) nameCell.innerHTML = (visible ? '&#9658; ' : '&#9660; ') + pg;
}
</script>
</body>
</html>
"@

$html | Out-File -FilePath $HtmlFile -Encoding UTF8

Write-Host "[Report] Saved to $HtmlFile" -ForegroundColor Green
Write-Host ""

# Open in default browser
Start-Process $HtmlFile
