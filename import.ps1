#################################################
# HelloID-Conn-Prov-Target-Unit4ERPx-Import
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

function ConvertTo-Unit4ERPxAccountObject {
    [CmdletBinding()]
    param (
        [object]
        $Account,

        [string[]]
        $FieldNames
    )
    # Builds an object with the same (nested) structure as the field mapping, with the values of the ERPx user
    $contactPointPaths = @{
        'contactPoints.eMail'       = 'additionalContactInfo.eMail'
        'contactPoints.countryCode' = 'address.countryCode'
    }
    $contactPoint = @($Account.contactPoints) | Where-Object { $null -ne $_ -and "$($_.contactPointType)" -eq "$($actionContext.Configuration.ContactPointType)" } | Select-Object -First 1
    $result = [PSCustomObject]@{}
    foreach ($fieldName in $FieldNames) {
        if ($fieldName.StartsWith('_extension.')) {
            continue
        }
        if ($fieldName.StartsWith('contactPoints.')) {
            if (-not $contactPointPaths.ContainsKey($fieldName)) {
                throw "Field mapping [$fieldName] is not supported. Supported contact point fields: [$($contactPointPaths.Keys -join ', ')]"
            }
            $value = $contactPoint
            $sourcePath = $contactPointPaths[$fieldName]
        }
        else {
            $value = $Account
            $sourcePath = $fieldName
        }
        foreach ($segment in $sourcePath.Split('.')) {
            $value = $value.$segment
        }
        # PowerShell 7 returns ERPx dates as [datetime], while the field mapping fields are text
        if ($value -is [datetime]) {
            $value = $value.ToString("yyyy-MM-dd'T'HH:mm:ss.fff", [System.Globalization.CultureInfo]::InvariantCulture)
        }

        $segments = $fieldName.Split('.')
        $target = $result
        for ($i = 0; $i -lt ($segments.Count - 1); $i++) {
            if ($null -eq $target.($segments[$i])) {
                $target | Add-Member -NotePropertyName $segments[$i] -NotePropertyValue ([PSCustomObject]@{})
            }
            $target = $target.($segments[$i])
        }
        $target | Add-Member -NotePropertyName $segments[-1] -NotePropertyValue $value -Force
    }
    Write-Output $result
}
#endregion

try {
    Write-Information 'Starting Unit4ERPx account entitlement import'
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

    $pageSize = 100
    $offset = 0
    do {
        $splatGetUsersParams = @{
            Uri     = "$($actionContext.Configuration.BaseUrl)/v1/objects/users?companyId=$([System.Uri]::EscapeDataString($actionContext.Configuration.CompanyId))&orderBy=userId&offset=$offset&limit=$pageSize"
            Method  = 'GET'
            Headers = $headers
        }
        $importedAccounts = @((Invoke-RestMethod @splatGetUsersParams -Verbose:$false) | Where-Object { $null -ne $_ })
        Write-Information "Retrieved [$($importedAccounts.Count)] Unit4ERPx accounts from offset [$offset]"

        foreach ($importedAccount in $importedAccounts) {
            if ([string]::IsNullOrEmpty($importedAccount.userId)) {
                continue
            }

            # Making sure only fieldMapping fields are imported (nested like the field mapping)
            $data = ConvertTo-Unit4ERPxAccountObject -Account $importedAccount -FieldNames @($actionContext.ImportFields)

            # Enabled: status N and dateTo has not passed (same definition as enable and disable)
            $isEnabled = ("$($importedAccount.userStatus.status)" -eq 'N' -and ([string]::IsNullOrEmpty("$($importedAccount.userStatus.dateTo)") -or ([datetime]$importedAccount.userStatus.dateTo).Date -ge (Get-Date).Date))

            # Make sure the displayName has a value
            $displayName = "$($importedAccount.description)".Trim()
            if ([string]::IsNullOrEmpty($displayName)) {
                $displayName = "$($importedAccount.userName)".Trim()
            }
            if ([string]::IsNullOrEmpty($displayName)) {
                $displayName = "$($importedAccount.userId)"
            }

            # The userName is the userId (the NetwerkgebruikersID)
            $userName = "$($importedAccount.userId)"

            # Return the result
            Write-Output @{
                AccountReference = "$($importedAccount.userId)"
                DisplayName      = $displayName
                UserName         = $userName.Substring(0, [math]::Min($userName.Length, 100))
                Enabled          = $isEnabled
                Data             = $data
            }
        }
        $offset += $importedAccounts.Count
    } while ($importedAccounts.Count -eq $pageSize)
    Write-Information 'Unit4ERPx account entitlement import completed'
}
catch {
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-Unit4ERPxError -ErrorObject $ex
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
        Write-Error "Could not import Unit4ERPx account entitlements. Error: $($errorObj.FriendlyMessage)"
    }
    else {
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
        Write-Error "Could not import Unit4ERPx account entitlements. Error: $($ex.Exception.Message)"
    }
}
