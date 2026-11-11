#################################################
# HelloID-Conn-Prov-Target-Unit4ERPx-Permissions-Roles-Import
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

try {
    Write-Information 'Starting Unit4ERPx permission entitlement import'
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

    $companyId = "$($actionContext.Configuration.CompanyId)"
    # The DefaultRoleId is part of the account lifecycle (create) and is not imported as a permission
    $defaultRoleId = "$($actionContext.Configuration.DefaultRoleId)"
    # Objects are read per page (offset/limit). A page with less than [limit] results is the last page
    $pageSize = 100

    # Role descriptions for the display names
    $roleDescriptions = @{}
    $offset = 0
    do {
        $splatGetRolesParams = @{
            Uri     = "$($actionContext.Configuration.BaseUrl)/v1/objects/roles?companyId=$([System.Uri]::EscapeDataString($companyId))&orderBy=roleId&offset=$offset&limit=$pageSize"
            Method  = 'GET'
            Headers = $headers
        }
        $roles = @((Invoke-RestMethod @splatGetRolesParams -Verbose:$false) | Where-Object { $null -ne $_ })
        foreach ($role in $roles) {
            if (-not [string]::IsNullOrEmpty($role.roleId)) {
                $roleDescriptions["$($role.roleId)"] = "$($role.description)"
            }
        }
        $offset += $roles.Count
    } while ($roles.Count -eq $pageSize)

    # Role connections of the company that have not ended, returned to HelloID per page.
    # HelloID combines the account references of the same permission reference
    $offset = 0
    do {
        $splatGetConnectionsParams = @{
            Uri     = "$($actionContext.Configuration.BaseUrl)/v1/objects/user-role-company-connections?companyId=$([System.Uri]::EscapeDataString($companyId))&orderBy=userId&offset=$offset&limit=$pageSize"
            Method  = 'GET'
            Headers = $headers
        }
        $connections = @((Invoke-RestMethod @splatGetConnectionsParams -Verbose:$false) | Where-Object { $null -ne $_ })
        Write-Information "Retrieved [$($connections.Count)] role connections from offset [$offset]"

        $activeConnections = $connections | Where-Object {
            -not [string]::IsNullOrEmpty($_.userId) -and
            -not [string]::IsNullOrEmpty($_.roleId) -and
            "$($_.companyId)" -eq $companyId -and
            "$($_.roleId)" -ne $defaultRoleId -and
            ([string]::IsNullOrEmpty("$($_.roleConnectionValidTo)") -or ([datetime]$_.roleConnectionValidTo).Date -ge (Get-Date).Date)
        }

        foreach ($connectionsPerRole in ($activeConnections | Group-Object -Property roleId)) {
            $roleKey = "$($connectionsPerRole.Name)"
            $displayName = $roleKey
            if (-not [string]::IsNullOrEmpty($roleDescriptions[$roleKey])) {
                $displayName = "$($roleDescriptions[$roleKey]) ($roleKey)"
            }
            Write-Output @{
                PermissionReference = @{
                    Reference = $roleKey
                }
                Description         = "$($roleDescriptions[$roleKey])"
                DisplayName         = $displayName
                AccountReferences   = [string[]]@($connectionsPerRole.Group.userId | Select-Object -Unique)
            }
        }
        $offset += $connections.Count
    } while ($connections.Count -eq $pageSize)
    Write-Information 'Unit4ERPx permission entitlement import completed'
}
catch {
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-Unit4ERPxError -ErrorObject $ex
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
        Write-Error "Could not import Unit4ERPx permission entitlements. Error: $($errorObj.FriendlyMessage)"
    }
    else {
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
        Write-Error "Could not import Unit4ERPx permission entitlements. Error: $($ex.Exception.Message)"
    }
}
