# ==============================================================
#  get-group-nesting-audit.ps1
#  Shows the full nesting tree of an AD group (or a list of
#  groups), displaying who has access and through what path.
#
#  Usage - single group (interactive):
#    .\get-group-nesting-audit.ps1
#
#  Usage - single group (parameter):
#    .\get-group-nesting-audit.ps1 -GroupName "Domain Admins"
#
#  Usage - multiple groups from a text file (one group per line):
#    .\get-group-nesting-audit.ps1 -GroupListFile "C:\temp\groups.txt"
# ==============================================================

#Requires -Module ActiveDirectory

# --- Parameters -----------------------------------------------
param (
    [Parameter(Mandatory = $false)]
    [string]$GroupName,

    [Parameter(Mandatory = $false)]
    [string]$GroupListFile,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath
)

# --- Helper: Draw tree view recursively -----------------------
function Show-GroupTree {
    param (
        [string]$GroupDN,
        [System.Collections.Generic.HashSet[string]]$Visited,
        [string]$Indent = "",
        [bool]$IsLast = $true
    )

    $connector  = if ($IsLast) { "+-" } else { "|-" }
    $childIndent = if ($IsLast) { "  " } else { "| " }

    if ($Visited.Contains($GroupDN)) {
        Write-Host "$Indent$connector [CIRCULAR REF - already visited]" -ForegroundColor Red
        return
    }
    [void]$Visited.Add($GroupDN)

    try {
        $group   = Get-ADGroup -Identity $GroupDN -Properties Description, Members -ErrorAction Stop
        $members = Get-ADGroupMember -Identity $GroupDN -ErrorAction Stop

        $label = $group.Name
        if ($group.Description) { $label += " [$($group.Description)]" }

        Write-Host "$Indent$connector " -NoNewline -ForegroundColor DarkGray
        Write-Host $label -ForegroundColor Yellow

        $subGroups = $members | Where-Object { $_.objectClass -eq "group" }
        $users     = $members | Where-Object { $_.objectClass -eq "user" }

        # Show nested groups first (recurse)
        for ($i = 0; $i -lt $subGroups.Count; $i++) {
            $isLastGroup = ($i -eq $subGroups.Count - 1) -and ($users.Count -eq 0)
            Show-GroupTree -GroupDN $subGroups[$i].distinguishedName -Visited $Visited -Indent "$Indent$childIndent" -IsLast $isLastGroup
        }

        # Show users
        for ($i = 0; $i -lt $users.Count; $i++) {
            $isLastUser = ($i -eq $users.Count - 1)
            $userConnector = if ($isLastUser) { "+-" } else { "|-" }
            try {
                $u = Get-ADUser -Identity $users[$i].distinguishedName -Properties DisplayName, Enabled -ErrorAction Stop
                $status = if ($u.Enabled) { "" } else { " [DISABLED]" }
                Write-Host "$Indent$childIndent$userConnector " -NoNewline -ForegroundColor DarkGray
                Write-Host "$($u.SamAccountName) ($($u.DisplayName))$status" -ForegroundColor $(if ($u.Enabled) { "White" } else { "DarkRed" })
            }
            catch {
                Write-Host "$Indent$childIndent$userConnector $($users[$i].SamAccountName) [could not retrieve]" -ForegroundColor DarkGray
            }
        }
    }
    catch {
        Write-Host "$Indent$connector [ERROR: could not retrieve group $GroupDN]" -ForegroundColor Red
    }
}

# --- Helper: Flatten group tree into CSV rows -----------------
function Get-GroupTreeFlat {
    param (
        [string]$GroupDN,
        [string]$TopLevelGroup,
        [System.Collections.Generic.HashSet[string]]$Visited,
        [string]$PathSoFar = ""
    )

    if ($Visited.Contains($GroupDN)) { return }
    [void]$Visited.Add($GroupDN)

    try {
        $group   = Get-ADGroup -Identity $GroupDN -Properties Description -ErrorAction Stop
        $members = Get-ADGroupMember -Identity $GroupDN -ErrorAction Stop

        $currentPath = if ($PathSoFar) { "$PathSoFar > $($group.Name)" } else { $group.Name }

        $subGroups = $members | Where-Object { $_.objectClass -eq "group" }
        $users     = $members | Where-Object { $_.objectClass -eq "user" }

        # Emit a row for each nested group found along the way
        if ($PathSoFar) {
            [PSCustomObject]@{
                TopLevelGroup  = $TopLevelGroup
                Type           = "Group"
                Name           = $group.Name
                DisplayName    = ""
                Enabled        = ""
                AccessPath     = $currentPath
                NestingDepth   = ($currentPath -split ">").Count - 1
                Description    = if ($group.Description) { $group.Description } else { "(no description)" }
            }
        }

        # Recurse into nested groups
        foreach ($sg in $subGroups) {
            Get-GroupTreeFlat -GroupDN $sg.distinguishedName -TopLevelGroup $TopLevelGroup -Visited $Visited -PathSoFar $currentPath
        }

        # Emit a row for each user
        foreach ($u in $users) {
            try {
                $adUser = Get-ADUser -Identity $u.distinguishedName -Properties DisplayName, Enabled -ErrorAction Stop
                [PSCustomObject]@{
                    TopLevelGroup  = $TopLevelGroup
                    Type           = "User"
                    Name           = $adUser.SamAccountName
                    DisplayName    = $adUser.DisplayName
                    Enabled        = $adUser.Enabled
                    AccessPath     = "$currentPath > $($adUser.SamAccountName)"
                    NestingDepth   = ($currentPath -split ">").Count - 1
                    Description    = ""
                }
            }
            catch {
                [PSCustomObject]@{
                    TopLevelGroup  = $TopLevelGroup
                    Type           = "User"
                    Name           = $u.SamAccountName
                    DisplayName    = "[could not retrieve]"
                    Enabled        = ""
                    AccessPath     = "$currentPath > $($u.SamAccountName)"
                    NestingDepth   = ($currentPath -split ">").Count - 1
                    Description    = ""
                }
            }
        }
    }
    catch {
        Write-Warning "Could not retrieve group: $GroupDN - $_"
    }
}

# --- Prompt if no parameters supplied -------------------------
if (-not $GroupName -and -not $GroupListFile) {
    $choice = Read-Host "Audit a single [G]roup or a [L]ist of groups from a file? (G/L)"
    if ($choice -match "^[Ll]") {
        $GroupListFile = Read-Host "Enter the path to the text file (one group name per line)"
    }
    else {
        $GroupName = Read-Host "Enter the AD group name"
    }
}

# --- Build list of groups to process -------------------------
$groupsToProcess = [System.Collections.Generic.List[string]]::new()

if ($GroupListFile) {
    if (-not (Test-Path $GroupListFile)) {
        Write-Error "File not found: $GroupListFile"
        exit 1
    }
    $lines = Get-Content $GroupListFile | Where-Object { $_.Trim() -ne "" }
    foreach ($line in $lines) {
        $groupsToProcess.Add($line.Trim())
    }
    Write-Host ""
    Write-Host "Loaded $($groupsToProcess.Count) group(s) from file." -ForegroundColor Cyan
}
else {
    $groupsToProcess.Add($GroupName)
}

# --- Process each group ---------------------------------------
$allRows = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($gName in $groupsToProcess) {
    try {
        $adGroup = Get-ADGroup -Identity $gName -ErrorAction Stop
    }
    catch {
        Write-Warning "Group '$gName' not found in Active Directory - skipping."
        continue
    }

    # Tree view
    Write-Host ""
    Write-Host "======================================================" -ForegroundColor DarkGray
    Write-Host "  GROUP: $($adGroup.Name)" -ForegroundColor Cyan
    Write-Host "======================================================" -ForegroundColor DarkGray

    $treeVisited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    Show-GroupTree -GroupDN $adGroup.DistinguishedName -Visited $treeVisited -Indent "" -IsLast $true

    # Flat rows for CSV
    $flatVisited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $rows = Get-GroupTreeFlat -GroupDN $adGroup.DistinguishedName -TopLevelGroup $adGroup.Name -Visited $flatVisited -PathSoFar ""
    foreach ($row in $rows) {
        $allRows.Add($row)
    }
}

Write-Host ""

# --- Export CSV -----------------------------------------------
if ($allRows.Count -eq 0) {
    Write-Host "No data to export." -ForegroundColor Yellow
    exit 0
}

if (-not $OutputPath) {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    if ($GroupListFile) {
        $OutputPath = ".\GroupNestingAudit_MultiGroup_$timestamp.csv"
    }
    else {
        $safeName   = $GroupName -replace "[^a-zA-Z0-9_-]", "_"
        $OutputPath = ".\GroupNestingAudit_$($safeName)_$timestamp.csv"
    }
}

$allRows | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

# --- Summary --------------------------------------------------
$userRows  = $allRows | Where-Object { $_.Type -eq "User" }
$groupRows = $allRows | Where-Object { $_.Type -eq "Group" }
$maxDepth  = ($allRows | Measure-Object -Property NestingDepth -Maximum).Maximum
$disabled  = $userRows | Where-Object { $_.Enabled -eq $false }

Write-Host "Done!" -ForegroundColor Green
Write-Host "  Groups audited    : $($groupsToProcess.Count)"
Write-Host "  Nested groups     : $($groupRows.Count)"
Write-Host "  Total users       : $($userRows.Count)"
Write-Host "  Disabled users    : $($disabled.Count)" -ForegroundColor $(if ($disabled.Count -gt 0) { "Red" } else { "White" })
Write-Host "  Max nesting depth : $maxDepth" -ForegroundColor $(if ($maxDepth -ge 3) { "Yellow" } else { "White" })
Write-Host "  Output file       : $((Resolve-Path $OutputPath).Path)"