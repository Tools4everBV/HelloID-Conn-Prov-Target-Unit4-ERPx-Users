#################################################
# HelloID-Conn-Prov-Target-Unit4ERPx-Permissions-Roles-Revoke
# PowerShell V2
#################################################

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

#region functions
function Resolve-Unit4ERPxError {
    [CmdletBinding()]
    param (
        [object]
        $ErrorObject
    )
    process {
        if ($null -eq $ErrorObject) {
            throw 'Resolve-Unit4ERPxError: parameter [ErrorObject] is empty'
        }
        $httpErrorObj = [PSCustomObject]@{
            ScriptLineNumber = $ErrorObject.InvocationInfo.ScriptLineNumber
            Line             = $ErrorObject.InvocationInfo.Line
            ErrorDetails     = $ErrorObject.Exception.Message
            FriendlyMessage  = $ErrorObject.Exception.Message
        }
        if (-not [string]::IsNullOrEmpty($ErrorObject.ErrorDetails.Message)) {
            $httpErrorObj.ErrorDetails = $ErrorObject.ErrorDetails.Message
        }
        elseif ($ErrorObject.Exception.GetType().FullName -eq 'System.Net.WebException') {
            if ($null -ne $ErrorObject.Exception.Response) {
                $streamReaderResponse = [System.IO.StreamReader]::new($ErrorObject.Exception.Response.GetResponseStream()).ReadToEnd()
                if (-not [string]::IsNullOrEmpty($streamReaderResponse)) {
                    $httpErrorObj.ErrorDetails = $streamReaderResponse
                }
            }
        }
        try {
            $errorDetailsObject = ($httpErrorObj.ErrorDetails | ConvertFrom-Json)
            if (-not [string]::IsNullOrEmpty($errorDetailsObject.error_description)) {
                # Token endpoint error
                $httpErrorObj.FriendlyMessage = "$($errorDetailsObject.error): $($errorDetailsObject.error_description)"
            }
            elseif (-not [string]::IsNullOrEmpty($errorDetailsObject.error)) {
                $httpErrorObj.FriendlyMessage = "$($errorDetailsObject.error)"
            }
            elseif (-not [string]::IsNullOrEmpty($errorDetailsObject.message)) {
                # Unit4.PublicApi.NotificationInformation { code, message }
                $httpErrorObj.FriendlyMessage = "$($errorDetailsObject.message)"
            }
            else {
                # HTTP 422 returns the posted object with notificationMessages per (sub)object.
                $notifications = [System.Collections.Generic.List[string]]::new()
                $notificationDetails = [System.Collections.Generic.List[string]]::new()
                Get-Unit4ERPxNotificationMessage -InputObject $errorDetailsObject -Path '' -Result $notifications -Details $notificationDetails
                if ($notifications.Count -gt 0) {
                    $httpErrorObj.FriendlyMessage = @($notifications | Select-Object -Unique) -join '; '
                    $httpErrorObj.ErrorDetails = $notificationDetails -join '; '
                }
                else {
                    $httpErrorObj.FriendlyMessage = $httpErrorObj.ErrorDetails
                }
            }
        }
        catch {
            $httpErrorObj.FriendlyMessage = $httpErrorObj.ErrorDetails
            Write-Warning $_.Exception.Message
        }
        Write-Output $httpErrorObj
    }
}

function Get-Unit4ERPxNotificationMessage {
    [CmdletBinding()]
    param (
        [object]
        $InputObject,

        [string]
        $Path,

        [System.Collections.Generic.List[string]]
        $Result,

        [System.Collections.Generic.List[string]]
        $Details
    )
    if ($null -eq $InputObject -or $InputObject -is [string] -or $InputObject.GetType().IsValueType) {
        return
    }
    if ($InputObject -is [System.Collections.IEnumerable]) {
        $index = 0
        foreach ($item in $InputObject) {
            Get-Unit4ERPxNotificationMessage -InputObject $item -Path "$Path[$index]" -Result $Result -Details $Details
            $index++
        }
        return
    }
    foreach ($property in $InputObject.PSObject.Properties) {
        if ($property.Name -eq 'notificationMessages') {
            if ($null -eq $property.Value) {
                continue
            }
            $label = $Path.TrimStart('.')
            if ([string]::IsNullOrEmpty($label)) { $label = 'user' }
            # notificationMessages is { <field>: [ { code, message } ] }
            foreach ($field in $property.Value.PSObject.Properties) {
                foreach ($notification in @($field.Value)) {
                    if ($null -ne $notification -and -not [string]::IsNullOrEmpty($notification.message)) {
                        $Result.Add("$($notification.message)")
                        $Details.Add("$label.$($field.Name): [$($notification.code)] $($notification.message)")
                    }
                    elseif ($null -ne $notification) {
                        $message = $notification | ConvertTo-Json -Depth 5 -Compress
                        $Result.Add("$label.$($field.Name): $message")
                        $Details.Add("$label.$($field.Name): $message")
                    }
                }
            }
        }
        else {
            Get-Unit4ERPxNotificationMessage -InputObject $property.Value -Path "$Path.$($property.Name)" -Result $Result -Details $Details
        }
    }
}
#endregion

# Begin
try {
    # Verify if [accountReference] has a value
    if ([string]::IsNullOrEmpty($($actionContext.References.Account))) {
        throw 'The account reference could not be found'
    }
    $roleId = "$($actionContext.References.Permission.Reference)"
    if ([string]::IsNullOrEmpty($roleId)) {
        throw 'The permission reference could not be found'
    }
    $companyId = "$($actionContext.Configuration.CompanyId)"
    $permissionName = $actionContext.PermissionDisplayName
    if ([string]::IsNullOrEmpty($permissionName)) {
        $permissionName = $roleId
    }

    # Retrieve an access token
    $splatTokenParams = @{
        Uri         = $actionContext.Configuration.TokenUrl
        Method      = 'POST'
        ContentType = 'application/x-www-form-urlencoded'
        Body        = @{
            client_id     = $actionContext.Configuration.ClientId
            client_secret = $actionContext.Configuration.ClientSecret
            scope         = $actionContext.Configuration.Scope
            grant_type    = 'client_credentials'
        }
    }
    $accessToken = (Invoke-RestMethod @splatTokenParams -Verbose:$false).access_token
    $headers = @{
        Authorization = "Bearer $accessToken"
        Accept        = 'application/json'
    }

    Write-Information 'Verifying if a Unit4ERPx account exists'
    $splatGetUserParams = @{
        Uri     = "$($actionContext.Configuration.BaseUrl)/v1/users/$([System.Uri]::EscapeDataString($actionContext.References.Account))?companyId=$([System.Uri]::EscapeDataString($actionContext.Configuration.CompanyId))"
        Method  = 'GET'
        Headers = $headers
    }
    $correlatedAccount = $null
    try {
        $correlatedAccount = Invoke-RestMethod @splatGetUserParams -Verbose:$false
    }
    catch {
        # HTTP 404 means the account does not exist
        if ([int]$_.Exception.Response.StatusCode -ne 404) {
            throw
        }
    }

    # The DefaultRoleId belongs to the account lifecycle and is not a permission (excluded from the permission list and import).
    # Its entry is the default role and company entry, which links the user to the employee and is never removed.
    # ERPx can fill personId on every entry, so personId does not identify the default entry
    $isDefaultRole = (-not [string]::IsNullOrEmpty($actionContext.Configuration.DefaultRoleId) -and $roleId -eq "$($actionContext.Configuration.DefaultRoleId)")
    if ($null -ne $correlatedAccount) {
        # A JSON Patch path points to an entry by its position in roleAndCompany, so each entry keeps its position in ERPx
        $roleEntries = @()
        if ($null -ne $correlatedAccount.roleAndCompany) {
            $roleEntries = @($correlatedAccount.roleAndCompany)
        }
        $roleEntriesWithPosition = for ($position = 0; $position -lt $roleEntries.Count; $position++) {
            [PSCustomObject]@{ Position = $position; Entry = $roleEntries[$position] }
        }

        $entriesToRemove = @($roleEntriesWithPosition | Where-Object { -not $isDefaultRole -and "$($_.Entry.roleId)" -eq $roleId -and "$($_.Entry.companyId)" -eq $companyId })
        if ($entriesToRemove.Count -gt 0) {
            $lifecycleProcess = 'RevokePermission'
        }
        else {
            $lifecycleProcess = 'AlreadyRevoked'
        }
    }
    else {
        $lifecycleProcess = 'NotFound'
    }

    # Process
    switch ($lifecycleProcess) {
        'RevokePermission' {
            # Removing an entry moves the entries after it one position up, so the last entry is removed first
            $operations = foreach ($entry in ($entriesToRemove | Sort-Object -Property Position -Descending)) {
                [PSCustomObject]@{ op = 'remove'; path = "/roleAndCompany/$($entry.Position)" }
            }

            $splatUpdateParams = @{
                Uri         = "$($actionContext.Configuration.BaseUrl)/v1/users/$([System.Uri]::EscapeDataString($actionContext.References.Account))?companyId=$([System.Uri]::EscapeDataString($actionContext.Configuration.CompanyId))"
                Method      = 'PATCH'
                Headers     = $headers
                Body        = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject @($operations) -Depth 10))
                ContentType = 'application/json-patch+json; charset=utf-8'
            }

            if (-not($actionContext.DryRun -eq $true)) {
                Write-Information "Revoking Unit4ERPx permission: [$permissionName] - [$roleId]"
                $null = Invoke-RestMethod @splatUpdateParams -Verbose:$false
            }
            else {
                Write-Information "[DryRun] Revoke Unit4ERPx permission: [$permissionName] - [$roleId], will be executed during enforcement"
            }

            $outputContext.Success = $true
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = "Revoke permission: [$permissionName] from [$($actionContext.References.Account)] was successful. Action initiated by: [$($actionContext.Origin)]"
                    IsError = $false
                })
            break
        }

        'AlreadyRevoked' {
            $message = "Revoke permission: [$permissionName] from [$($actionContext.References.Account)] was successful. The role was not granted in company [$companyId]. Action initiated by: [$($actionContext.Origin)]"
            if ($isDefaultRole) {
                $message = "Revoke permission: [$permissionName] from [$($actionContext.References.Account)] was successful. The role is the DefaultRoleId of the account lifecycle and is kept in the default role and company entry. Action initiated by: [$($actionContext.Origin)]"
            }
            Write-Information $message
            $outputContext.Success = $true
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = $message
                    IsError = $false
                })
            break
        }

        'NotFound' {
            Write-Information "Unit4ERPx account: [$($actionContext.References.Account)] could not be found, indicating that it may have been deleted"
            $outputContext.Success = $true
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = "Unit4ERPx account: [$($actionContext.References.Account)] could not be found, indicating that it may have been deleted. Action initiated by: [$($actionContext.Origin)]"
                    IsError = $false
                })
            break
        }
    }
}
catch {
    $outputContext.success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-Unit4ERPxError -ErrorObject $ex
        $auditLogMessage = "Could not revoke Unit4ERPx permission [$($actionContext.References.Permission.Reference)] for account: [$($actionContext.References.Account)]. Error: $($errorObj.FriendlyMessage). Action initiated by: [$($actionContext.Origin)]"
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditLogMessage = "Could not revoke Unit4ERPx permission [$($actionContext.References.Permission.Reference)] for account: [$($actionContext.References.Account)]. Error: $($ex.Exception.Message). Action initiated by: [$($actionContext.Origin)]"
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Message = $auditLogMessage
            IsError = $true
        })
}
