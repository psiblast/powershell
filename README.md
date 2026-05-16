# 🛠️ PowerShell Scripts

A collection of utility PowerShell scripts for Active Directory administration and IT operations.

> [!WARNING]
> **Disclaimer:** These scripts are provided as-is. Use them at your own risk. The author takes no responsibility for any damage, data loss, or unintended changes resulting from running these scripts. Always test in a non-production environment first and ensure you understand what a script does before executing it.

---

## 📋 Requirements

- PowerShell 5.1 or later
- **RSAT Active Directory module** (`ActiveDirectory`) — required by AD scripts
  - Install via: `Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0`
- Appropriate permissions to query Active Directory

---

## 📁 Scripts

| Script | Description |
|---|---|
| [`get-nested-groups-of-user-or-group.ps1`](#get-nested-groups-of-user-or-groupps1) | Export all group memberships (direct & nested) for a user or group |
| [`get-group-nesting-audit.ps1`](#get-group-nesting-auditps1) | Audit the full nesting tree of one or more AD groups |
| [`compare-aduser-group-memberships.ps1`](#compare-aduser-group-membershipsps1) | Compare group memberships across all members of an AD group to surface outliers |
| [`get-ad-ou-delegation-audit.ps1`](#get-ad-ou-delegation-auditps1) | Export custom/non-default OU delegations across an entire domain or OU subtree |

---

### `get-nested-groups-of-user-or-group.ps1`

Exports all group memberships — including nested/recursive groups — for a given AD user, or for all users within a given AD group. Results are written to a timestamped CSV file.

**Features**
- Looks up a single user's full group membership chain (direct and nested)
- Or resolves all users in a group and reports each user's full membership chain
- Deduplicates group traversal to avoid infinite loops
- Outputs a clean CSV with username, group name, membership type, and inheritance path

**Usage**

```powershell
# Interactive mode (prompts for user or group)
.\get-nested-groups-of-user-or-group.ps1

# Single user
.\get-nested-groups-of-user-or-group.ps1 -Username jdoe

# All users in a group
.\get-nested-groups-of-user-or-group.ps1 -GroupName "HelpDesk"
```

**Output columns**

| Column | Description |
|---|---|
| `Username` | SamAccountName of the user |
| `GroupName` | Name of the AD group |
| `MembershipType` | `Direct` or `Nested` |
| `InheritedFrom` | The group that granted nested membership |
| `Description` | Group description from AD |

Output is saved as a CSV in the current directory, e.g.:
- `jdoe_GroupMemberships_20250515_143022.csv`
- `Group_HelpDesk_Members_GroupMemberships_20250515_143022.csv`

---

### `get-group-nesting-audit.ps1`

Displays the full nesting tree of one or more AD groups — showing every nested group and user, the path through which they have access, and the nesting depth. Produces both a colour-coded console tree view and a timestamped CSV export.

**Features**
- Interactive console tree with colour-coded users (white = enabled, dark red = disabled) and circular-reference detection
- Flattens the tree into CSV rows with a full access path per user/group (e.g. `Domain Admins > HelpDesk > jdoe`)
- Accepts a plain-text file of group names to audit multiple groups in one run
- Summary on completion: nested group count, total/disabled users, and max nesting depth

**Usage**

```powershell
# Interactive mode (prompts for group name)
.\get-group-nesting-audit.ps1

# Single group
.\get-group-nesting-audit.ps1 -GroupName "Domain Admins"

# Multiple groups from a text file (one group name per line)
.\get-group-nesting-audit.ps1 -GroupListFile "C:\temp\groups.txt"

# Specify a custom output path for the CSV
.\get-group-nesting-audit.ps1 -GroupName "Domain Admins" -OutputPath "C:\reports\audit.csv"
```

**Output columns**

| Column | Description |
|---|---|
| `TopLevelGroup` | The group name passed in as the starting point |
| `Type` | `User` or `Group` |
| `Name` | SamAccountName (users) or group name (groups) |
| `DisplayName` | Display name of the user (blank for groups) |
| `Enabled` | `True` / `False` for users (blank for groups) |
| `AccessPath` | Full path showing how access is inherited, e.g. `Domain Admins > HelpDesk > jdoe` |
| `NestingDepth` | How many levels deep this entry sits |
| `Description` | Group description from AD (blank for users) |

Output is saved as a CSV in the current directory, e.g.:
- `GroupNestingAudit_Domain_Admins_20250515_143022.csv`
- `GroupNestingAudit_MultiGroup_20250515_143022.csv`

---

### `compare-aduser-group-memberships.ps1`

Compares group memberships across all members of an AD group, identifying which memberships are common to everyone (the baseline) and which are unique to individual users (the outliers worth investigating). Useful for spotting privilege creep or misconfigured accounts within a peer group.

**Features**
- Resolves full recursive group memberships for every user in the target group
- Classifies each membership as `Common` (shared by all) or `Unique to this user`
- Console summary ranked by unique membership count — largest outliers flagged in red
- Colour-coded output: grey (0 unique), white (1–10), yellow (11–30), red (31+, flagged for investigation)

**Usage**

```powershell
# Interactive mode (prompts for group name)
.\compare-aduser-group-memberships.ps1

# With a group name
.\compare-aduser-group-memberships.ps1 -GroupName "Helpdesk"

# With a custom output path
.\compare-aduser-group-memberships.ps1 -GroupName "Helpdesk" -OutputPath "C:\Audit\helpdesk.csv"
```

**Output columns**

| Column | Description |
|---|---|
| `Username` | SamAccountName of the user |
| `DisplayName` | Display name of the user |
| `Status` | `Common` (all users share this) or `Unique to this user` |
| `GroupName` | Name of the AD group |
| `MembershipType` | `Direct` or `Nested` |
| `InheritedFrom` | The group that granted nested membership |
| `Description` | Group description from AD |

Output is saved as a CSV in the current directory, e.g.:
- `PeerComparison_Helpdesk_20250515_143022.csv`

---

### `get-ad-ou-delegation-audit.ps1`

Exports custom, non-default ACE delegations on AD Organisational Units — filtering out inherited ACEs and well-known built-in identities so you only see what was deliberately delegated. Covers either the entire domain or a specific OU subtree. Resolves ObjectType GUIDs to human-readable names using the AD schema and Extended Rights.

**Features**
- Skips inherited ACEs and a comprehensive built-in identity exclusion list (SYSTEM, Administrators, Domain Admins, Enterprise Admins, etc.)
- Translates raw ObjectType and InheritedObjectType GUIDs to friendly names (e.g. `Reset Password`, `User`, `Group`)
- Accepts an OU by name or full Distinguished Name
- Progress output every 50 OUs for large domains
- Summary on completion: OUs scanned, OUs with custom ACEs, total ACEs, and unique delegated identities

**Usage**

```powershell
# Interactive mode (prompts for scope)
.\get-ad-ou-delegation-audit.ps1

# Entire domain
.\get-ad-ou-delegation-audit.ps1 -Scope Domain

# Specific OU and all child OUs (by name)
.\get-ad-ou-delegation-audit.ps1 -Scope OU -OUName "Helpdesk"

# Specific OU by Distinguished Name
.\get-ad-ou-delegation-audit.ps1 -Scope OU -OUName "OU=Helpdesk,DC=domain,DC=local"

# With a custom output path
.\get-ad-ou-delegation-audit.ps1 -Scope Domain -OutputPath "C:\Audit\ou_delegation.csv"
```

**Output columns**

| Column | Description |
|---|---|
| `OUName` | Display name of the OU |
| `OUDistinguishedName` | Full DN of the OU |
| `IdentityReference` | The account or group the ACE applies to |
| `AccessControlType` | `Allow` or `Deny` |
| `ActiveDirectoryRights` | The AD rights granted (e.g. `WriteProperty`, `GenericAll`) |
| `InheritanceType` | How the ACE propagates to child objects |
| `ObjectType` | The object or property the right applies to (e.g. `Reset Password`, `All`) |
| `InheritedObjectType` | The child object type the ACE applies to (e.g. `User`, `All`) |

Output is saved as a CSV in the current directory, e.g.:
- `OUDelegationAudit_FullDomain_20250515_143022.csv`
- `OUDelegationAudit_Helpdesk_20250515_143022.csv`