#################################################
# HelloID-Conn-Prov-Target-Unit4ERPx-Permissions-Roles-Grant
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

    if ($null -ne $correlatedAccount) {
        # A JSON Patch path points to an entry by its position in roleAndCompany, so each entry keeps its position in ERPx
        $roleEntries = @()
        if ($null -ne $correlatedAccount.roleAndCompany) {
            $roleEntries = @($correlatedAccount.roleAndCompany)
        }
        $roleEntriesWithPosition = for ($position = 0; $position -lt $roleEntries.Count; $position++) {
            [PSCustomObject]@{ Position = $position; Entry = $roleEntries[$position] }
        }

        $entriesOfRole = @($roleEntriesWithPosition | Where-Object { "$($_.Entry.roleId)" -eq $roleId -and "$($_.Entry.companyId)" -eq $companyId })
        $activeEntriesOfRole = @($entriesOfRole | Where-Object {
                [string]::IsNullOrEmpty("$($_.Entry.roleConnectionValidTo)") -or ([datetime]$_.Entry.roleConnectionValidTo).Date -ge (Get-Date).Date
            })
        if ($activeEntriesOfRole.Count -gt 0) {
            $lifecycleProcess = 'AlreadyGranted'
        }
        else {
            $lifecycleProcess = 'GrantPermission'
        }
    }
    else {
        $lifecycleProcess = 'NotFound'
    }

    # Process
    switch ($lifecycleProcess) {
        'GrantPermission' {
            $today = (Get-Date).ToString("yyyy-MM-dd'T'00:00:00.000", [System.Globalization.CultureInfo]::InvariantCulture)
            $endDate = '2099-12-31T00:00:00.000'
            # All existing connections of this role and company have ended. The first one is reactivated instead of adding a new one
            $endedEntry = $entriesOfRole | Select-Object -First 1
            if ($null -ne $endedEntry) {
                $operations = @(
                    [PSCustomObject]@{ op = 'replace'; path = "/roleAndCompany/$($endedEntry.Position)/roleConnectionValidFrom"; value = $today },
                    [PSCustomObject]@{ op = 'replace'; path = "/roleAndCompany/$($endedEntry.Position)/roleConnectionValidTo"; value = $endDate }
                )
            }
            else {
                $operations = @(
                    [PSCustomObject]@{
                        op    = 'add'
                        path  = '/roleAndCompany/-'
                        value = [PSCustomObject]@{
                            companyId               = $companyId
                            roleId                  = $roleId
                            roleConnectionValidFrom = $today
                            roleConnectionValidTo   = $endDate
                        }
                    }
                )
            }

            $splatUpdateParams = @{
                Uri         = "$($actionContext.Configuration.BaseUrl)/v1/users/$([System.Uri]::EscapeDataString($actionContext.References.Account))?companyId=$([System.Uri]::EscapeDataString($actionContext.Configuration.CompanyId))"
                Method      = 'PATCH'
                Headers     = $headers
                Body        = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject @($operations) -Depth 10))
                ContentType = 'application/json-patch+json; charset=utf-8'
            }

            if (-not($actionContext.DryRun -eq $true)) {
                Write-Information "Granting Unit4ERPx permission: [$permissionName] - [$roleId]"
                $null = Invoke-RestMethod @splatUpdateParams -Verbose:$false
            }
            else {
                Write-Information "[DryRun] Grant Unit4ERPx permission: [$permissionName] - [$roleId], will be executed during enforcement"
            }

            $outputContext.Success = $true
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = "Grant permission [$permissionName] was successful"
                    IsError = $false
                })
            break
        }

        'AlreadyGranted' {
            Write-Information "Unit4ERPx permission: [$permissionName] - [$roleId] is already granted to account [$($actionContext.References.Account)]"
            $outputContext.Success = $true
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = "Grant permission [$permissionName] was successful. The role was already granted in company [$companyId]"
                    IsError = $false
                })
            break
        }

        'NotFound' {
            Write-Information "Unit4ERPx account: [$($actionContext.References.Account)] could not be found, indicating that it may have been deleted"
            $outputContext.Success = $false
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = "Unit4ERPx account: [$($actionContext.References.Account)] could not be found, indicating that it may have been deleted"
                    IsError = $true
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
        $auditLogMessage = "Could not grant Unit4ERPx permission [$($actionContext.References.Permission.Reference)] for account: [$($actionContext.References.Account)]. Error: $($errorObj.FriendlyMessage)"
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditLogMessage = "Could not grant Unit4ERPx permission [$($actionContext.References.Permission.Reference)] for account: [$($actionContext.References.Account)]. Error: $($ex.Exception.Message)"
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Message = $auditLogMessage
            IsError = $true
        })
}
