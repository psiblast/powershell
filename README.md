# 🛠️ PowerShell Scripts

A collection of utility PowerShell scripts for Active Directory administration and IT operations.

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

## 🤝 Contributing

Issues and pull requests are welcome. When adding a new script, please:

1. Include a comment block at the top of the script with a description and usage examples
2. Add an entry for it in the **Scripts** section of this README

---

## 📄 License

MIT