# ==============================================================
#  get-nested-groups-of-user-or-group.ps1
#  Exports all group memberships (including nested/recursive)
#  for an AD user or all members of an AD group, to a CSV.
#
#  Usage - interactive:
#    .\get-nested-groups-of-user-or-group
#
#  Usage - single user:
#    .\get-nested-groups-of-user-or-group.ps1 -Username jdoe
#
#  Usage - all members of a group:
#    .\get-nested-groups-of-user-or-group.ps1 -GroupName "HelpDesk"
# ==============================================================

#Requires -Module ActiveDirectory

# --- Parameters -----------------------------------------------
param (
    [Parameter(Mandatory = $false)]
    [string]$Username,

    [Parameter(Mandatory = $false)]
    [string]$GroupName
)

# --- Helper: Recursive group membership lookup ----------------
function Get-NestedGroups {
    param (
        [string]$GroupDN,
        [System.Collections.Generic.HashSet[string]]$Visited,
        [string]$ParentName = ""
    )

    if ($Visited.Contains($GroupDN)) { return }
    [void]$Visited.Add($GroupDN)

    try {
        $group = Get-ADGroup -Identity $GroupDN -Properties Description, MemberOf -ErrorAction Stop

        [PSCustomObject]@{
            GroupName      = $group.Name
            Description    = if ($group.Description) { $group.Description } else { "(no description)" }
            MembershipType = "Direct"
            InheritedFrom  = $ParentName
            DN             = $group.DistinguishedName
        }

        foreach ($parentDN in $group.MemberOf) {
            $nested = Get-NestedGroups -GroupDN $parentDN -Visited $Visited -ParentName $group.Name
            foreach ($n in $nested) {
                $n.MembershipType = "Nested"
                $n
            }
        }
    }
    catch {
        Write-Warning "Could not retrieve group: $GroupDN - $_"
    }
}

# --- Helper: Get all groups for a single user -----------------
function Get-UserGroups {
    param (
        [Microsoft.ActiveDirectory.Management.ADUser]$ADUser
    )

    $visited   = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $allGroups = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($groupDN in $ADUser.MemberOf) {
        $results = Get-NestedGroups -GroupDN $groupDN -Visited $visited -ParentName "(Direct member)"
        foreach ($r in $results) {
            $allGroups.Add($r)
        }
    }

    # Correct Direct vs Nested
    foreach ($g in $allGroups) {
        if ($ADUser.MemberOf -contains $g.DN) {
            $g.MembershipType = "Direct"
        }
        else {
            $g.MembershipType = "Nested"
        }
    }

    return $allGroups
}

# --- Prompt if neither parameter was supplied -----------------
if (-not $Username -and -not $GroupName) {
    $choice = Read-Host "Look up a [U]ser or a [G]roup? (U/G)"
    if ($choice -match "^[Gg]") {
        $GroupName = Read-Host "Enter the AD group name"
    }
    else {
        $Username = Read-Host "Enter the AD username (SamAccountName)"
    }
}

# --- Build the list of users to process ----------------------
$usersToProcess = [System.Collections.Generic.List[Microsoft.ActiveDirectory.Management.ADUser]]::new()

if ($GroupName) {
    # Group mode: resolve the group and get all its members
    try {
        $adGroup = Get-ADGroup -Identity $GroupName -ErrorAction Stop
    }
    catch {
        Write-Error "Group '$GroupName' not found in Active Directory. $_"
        exit 1
    }

    Write-Host ""
    Write-Host "Found group: $($adGroup.Name)" -ForegroundColor Cyan
    Write-Host "Fetching members..." -ForegroundColor Cyan

    $members = Get-ADGroupMember -Identity $adGroup -Recursive | Where-Object { $_.objectClass -eq "user" }

    if (-not $members) {
        Write-Host "No user members found in group '$GroupName'." -ForegroundColor Yellow
        exit 0
    }

    foreach ($m in $members) {
        try {
            $u = Get-ADUser -Identity $m.distinguishedName -Properties DisplayName, MemberOf, UserPrincipalName -ErrorAction Stop
            $usersToProcess.Add($u)
        }
        catch {
            Write-Warning "Could not retrieve user: $($m.SamAccountName) - $_"
        }
    }

    Write-Host "Found $($usersToProcess.Count) user(s) in group." -ForegroundColor Cyan
    Write-Host ""
}
else {
    # User mode: single user
    try {
        $u = Get-ADUser -Identity $Username -Properties DisplayName, MemberOf, UserPrincipalName -ErrorAction Stop
        $usersToProcess.Add($u)
    }
    catch {
        Write-Error "User '$Username' not found in Active Directory. $_"
        exit 1
    }
}

# --- Process each user ----------------------------------------
$allRows = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($adUser in $usersToProcess) {
    Write-Host "Processing: $($adUser.DisplayName) ($($adUser.SamAccountName))..." -ForegroundColor Gray

    $groups = Get-UserGroups -ADUser $adUser

    if ($groups.Count -eq 0) {
        Write-Host "  No group memberships found." -ForegroundColor Yellow
        continue
    }

    $sorted = $groups | Sort-Object MembershipType, GroupName

    foreach ($g in $sorted) {
        $allRows.Add([PSCustomObject]@{
            Username       = $adUser.SamAccountName
            GroupName      = $g.GroupName
            MembershipType = $g.MembershipType
            InheritedFrom  = $g.InheritedFrom
            Description    = $g.Description
        })
    }
}

if ($allRows.Count -eq 0) {
    Write-Host "No data to export." -ForegroundColor Yellow
    exit 0
}

# --- Build output path ----------------------------------------
if (-not $OutputPath) {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    if ($GroupName) {
        $safeName   = $GroupName -replace "[^a-zA-Z0-9_-]", "_"
        $OutputPath = ".\Group_$($safeName)_Members_GroupMemberships_$timestamp.csv"
    }
    else {
        $OutputPath = ".\$($Username)_GroupMemberships_$timestamp.csv"
    }
}

# --- Export ---------------------------------------------------
$allRows | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

# --- Summary --------------------------------------------------
Write-Host ""
Write-Host "Done!" -ForegroundColor Green
Write-Host "  Users processed : $($usersToProcess.Count)"
Write-Host "  Total rows      : $($allRows.Count)"
Write-Host "  Output file     : $((Resolve-Path $OutputPath).Path)"