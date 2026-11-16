# ============================================================
#  Get-VMData.ps1
#
#  Description:
#    Pulls data from all powered-on VMs in vCenter and writes
#    vmdata.json next to this script. The JSON is consumed by
#    the WSL Config Builder to pre-populate test targets with
#    real VM IPs and gateways — no manual entry needed.
#
#    Only powered-on VMs with a valid primary IP are included.
#    Gateway is derived from the VM's default route via
#    VMware Tools guest info (requires VMware Tools running).
#
#    Credentials are prompted on first run and saved encrypted
#    via Windows DPAPI. Use -Reset to clear saved credentials.
#
#  Author : Paul van Dieen
#  Site   : https://www.hollebollevsan.nl
#  Repo   : https://github.com/pauldiee/vsphere-vlan-tester
#
#  Requirements:
#    - PowerCLI: VMware.VimAutomation.Core, from VCF.PowerCLI
#      (vCenter 9, PowerShell 7) or VMware.PowerCLI (vCenter 7/8)
#    - VMware Tools running on target VMs (for IP/gateway info)
#
#  Usage:
#    .\Get-VMData.ps1              # normal run
#    .\Get-VMData.ps1 -Reset       # clear saved credentials
#
#  Changelog:
#    v1.0  2026-03-16  Initial release
#    v1.1  2026-11-16  PowerCLI loaded up front: imports only
#                      VMware.VimAutomation.Core, stops on mixed
#                      PowerCLI versions, clear error with loaded
#                      modules and jump-host guide link (#3)
# ============================================================

param(
    [switch]$Reset
)

# ============================================================
#  PowerCLI module check
# ============================================================
# The script needs only VMware.VimAutomation.Core (and what it requires), not
# the whole PowerCLI bundle. Loading problems almost always come from the
# jump host (several PowerCLI versions side by side, an old one already loaded
# in the session, an incomplete or blocked offline install); the fix belongs
# there, so the script only explains what it found and where to read on.
$jumpHostGuide = 'https://vcf-planning.hollebollevsan.nl/docs/42-jump-host-powershell/'

function Stop-ModuleLoadFailure {
    param([string]$Reason)
    Write-Host '  [ERROR] Could not load PowerCLI (VMware.VimAutomation.Core).' -ForegroundColor Red
    if ($Reason) { Write-Host "          $Reason" -ForegroundColor Red }
    Write-Host '          Start a clean session with "pwsh -NoProfile" and run the script first.' -ForegroundColor Yellow
    Write-Host '          Keep one complete, unblocked PowerCLI version on this host; see the jump-host' -ForegroundColor Yellow
    Write-Host "          guide, section 4 (completeness check) and 6 (pitfalls): $jumpHostGuide" -ForegroundColor Yellow
    $loaded = @(Get-Module -Name VMware.*, VCF.PowerCLI)
    if ($loaded.Count -gt 0) {
        Write-Host '          Loaded now:' -ForegroundColor Yellow
        $loaded | Sort-Object Name | ForEach-Object {
            Write-Host "            $($_.Name) $($_.Version)  ($($_.ModuleBase))" -ForegroundColor Yellow
        }
    }
    exit 1
}
function Get-ShortError {
    param($ErrorRecord)
    $m = "$($ErrorRecord.Exception.Message)"
    if ($m -match "`t") { $m = @($m -split "`t" | Where-Object { $_.Trim() })[-1].Trim() }
    return $m
}

if (-not (Get-Module -ListAvailable -Name VMware.VimAutomation.Core)) {
    Write-Host '  [ERROR] No PowerCLI found (VMware.VimAutomation.Core is not installed).' -ForegroundColor Red
    Write-Host '          vCenter 9:     Install-Module -Name VCF.PowerCLI -Scope CurrentUser   (needs PowerShell 7, KB 409981)' -ForegroundColor Yellow
    Write-Host '          vCenter 7 / 8: Install-Module -Name VMware.PowerCLI -Scope CurrentUser  (KB 428547)' -ForegroundColor Yellow
    Write-Host "          Without internet access: $jumpHostGuide (section 3)" -ForegroundColor Yellow
    exit 1
}

# All VMware.VimAutomation.* modules of one PowerCLI release share one version
# (13.5.1.x for VCF.PowerCLI 9.1.1); StorageUtility is versioned on its own.
$loadedVersions = @(Get-Module -Name VMware.VimAutomation.* |
    Where-Object { $_.Name -ne 'VMware.VimAutomation.StorageUtility' } |
    ForEach-Object { "$($_.Version)" } | Select-Object -Unique)
if ($loadedVersions.Count -gt 1) {
    Stop-ModuleLoadFailure -Reason "PowerCLI modules of different versions are already loaded in this session ($($loadedVersions -join ', '))."
}

try {
    Import-Module -Name VMware.VimAutomation.Core -ErrorAction Stop -WarningAction SilentlyContinue 6>$null
}
catch {
    Stop-ModuleLoadFailure -Reason (Get-ShortError $_)
}
Write-Host "  [INFO] PowerCLI $(@(Get-Module -Name VMware.VimAutomation.Core)[0].Version) loaded." -ForegroundColor Cyan

$CredFile   = Join-Path $PSScriptRoot "credentials-vm.xml"
$OutputFile = Join-Path $PSScriptRoot "vmdata.json"

# ============================================================
#  Credential helpers
# ============================================================
function Save-Credentials {
    param($Server, $Cred)
    $data = [PSCustomObject]@{
        Server = $Server
        User   = $Cred.UserName
        Pass   = $Cred.Password | ConvertFrom-SecureString
    }
    $data | Export-Clixml -Path $CredFile
    Write-Host "[Credentials] Saved to $CredFile" -ForegroundColor DarkGray
}

function Load-Credentials {
    $data = Import-Clixml -Path $CredFile
    $cred = New-Object System.Management.Automation.PSCredential(
        $data.User,
        ($data.Pass | ConvertTo-SecureString)
    )
    return $data.Server, $cred
}

function Prompt-Credentials {
    Write-Host ""
    Write-Host "  Enter vCenter connection details" -ForegroundColor Cyan
    Write-Host "  ----------------------------------------" -ForegroundColor DarkGray
    $server = Read-Host "  vCenter hostname or IP"
    $cred   = Get-Credential -Message "vCenter credentials" -UserName "administrator@vsphere.local"
    Write-Host ""
    $save = Read-Host "  Save credentials for next run? (Y/N)"
    if ($save -match '^[Yy]') { Save-Credentials $server $cred }
    return $server, $cred
}

# ============================================================
#  Load or prompt credentials
# ============================================================
if ($Reset -and (Test-Path $CredFile)) {
    Remove-Item $CredFile -Force
    Write-Host "[Credentials] Cleared - you will be prompted again." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "  +==========================================+" -ForegroundColor DarkCyan
Write-Host "  |        Get-VMData  v1.0                  |" -ForegroundColor DarkCyan
Write-Host "  |        hollebollevsan.nl                 |" -ForegroundColor DarkCyan
Write-Host "  +==========================================+" -ForegroundColor DarkCyan
Write-Host ""

if (Test-Path $CredFile) {
    Write-Host "[Credentials] Loading saved credentials..." -ForegroundColor DarkGray
    try {
        $vCenterServer, $vCenterCred = Load-Credentials
        Write-Host "[Credentials] Loaded for $($vCenterCred.UserName)@$vCenterServer" -ForegroundColor DarkGray
    } catch {
        Write-Warning "[Credentials] Failed to load - prompting again."
        Remove-Item $CredFile -Force
        $vCenterServer, $vCenterCred = Prompt-Credentials
    }
} else {
    $vCenterServer, $vCenterCred = Prompt-Credentials
}

$vCenterPass = $vCenterCred.GetNetworkCredential().Password
$vCenterUser = $vCenterCred.UserName

# ============================================================
#  Connect and pull VM data
# ============================================================
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null

Write-Host "[vCenter] Connecting to $vCenterServer..." -ForegroundColor Cyan

try {
    Connect-VIServer -Server $vCenterServer -User $vCenterUser -Password $vCenterPass -ErrorAction Stop | Out-Null
    Write-Host "[vCenter] Connected" -ForegroundColor Green
} catch {
    Write-Warning "[vCenter] Failed to connect: $_"
    exit 1
}

Write-Host "[vCenter] Pulling powered-on VMs..." -ForegroundColor Cyan

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

$vms = Get-VM | Where-Object { $_.PowerState -eq 'PoweredOn' }
Write-Host "[vCenter] Found $($vms.Count) powered-on VMs" -ForegroundColor Green

foreach ($vm in $vms) {
    # Skip VMs without Tools or without an IP
    $toolsStatus = $vm.ExtensionData.Guest.ToolsRunningStatus
    if ($toolsStatus -ne 'guestToolsRunning') { continue }

    $guest = $vm.ExtensionData.Guest

    # Primary IP — first non-loopback IPv4 address
    $primaryIP = ""
    foreach ($nic in $guest.Net) {
        foreach ($ip in $nic.IpAddress) {
            if ($ip -match '^\d+\.\d+\.\d+\.\d+$' -and $ip -ne '127.0.0.1') {
                $primaryIP = $ip
                break
            }
        }
        if ($primaryIP) { break }
    }

    if (-not $primaryIP) { continue }

    # Default gateway from guest routing info
    $gateway = ""
    try {
        $routeTable = $guest.IpStack
        if ($routeTable -and $routeTable.Count -gt 0) {
            $defaultRoute = $routeTable[0].IpRouteConfig.IpRoute |
                Where-Object { $_.Network -eq '0.0.0.0' -and $_.PrefixLength -eq 0 } |
                Select-Object -First 1
            if ($defaultRoute) {
                $gateway = $defaultRoute.Gateway.IpAddress
            }
        }
    } catch {}

    $results.Add([PSCustomObject]@{
        label       = $vm.Name
        ip          = $primaryIP
        gateway     = $gateway
        powerState  = $vm.PowerState.ToString()
        toolsStatus = $toolsStatus
    })
}

Disconnect-VIServer -Server $vCenterServer -Confirm:$false | Out-Null

# ============================================================
#  Write JSON output
# ============================================================
if ($results.Count -eq 0) {
    Write-Warning "No powered-on VMs with VMware Tools and a valid IP found."
    exit 1
}

$results | ConvertTo-Json -Depth 5 | Set-Content -Path $OutputFile -Encoding UTF8

Write-Host ""
Write-Host "[Done] Written $($results.Count) VMs to:" -ForegroundColor Green
Write-Host "       $OutputFile" -ForegroundColor Green
Write-Host ""
Write-Host "  Open wsl-config-builder.html and click" -ForegroundColor DarkGray
Write-Host "  'Load from vCenter VMs' to import." -ForegroundColor DarkGray
Write-Host ""
