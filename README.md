# HelloID-Conn-Prov-Target-Unit4ERPx

> [!IMPORTANT]
> This repository contains the connector and configuration code only. The implementer is responsible to acquire the connection details such as username, password, certificate, etc. You might even need to sign a contract or agreement with the supplier before implementing this connector. Please contact the client's application manager to coordinate the connector requirements.

<p align="center">
  <img src="">
</p>

## Table of contents

- [HelloID-Conn-Prov-Target-Unit4ERPx](#helloid-conn-prov-target-unit4erpx)
  - [Table of contents](#table-of-contents)
  - [Introduction](#introduction)
  - [Supported features](#supported-features)
    - [⚠️ Governance Reconciliation Resolutions](#️-governance-reconciliation-resolutions)
  - [Getting started](#getting-started)
    - [HelloID Icon URL](#helloid-icon-url)
    - [Requirements](#requirements)
    - [Connection settings](#connection-settings)
    - [Correlation configuration](#correlation-configuration)
    - [Field mapping](#field-mapping)
    - [Account Reference](#account-reference)
  - [Remarks](#remarks)
    - [Account status](#account-status)
    - [No delete](#no-delete)
    - [Default role and company entry](#default-role-and-company-entry)
    - [Permissions: roles per company](#permissions-roles-per-company)
    - [Entitlement import](#entitlement-import)
  - [Development resources](#development-resources)
    - [API endpoints](#api-endpoints)
    - [API documentation](#api-documentation)
  - [Getting help](#getting-help)
  - [HelloID docs](#helloid-docs)

## Introduction

_HelloID-Conn-Prov-Target-Unit4ERPx_ is a _target_ connector. It manages **user accounts** in _Unit4 ERPx_ through the Unit4 ERPx REST API, and the roles of these users in one company (administration). Employees (resources) are not managed by this connector.

## Supported features

The following features are available:

| Feature                                   | Supported | Actions                         | Remarks                                                          |
| ----------------------------------------- | --------- | ------------------------------- | ---------------------------------------------------------------- |
| **Account Lifecycle**                     | ✅         | Create, Update, Enable, Disable | No delete, see [No delete](#no-delete)                           |
| **Permissions**                           | ✅         | Retrieve, Grant, Revoke         | Static: roles in the configured company (`roleAndCompany`)       |
| **Resources**                             | ❌         | -                               |                                                                  |
| **Entitlement Import: Accounts**          | ✅         | -                               | All users returned for the configured company                    |
| **Entitlement Import: Permissions**       | ✅         | -                               | Role connections in the configured company that have not ended   |
| **Governance Reconciliation Resolutions** | ✅⚠️        | -                               | No delete: an unexpected account can only be disabled            |

### ⚠️ Governance Reconciliation Resolutions

The connector has no delete action. A resolution that requires deleting an account is not possible; the account can be disabled.

## Getting started

### HelloID Icon URL

URL of the icon used for the HelloID Provisioning target system.

```
TODO: add the icon URL once the connector is published on GitHub
```

### Requirements

- **Machine-to-machine client in the Unit4 Identity Server**:<br>
  A client ID and secret for the OAuth2 client credentials flow, with access to the Unit4 ERPx API.
- **Rights for the API user in Unit4 ERPx**:<br>
  The ERPx user behind the client must be allowed to read and change users and to read roles and role connections.
- **Existing resources (employees)**:<br>
  When the default role and company entry is sent with a `personId`, the personnel number must exist as a resource in the ERPx company.

### Connection settings

The following settings are required to connect to the API.

| Setting                                | Description                                                                                                     | Mandatory |
| -------------------------------------- | --------------------------------------------------------------------------------------------------------------- | --------- |
| ClientId                               | The client ID of the machine-to-machine client in the Unit4 Identity Server                                     | Yes       |
| ClientSecret                           | The client secret of the machine-to-machine client                                                              | Yes       |
| TokenUrl                               | The token endpoint of the Unit4 Identity Server (`.../identity/connect/token`)                                  | Yes       |
| Scope                                  | The OAuth scope for the Unit4 ERPx API. Default: `u4erp`                                                        | Yes       |
| BaseUrl                                | The URL to the Unit4 ERPx API                                                                                   | Yes       |
| CompanyId                              | The ERPx company (administration) used for all calls, the default role and company entry and the roles          | Yes       |
| ContactPointType                       | The `contactPointType` (ERPx ADRESTYPE) of the user contact point that holds the e-mail address, default `1`.   | No        |
| Add default role and company on create | When enabled, create sends one `roleAndCompany` entry for CompanyId and sets `defaultLogonCompany` to CompanyId | No        |
| DefaultRoleId                          | The `roleId` of the default role and company entry.                                                             | No        |

### Correlation configuration

The correlation configuration is used to specify which properties will be used to match an existing account within _Unit4 ERPx_ to a person in _HelloID_.

| Setting                   | Value               |
| ------------------------- | ------------------- |
| Enable correlation        | `True`              |
| Person correlation field  | `Person.ExternalId` |
| Account correlation field | `userId`            |

Correlation is an exact lookup with `GET /v1/users/{userId}`, so only the account field `userId` is supported. The person correlation field must hold the same value as the `userId` field mapping. Create fails with a clear error when the correlation value and the mapped `userId` differ, to prevent a duplicate account under another key.

> [!TIP]
> _For more information on correlation, please refer to our correlation [documentation](https://docs.helloid.com/en/provisioning/target-systems/powershell-v2-target-systems/correlation.html) pages_.

### Field mapping

The field mapping can be imported by using the _fieldMapping.json_ file. The field names are the Unit4 ERPx property names. A `.` in a field name is a nested object, for example `security.unit4Id`.

- HelloID supports one nesting level in field names, so the contact point fields have short names. The connector maps them to the ERPx path:
  -  `contactPoints.eMail` → `additionalContactInfo.eMail`
  -  `contactPoints.countryCode` → `address.countryCode`.
  -  `contactPoints.*` fields are not supported.
- On create, the contact point fields are combined into one contact point (with `contactPointType` = **ContactPointType** when it is set). On update, a changed contact point field is replaced in the contact point of type **ContactPointType**; when that contact point does not exist, the changed fields are added as one new contact point.
- Fields in `_extension` are not sent as user fields.
- The field mapping is dynamic: a field that is added to the field mapping is sent to and read from the same path in ERPx (`security.unit4Id` → `security.unit4Id`), without changes to the scripts. Only the `contactPoints.*` fields have a fixed translation.

### Account Reference

The account reference is populated with the property `userId` from _Unit4 ERPx_.

## Remarks

### Account status

| Action  | `userStatus`                                                                                                                                         |
| ------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| Create  | `status` = `P` (parked, inactive), `dateFrom` = today, `dateTo` = `2099-12-31`. The default role and company entry gets `roleConnectionStatus` = `N` |
| Enable  | `status` = `N` (active). `dateTo` is set to `2099-12-31` when it is today or earlier                                                                 |
| Disable | `status` = `P` (parked). `dateTo` is set to today when it is empty or later than today. `dateFrom` is not changed                                    |

### No delete

Delete is not implemented, because it is not required. Accounts stay in Unit4 ERPx with status `P` after disable. The API has `DELETE /v1/users/{userId}`, which sets the status to `T` (terminated); it is not used by the connector.

### Default role and company entry

With **Add default role and company on create** enabled, create sends `defaultLogonCompany` = CompanyId and one `roleAndCompany` entry:

- `companyId` = CompanyId.
- `personId` = the mapped `_extension.personId` (personnel number)
- `roleId` = DefaultRoleId
- Valid from today (Get-Date) to `2099-12-31`.

According to the Swagger specification `roleAndCompany` is not required, during development it was found that the API may require it in practice. The entry is only set on create. Other roles are managed with permissions.


### Permissions: roles per company

The permission scripts are in `permissions/roles`.

- **Retrieve:** the active roles (`status` = `N`) of CompanyId, except the **DefaultRoleId**. The permission reference is the `roleId`.
- **DefaultRoleId is not a permission:** it is part of the account lifecycle (create), so it is not in the permission list and not in the permission import.
- **Grant:** adds a `roleAndCompany` entry for CompanyId, valid from today to `2099-12-31`.
- **Revoke:** removes all `roleAndCompany` entries of the role in CompanyId, also when they have a `personId` (ERPx can fill `personId` on every entry). The **default entry** is the entry of the DefaultRoleId; it is never removed, because it links the user to the employee.

### Entitlement import

- **Accounts:** all users of CompanyId, read in pages of 100 with `orderBy=userId`. Each page is returned to HelloID before the next page is read. An account is enabled when `userStatus.status` is `N` and `userStatus.dateTo` has not passed (see [Account status](#account-status)).
- **Permissions:** all role memberships of CompanyId of which `roleConnectionValidTo` has not passed. HelloID combines the account references of the same role. Roles without members are not returned. Roles with the DefaultRoleId are not imported.

## Development resources

### API endpoints

The following endpoints are used by the connector

| Endpoint                                     | HTTP Method | Description                                                         |
| -------------------------------------------- | ----------- | ------------------------------------------------------------------- |
| `{TokenUrl}`                                 | POST        | Retrieve an access token (client credentials)                       |
| `/v1/users`                                  | POST        | Create a user                                                       |
| `/v1/users/{userId}?companyId={CompanyId}`   | GET         | Correlate, and retrieve the user before every action                |
| `/v1/users/{userId}?companyId={CompanyId}`   | PATCH       | Update, enable, disable, grant and revoke (JSON Patch)              |
| `/v1/objects/users`                          | GET         | Account entitlement import                                          |
| `/v1/objects/roles`                          | GET         | Retrieve roles (permissions and permission import)                  |
| `/v1/objects/user-role-company-connections`  | GET         | Permission entitlement import                                       |

### API documentation

The Swagger documentation (Unit4 WebAPI, OpenAPI 3) is available per Unit4 ERPx environment at `{BaseUrl}/swagger`. The object definitions refer to the Unit4 ontology: https://ontology-latest.u4pp.com.

## Getting help

> [!TIP]
> _For more information on how to configure a HelloID PowerShell connector, please refer to our [documentation](https://docs.helloid.com/en/provisioning/target-systems/powershell-v2-target-systems.html) pages_.

## HelloID docs

The official HelloID documentation can be found at: https://docs.helloid.com/
