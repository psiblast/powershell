# ==============================================================
#  get-ad-ou-delegation-audit.ps1
#  Exports only custom/non-default delegations on OUs.
#  Filters out inherited ACEs and well-known built-in identities
#  so you only see what was deliberately delegated.
#
#  Usage - interactive:
#    .\get-ad-ou-delegation-audit.ps1
#
#  Usage - entire domain:
#    .\get-ad-ou-delegation-audit.ps1 -Scope Domain
#
#  Usage - specific OU and its children:
#    .\get-ad-ou-delegation-audit.ps1 -Scope OU -OUName "Helpdesk"
#
#  Usage - with custom output path:
#    .\get-ad-ou-delegation-audit.ps1 -Scope Domain -OutputPath "C:\Audit\ou_delegation.csv"
# ==============================================================

#Requires -Module ActiveDirectory

# --- Parameters -----------------------------------------------
param (
    [Parameter(Mandatory = $false)]
    [ValidateSet("Domain", "OU")]
    [string]$Scope,

    [Parameter(Mandatory = $false)]
    [string]$OUName,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath
)

# --- Default identities to exclude ----------------------------
# These appear on every OU by default and are not custom delegations
$defaultIdentities = @(
    "NT AUTHORITY\SYSTEM",
    "NT AUTHORITY\SELF",
    "NT AUTHORITY\Authenticated Users",
    "NT AUTHORITY\ENTERPRISE DOMAIN CONTROLLERS",
    "BUILTIN\Administrators",
    "BUILTIN\Account Operators",
    "BUILTIN\Print Operators",
    "BUILTIN\Backup Operators",
    "BUILTIN\Server Operators",
    "CREATOR OWNER",
    "Everyone"
)

# These partial matches cover domain-prefixed built-in groups
# regardless of what the domain is called
$defaultPartialMatches = @(
    "Domain Admins",
    "Enterprise Admins",
    "Schema Admins",
    "Group Policy Creator Owners",
    "Key Admins",
    "Enterprise Key Admins"
)

function Is-DefaultIdentity {
    param ([string]$Identity)

    # Exact match
    foreach ($d in $defaultIdentities) {
        if ($Identity -ieq $d) { return $true }
    }

    # Partial match (handles DOMAIN\Domain Admins etc.)
    foreach ($p in $defaultPartialMatches) {
        if ($Identity -ilike "*$p*") { return $true }
    }

    return $false
}

# --- Helper: Translate ObjectType GUIDs to readable names -----
function Get-SchemaGUIDMap {
    Write-Host "  Building GUID lookup table from AD schema..." -ForegroundColor Gray

    $guidMap = @{}

    Get-ADObject `
        -SearchBase (Get-ADRootDSE).schemaNamingContext `
        -LDAPFilter "(schemaIDGUID=*)" `
        -Properties name, schemaIDGUID `
        -ErrorAction SilentlyContinue |
    ForEach-Object {
        $guid = [System.GUID]$_.schemaIDGUID
        if (-not $guidMap.ContainsKey($guid)) {
            $guidMap[$guid] = $_.name
        }
    }

    Get-ADObject `
        -SearchBase "CN=Extended-Rights,$((Get-ADRootDSE).configurationNamingContext)" `
        -LDAPFilter "(objectClass=controlAccessRight)" `
        -Properties name, rightsGUID `
        -ErrorAction SilentlyContinue |
    ForEach-Object {
        $guid = [System.GUID]$_.rightsGUID
        if (-not $guidMap.ContainsKey($guid)) {
            $guidMap[$guid] = $_.name
        }
    }

    return $guidMap
}

# --- Helper: Resolve a GUID to a friendly name ----------------
function Resolve-GUID {
    param (
        [string]$GUIDString,
        [hashtable]$GUIDMap
    )

    if ([string]::IsNullOrWhiteSpace($GUIDString) -or $GUIDString -eq "00000000-0000-0000-0000-000000000000") {
        return "All"
    }

    try {
        $guid = [System.GUID]$GUIDString
        if ($GUIDMap.ContainsKey($guid)) {
            return $GUIDMap[$guid]
        }
    }
    catch {}

    return $GUIDString
}

# --- Helper: Process ACL for a single OU ----------------------
function Get-OUAclRows {
    param (
        [Microsoft.ActiveDirectory.Management.ADOrganizationalUnit]$OU,
        [hashtable]$GUIDMap
    )

    $rows = [System.Collections.Generic.List[PSCustomObject]]::new()

    try {
        $acl = Get-Acl -Path "AD:\$($OU.DistinguishedName)" -ErrorAction Stop

        foreach ($ace in $acl.Access) {

            # Skip inherited ACEs
            if ($ace.IsInherited) { continue }

            # Skip default built-in identities
            if (Is-DefaultIdentity -Identity $ace.IdentityReference.ToString()) { continue }

            $objectType          = Resolve-GUID -GUIDString $ace.ObjectType.ToString() -GUIDMap $GUIDMap
            $inheritedObjectType = Resolve-GUID -GUIDString $ace.InheritedObjectType.ToString() -GUIDMap $GUIDMap

            $rows.Add([PSCustomObject]@{
                OUName                = $OU.Name
                OUDistinguishedName   = $OU.DistinguishedName
                IdentityReference     = $ace.IdentityReference.ToString()
                AccessControlType     = $ace.AccessControlType.ToString()
                ActiveDirectoryRights = $ace.ActiveDirectoryRights.ToString()
                InheritanceType       = $ace.InheritanceType.ToString()
                ObjectType            = $objectType
                InheritedObjectType   = $inheritedObjectType
            })
        }
    }
    catch {
        Write-Warning "Could not read ACL for OU: $($OU.DistinguishedName) - $_"
    }

    return $rows
}

# --- Prompt if no scope supplied ------------------------------
if (-not $Scope) {
    $choice = Read-Host "Audit the entire [D]omain or a specific [O]U? (D/O)"
    if ($choice -match "^[Oo]") {
        $Scope = "OU"
    }
    else {
        $Scope = "Domain"
    }
}

if ($Scope -eq "OU" -and -not $OUName) {
    $OUName = Read-Host "Enter the OU name or Distinguished Name (e.g. 'Helpdesk' or 'OU=Helpdesk,DC=domain,DC=local')"
}

# --- Resolve the list of OUs to audit ------------------------
$ouList = [System.Collections.Generic.List[Microsoft.ActiveDirectory.Management.ADOrganizationalUnit]]::new()

Write-Host ""

if ($Scope -eq "Domain") {
    Write-Host "Scope: Entire domain" -ForegroundColor Cyan
    Write-Host "Fetching all OUs..." -ForegroundColor Cyan

    $allOUs = Get-ADOrganizationalUnit -Filter * -Properties Name, DistinguishedName
    foreach ($ou in $allOUs) { $ouList.Add($ou) }
}
else {
    Write-Host "Scope: OU subtree - $OUName" -ForegroundColor Cyan
    Write-Host "Fetching OUs..." -ForegroundColor Cyan

    try {
        if ($OUName -match "^OU=") {
            $rootOU = Get-ADOrganizationalUnit -Identity $OUName -Properties Name, DistinguishedName -ErrorAction Stop
        }
        else {
            $rootOU = Get-ADOrganizationalUnit -Filter "Name -eq '$OUName'" -Properties Name, DistinguishedName -ErrorAction Stop |
                      Select-Object -First 1
        }

        if (-not $rootOU) {
            Write-Error "OU '$OUName' not found in Active Directory."
            exit 1
        }

        $ouList.Add($rootOU)

        $childOUs = Get-ADOrganizationalUnit -Filter * -SearchBase $rootOU.DistinguishedName -SearchScope Subtree -Properties Name, DistinguishedName
        foreach ($ou in $childOUs) {
            if ($ou.DistinguishedName -ne $rootOU.DistinguishedName) {
                $ouList.Add($ou)
            }
        }
    }
    catch {
        Write-Error "Could not resolve OU '$OUName'. $_"
        exit 1
    }
}

Write-Host "Found $($ouList.Count) OU(s) to audit." -ForegroundColor Cyan
Write-Host ""

# --- Build GUID map -------------------------------------------
$guidMap = Get-SchemaGUIDMap
Write-Host "  Done. Processing OUs..." -ForegroundColor Gray
Write-Host ""

# --- Process each OU ------------------------------------------
$allRows   = [System.Collections.Generic.List[PSCustomObject]]::new()
$processed = 0

foreach ($ou in $ouList) {
    $processed++
    if ($processed % 50 -eq 0) {
        Write-Host "  Processed $processed / $($ouList.Count) OUs..." -ForegroundColor Gray
    }

    $rows = Get-OUAclRows -OU $ou -GUIDMap $guidMap
    foreach ($row in $rows) {
        $allRows.Add($row)
    }
}

if ($allRows.Count -eq 0) {
    Write-Host "No custom delegations found." -ForegroundColor Yellow
    exit 0
}

# --- Build output path ----------------------------------------
if (-not $OutputPath) {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    if ($Scope -eq "Domain") {
        $OutputPath = ".\OUDelegationAudit_FullDomain_$timestamp.csv"
    }
    else {
        $safeName   = $OUName -replace "[^a-zA-Z0-9_-]", "_"
        $OutputPath = ".\OUDelegationAudit_$($safeName)_$timestamp.csv"
    }
}

# --- Export ---------------------------------------------------
$allRows | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

# --- Summary --------------------------------------------------
$uniqueOUs        = ($allRows | Select-Object -ExpandProperty OUDistinguishedName -Unique).Count
$uniqueIdentities = ($allRows | Select-Object -ExpandProperty IdentityReference -Unique).Count

Write-Host "Done!" -ForegroundColor Green
Write-Host "  OUs scanned          : $($ouList.Count)"
Write-Host "  OUs with custom ACEs : $uniqueOUs"
Write-Host "  Total custom ACEs    : $($allRows.Count)"
Write-Host "  Unique identities    : $uniqueIdentities"
Write-Host "  Output file          : $((Resolve-Path $OutputPath).Path)"