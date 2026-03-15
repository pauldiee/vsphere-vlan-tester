# ============================================================
#  Get-PortGroupData.ps1
#
#  Description:
#    Pulls port group data from vSphere and NSX segments,
#    merges the results and writes portgroups.json next to
#    this script. The JSON is consumed by the VLAN Config
#    Builder HTML tool to pre-populate rows.
#
#    Credentials are prompted on first run and saved
#    encrypted to credentials.xml using DPAPI (Windows
#    user account). Subsequent runs load them automatically.
#    Use -Reset to clear saved credentials and re-prompt.
#
#  Author : Paul van Dieen
#  Site   : https://www.hollebollevsan.nl
#
#  Requirements:
#    - VMware.PowerCLI module
#
#  Usage:
#    .\Get-PortGroupData.ps1                      # prompts for source
#    .\Get-PortGroupData.ps1 -Source vCenter     # vCenter only
#    .\Get-PortGroupData.ps1 -Source NSX         # NSX only
#    .\Get-PortGroupData.ps1 -Source Both        # both (no prompt)
#    .\Get-PortGroupData.ps1 -Reset              # clear saved credentials
#
#  Changelog:
#    v1.0  2026-03-13  Initial release
#    v1.1  2026-03-13  Interactive credential prompts with
#                      encrypted save/load via DPAPI
#    v1.2  2026-03-13  Fixed null VDSwitch/Notes properties, added
#                      -Standard flag to Get-VirtualPortGroup
#    v1.3  2026-03-13  Added source selection prompt (vCenter/NSX/Both)
#                      and -Source parameter for unattended use
# ============================================================

param(
    [switch]$Reset,
    [ValidateSet("Both","vCenter","NSX")]
    [string]$Source = ""
)

$CredFile   = Join-Path $PSScriptRoot "credentials.xml"
$OutputFile = Join-Path $PSScriptRoot "portgroups.json"

# ============================================================
#  Credential helpers
# ============================================================
function Save-Credentials {
    param($vCenterServer, $vCenterCred, $NSXManager, $NSXCred)
    $data = [PSCustomObject]@{
        vCenterServer = $vCenterServer
        vCenterUser   = $vCenterCred.UserName
        vCenterPass   = $vCenterCred.Password | ConvertFrom-SecureString
        NSXManager    = $NSXManager
        NSXUser       = $NSXCred.UserName
        NSXPass       = $NSXCred.Password | ConvertFrom-SecureString
    }
    $data | Export-Clixml -Path $CredFile
    Write-Host "[Credentials] Saved to $CredFile" -ForegroundColor DarkGray
}

function Load-Credentials {
    $data        = Import-Clixml -Path $CredFile
    $vCenterCred = New-Object System.Management.Automation.PSCredential(
        $data.vCenterUser,
        ($data.vCenterPass | ConvertTo-SecureString)
    )
    $NSXCred     = New-Object System.Management.Automation.PSCredential(
        $data.NSXUser,
        ($data.NSXPass | ConvertTo-SecureString)
    )
    return $data.vCenterServer, $vCenterCred, $data.NSXManager, $NSXCred
}

function Prompt-Credentials {
    Write-Host ""
    Write-Host "  Enter connection details" -ForegroundColor Cyan
    Write-Host "  ----------------------------------------" -ForegroundColor DarkGray

    $vCenterServer = Read-Host "  vCenter hostname or IP"
    $vCenterCred   = Get-Credential -Message "vCenter credentials" -UserName "administrator@vsphere.local"

    Write-Host ""
    $NSXManager    = Read-Host "  NSX Manager hostname or IP (leave blank to skip)"
    $NSXCred       = $null
    if ($NSXManager) {
        $NSXCred   = Get-Credential -Message "NSX Manager credentials" -UserName "admin"
    }

    Write-Host ""
    $save = Read-Host "  Save credentials for next run? (Y/N)"
    if ($save -match '^[Yy]') {
        if ($NSXCred) {
            Save-Credentials $vCenterServer $vCenterCred $NSXManager $NSXCred
        } else {
            $emptyCred = New-Object System.Management.Automation.PSCredential(
                "none",
                (ConvertTo-SecureString "none" -AsPlainText -Force)
            )
            Save-Credentials $vCenterServer $vCenterCred "" $emptyCred
        }
    }

    return $vCenterServer, $vCenterCred, $NSXManager, $NSXCred
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
Write-Host "  |       Get-PortGroupData  v1.3            |" -ForegroundColor DarkCyan
Write-Host "  |       hollebollevsan.nl                  |" -ForegroundColor DarkCyan
Write-Host "  +==========================================+" -ForegroundColor DarkCyan
Write-Host ""

if (Test-Path $CredFile) {
    Write-Host "[Credentials] Loading saved credentials..." -ForegroundColor DarkGray
    try {
        $vCenterServer, $vCenterCred, $NSXManager, $NSXCred = Load-Credentials
        Write-Host "[Credentials] Loaded for $($vCenterCred.UserName)@$vCenterServer" -ForegroundColor DarkGray
        if (-not $NSXManager -or $NSXManager -eq "") { $NSXCred = $null }
    } catch {
        Write-Warning "[Credentials] Failed to load saved credentials - prompting again."
        Remove-Item $CredFile -Force
        $vCenterServer, $vCenterCred, $NSXManager, $NSXCred = Prompt-Credentials
    }
} else {
    $vCenterServer, $vCenterCred, $NSXManager, $NSXCred = Prompt-Credentials
}

$vCenterPass = $vCenterCred.GetNetworkCredential().Password
$vCenterUser = $vCenterCred.UserName
$NSXPass     = if ($NSXCred) { $NSXCred.GetNetworkCredential().Password } else { "" }
$NSXUser     = if ($NSXCred) { $NSXCred.UserName } else { "" }

# ============================================================
#  Source selection
# ============================================================
if (-not $Source) {
    Write-Host ""
    Write-Host "  What would you like to fetch?" -ForegroundColor Cyan
    Write-Host "  [1] Both vCenter and NSX" -ForegroundColor White
    Write-Host "  [2] vCenter only" -ForegroundColor White
    Write-Host "  [3] NSX only" -ForegroundColor White
    Write-Host ""
    $choice = Read-Host "  Enter choice (1/2/3)"
    switch ($choice) {
        "2" { $Source = "vCenter" }
        "3" { $Source = "NSX" }
        default { $Source = "Both" }
    }
}
Write-Host "[Source] Fetching: $Source" -ForegroundColor Cyan
Write-Host ""

# ============================================================
#  vSphere - Standard and Distributed Port Groups
# ============================================================
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

if ($Source -eq "Both" -or $Source -eq "vCenter") {
Write-Host "[vSphere] Connecting to $vCenterServer..." -ForegroundColor Cyan

try {
    Connect-VIServer -Server $vCenterServer -User $vCenterUser -Password $vCenterPass -ErrorAction Stop | Out-Null
    Write-Host "[vSphere] Connected" -ForegroundColor Green

    # Distributed port groups (VDS)
    $dvpgs = Get-VDPortgroup | Where-Object { $_.IsUplink -eq $false }
    foreach ($pg in $dvpgs) {
        $vlanId = ""
        try {
            $vlanConfig = $pg.ExtensionData.Config.DefaultPortConfig.Vlan
            if ($null -ne $vlanConfig.VlanId) {
                $vlanId = $vlanConfig.VlanId.ToString()
            } elseif ($null -ne $vlanConfig.Ranges) {
                $vlanId = ($vlanConfig.Ranges | ForEach-Object { "$($_.Start)-$($_.End)" }) -join ", "
            }
        } catch {}

        $results.Add([PSCustomObject]@{
            source      = "vSphere-VDS"
            name        = $pg.Name
            vlanId      = $vlanId
            subnet      = ""
            gateway     = ""
            description = if ($pg.Notes) { $pg.Notes } else { "" }
            switch      = if ($pg.VDSwitch) { $pg.VDSwitch.Name } else { "" }
        })
    }

    # Standard port groups (VSS) - use -Standard to avoid duplicate VDS warning
    $spgs = Get-VirtualPortGroup -Standard | Where-Object { $_.Name -notmatch "Management Network|VM Network|vMotion|vSAN|Replication" }
    foreach ($pg in $spgs) {
        $results.Add([PSCustomObject]@{
            source      = "vSphere-VSS"
            name        = $pg.Name
            vlanId      = if ($null -ne $pg.VLanId) { $pg.VLanId.ToString() } else { "" }
            subnet      = ""
            gateway     = ""
            description = ""
            switch      = if ($pg.VirtualSwitch) { $pg.VirtualSwitch.Name } else { "" }
        })
    }

    Disconnect-VIServer -Server $vCenterServer -Confirm:$false | Out-Null
    Write-Host "[vSphere] Pulled $($dvpgs.Count + $spgs.Count) port groups" -ForegroundColor Green

} catch {
    Write-Warning "[vSphere] Failed: $_"
}
} # end if vCenter

# ============================================================
#  NSX - Segments
# ============================================================
if (($Source -eq "Both" -or $Source -eq "NSX") -and $NSXCred -and $NSXManager) {
    Write-Host "[NSX] Connecting to $NSXManager..." -ForegroundColor Cyan

    try {
        $pair    = "${NSXUser}:${NSXPass}"
        $bytes   = [System.Text.Encoding]::ASCII.GetBytes($pair)
        $b64     = [Convert]::ToBase64String($bytes)
        $headers = @{ Authorization = "Basic $b64"; "Content-Type" = "application/json" }

        if (-not ([System.Management.Automation.PSTypeName]'TrustAllCertsPolicy').Type) {
            Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
"@
            [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
        }

        $uri      = "https://$NSXManager/policy/api/v1/infra/segments"
        $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -ErrorAction Stop
        $segments = $response.results

        foreach ($seg in $segments) {
            $subnet  = ""
            $gateway = ""
            if ($seg.subnets -and $seg.subnets.Count -gt 0) {
                $subnet  = $seg.subnets[0].network
                $gateway = $seg.subnets[0].gateway_address
            }
            $vlanId = ""
            if ($seg.vlan_ids -and $seg.vlan_ids.Count -gt 0) {
                $vlanId = $seg.vlan_ids -join ", "
            }
            $results.Add([PSCustomObject]@{
                source      = "NSX"
                name        = $seg.display_name
                vlanId      = $vlanId
                subnet      = $subnet
                gateway     = $gateway
                description = $seg.description
                switch      = ($seg.transport_zone_path -replace ".*/", "")
            })
        }

        Write-Host "[NSX] Pulled $($segments.Count) segments" -ForegroundColor Green

    } catch {
        Write-Warning "[NSX] Failed: $_"
    }
} else {
    Write-Host "[NSX] Skipped - no NSX manager configured" -ForegroundColor DarkGray
}

# ============================================================
#  Write JSON output
# ============================================================
if ($results.Count -eq 0) {
    Write-Warning "No data collected - check your credentials and connectivity."
    Write-Host "  Tip: run with -Reset to clear saved credentials and re-prompt." -ForegroundColor DarkGray
    exit 1
}

$results | ConvertTo-Json -Depth 5 | Set-Content -Path $OutputFile -Encoding UTF8
Write-Host ""
Write-Host "[Done] Written $($results.Count) entries to:" -ForegroundColor Green
Write-Host "       $OutputFile" -ForegroundColor Green
Write-Host ""
Write-Host "  Open vlan-config-builder.html and click" -ForegroundColor DarkGray
Write-Host "  'Load from vCenter / NSX' to import." -ForegroundColor DarkGray
Write-Host ""
