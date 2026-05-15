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

## 🤝 Contributing

Issues and pull requests are welcome. When adding a new script, please:

1. Include a comment block at the top of the script with a description and usage examples
2. Add an entry for it in the **Scripts** section of this README

---

## 📄 License

MIT
