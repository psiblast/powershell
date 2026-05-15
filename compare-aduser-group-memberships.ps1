# ==============================================================
#  compare-aduser-group-memberships.ps1
#  Compares group memberships across all members of an AD group.
#  Identifies which group memberships are common to all users
#  (the baseline) and which are unique to individual users
#  (the outliers worth investigating).
#
#  Usage - interactive:
#    .\compare-aduser-group-memberships.ps1
#
#  Usage - with parameter:
#    .\compare-aduser-group-memberships.ps1 -GroupName "Helpdesk"
#
#  Usage - with custom output path:
#    .\compare-aduser-group-memberships.ps1 -GroupName "Helpdesk" -OutputPath "C:\Audit\helpdesk.csv"
# ==============================================================

#Requires -Module ActiveDirectory

# --- Parameters -----------------------------------------------
param (
    [Parameter(Mandatory = $false)]
    [string]$GroupName,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath
)

# --- Helper: Get full recursive group memberships for a user --
function Get-UserGroupMemberships {
    param (
        [Microsoft.ActiveDirectory.Management.ADUser]$ADUser
    )

    $visited   = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $allGroups = [System.Collections.Generic.List[PSCustomObject]]::new()

    function Recurse-Groups {
        param (
            [string]$GroupDN,
            [string]$ParentName
        )

        if ($visited.Contains($GroupDN)) { return }
        [void]$visited.Add($GroupDN)

        try {
            $group = Get-ADGroup -Identity $GroupDN -Properties Description, MemberOf -ErrorAction Stop

            $allGroups.Add([PSCustomObject]@{
                GroupName      = $group.Name
                Description    = if ($group.Description) { $group.Description } else { "(no description)" }
                MembershipType = if ($ADUser.MemberOf -contains $GroupDN) { "Direct" } else { "Nested" }
                InheritedFrom  = $ParentName
                DN             = $group.DistinguishedName
            })

            foreach ($parentDN in $group.MemberOf) {
                Recurse-Groups -GroupDN $parentDN -ParentName $group.Name
            }
        }
        catch {
            Write-Warning "Could not retrieve group: $GroupDN - $_"
        }
    }

    foreach ($groupDN in $ADUser.MemberOf) {
        Recurse-Groups -GroupDN $groupDN -ParentName "(Direct member)"
    }

    return $allGroups
}

# --- Prompt if no parameter supplied --------------------------
if (-not $GroupName) {
    $GroupName = Read-Host "Enter the AD group name to compare members of"
}

# --- Resolve the group ----------------------------------------
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

Write-Host "Found $($members.Count) user(s). Resolving full group memberships..." -ForegroundColor Cyan
Write-Host ""

# --- Resolve full memberships for each user -------------------
# Dictionary: SamAccountName -> list of group DNs
$userMemberships = @{}
$userObjects     = @{}

foreach ($m in $members) {
    try {
        $adUser = Get-ADUser -Identity $m.distinguishedName -Properties DisplayName, MemberOf, UserPrincipalName -ErrorAction Stop
        Write-Host "  Processing: $($adUser.SamAccountName) ($($adUser.DisplayName))..." -ForegroundColor Gray

        $groups = Get-UserGroupMemberships -ADUser $adUser
        $userMemberships[$adUser.SamAccountName] = $groups
        $userObjects[$adUser.SamAccountName]     = $adUser
    }
    catch {
        Write-Warning "Could not retrieve user: $($m.SamAccountName) - $_"
    }
}

if ($userMemberships.Count -eq 0) {
    Write-Host "No user data to compare." -ForegroundColor Yellow
    exit 0
}

# --- Find common vs unique memberships ------------------------
# A group is "Common" if every user in the peer group has it
$allGroupDNs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

foreach ($sam in $userMemberships.Keys) {
    foreach ($g in $userMemberships[$sam]) {
        [void]$allGroupDNs.Add($g.DN)
    }
}

$commonDNs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

foreach ($dn in $allGroupDNs) {
    $allHaveIt = $true
    foreach ($sam in $userMemberships.Keys) {
        $dnList = $userMemberships[$sam] | Select-Object -ExpandProperty DN
        if ($dnList -notcontains $dn) {
            $allHaveIt = $false
            break
        }
    }
    if ($allHaveIt) {
        [void]$commonDNs.Add($dn)
    }
}

# --- Build CSV rows -------------------------------------------
$allRows = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($sam in ($userMemberships.Keys | Sort-Object)) {
    $adUser = $userObjects[$sam]
    $groups = $userMemberships[$sam] | Sort-Object { 
        # Sort: Common first, then Unique; within each, Direct before Nested, then alphabetical
        $status = if ($commonDNs.Contains($_.DN)) { "1-Common" } else { "2-Unique" }
        "$status-$($_.MembershipType)-$($_.GroupName)"
    }

    foreach ($g in $groups) {
        $status = if ($commonDNs.Contains($g.DN)) { "Common" } else { "Unique to this user" }

        $allRows.Add([PSCustomObject]@{
            Username       = $sam
            DisplayName    = $adUser.DisplayName
            Status         = $status
            GroupName      = $g.GroupName
            MembershipType = $g.MembershipType
            InheritedFrom  = $g.InheritedFrom
            Description    = $g.Description
        })
    }
}

# --- Console summary per user ---------------------------------
Write-Host ""
Write-Host "======================================================" -ForegroundColor DarkGray
Write-Host "  COMPARISON SUMMARY" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor DarkGray
Write-Host "  Peer group   : $($adGroup.Name)"
Write-Host "  Users compared: $($userMemberships.Count)"
Write-Host "  Common groups : $($commonDNs.Count) (all users share these)"
Write-Host ""

# Per-user unique count, sorted by most unique first (biggest outliers at top)
$userUniqueCounts = @{}
foreach ($sam in $userMemberships.Keys) {
    $uniqueCount = ($userMemberships[$sam] | Where-Object { -not $commonDNs.Contains($_.DN) }).Count
    $userUniqueCounts[$sam] = $uniqueCount
}

$sorted = $userUniqueCounts.GetEnumerator() | Sort-Object Value -Descending

Write-Host "  Unique memberships per user (most to least):" -ForegroundColor White
foreach ($entry in $sorted) {
    $adUser     = $userObjects[$entry.Key]
    $color      = if ($entry.Value -eq 0) { "Gray" } elseif ($entry.Value -le 10) { "White" } elseif ($entry.Value -le 30) { "Yellow" } else { "Red" }
    $flag       = if ($entry.Value -gt 30) { " <-- investigate" } else { "" }
    Write-Host ("    {0,-25} {1,4} unique group(s){2}" -f "$($entry.Key) ($($adUser.DisplayName))", $entry.Value, $flag) -ForegroundColor $color
}

# --- Export CSV -----------------------------------------------
if (-not $OutputPath) {
    $timestamp  = Get-Date -Format "yyyyMMdd_HHmmss"
    $safeName   = $GroupName -replace "[^a-zA-Z0-9_-]", "_"
    $OutputPath = ".\PeerComparison_$($safeName)_$timestamp.csv"
}

$allRows | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "Done!" -ForegroundColor Green
Write-Host "  Total rows  : $($allRows.Count)"
Write-Host "  Output file : $((Resolve-Path $OutputPath).Path)"