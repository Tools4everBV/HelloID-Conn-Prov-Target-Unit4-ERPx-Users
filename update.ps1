#################################################
# HelloID-Conn-Prov-Target-Unit4ERPx-Update
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

function Get-Unit4ERPxFlatProperty {
    [CmdletBinding()]
    param (
        [object]
        $InputObject,

        [string]
        $Prefix
    )
    # Flattens nested field mapping objects to dotted names, e.g. security.unit4Id
    $result = [ordered]@{}
    if ($null -eq $InputObject) {
        return $result
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $properties = foreach ($key in $InputObject.Keys) { [PSCustomObject]@{ Name = "$key"; Value = $InputObject[$key] } }
    }
    else {
        $properties = $InputObject.PSObject.Properties | Select-Object -Property Name, Value
    }
    foreach ($property in $properties) {
        $name = $property.Name
        if (-not [string]::IsNullOrEmpty($Prefix)) {
            $name = "$Prefix.$($property.Name)"
        }
        if (($null -ne $property.Value -and $property.Value.GetType().Name -eq 'PSCustomObject') -or $property.Value -is [System.Collections.IDictionary]) {
            $nestedResult = Get-Unit4ERPxFlatProperty -InputObject $property.Value -Prefix $name
            foreach ($key in $nestedResult.Keys) {
                $result[$key] = $nestedResult[$key]
            }
        }
        else {
            $result[$name] = $property.Value
        }
    }
    Write-Output $result
}

function ConvertTo-Unit4ERPxApiValue {
    [CmdletBinding()]
    param (
        [string]
        $FieldName,

        [object]
        $Value
    )
    # Boolean fields in the ERPx user schema. Fixed field mappings deliver these as text
    $booleanFields = @('usage.isAdministrator', 'usage.availableInMenuAccess', 'usage.isEnabledForWorkflowProcess')
    if ($FieldName -in $booleanFields -and "$Value" -match '^(?i)(true|false)$') {
        return [System.Convert]::ToBoolean("$Value")
    }
    # Date fields in the ERPx user schema. HelloID can deliver these as [datetime] or as text in a culture specific format (e.g. 1-1-1900 00:00:00),
    # while ERPx only accepts ISO 8601
    $dateFields = @('security.disabledUntil', 'security.passwordExpiryDate')
    if ($Value -is [datetime] -or ($FieldName -in $dateFields -and -not [string]::IsNullOrEmpty("$Value"))) {
        if ($Value -isnot [datetime]) {
            $parsedDate = [datetime]::MinValue
            $styles = [System.Globalization.DateTimeStyles]::None
            if (-not ([datetime]::TryParse("$Value", [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsedDate) -or
                    [datetime]::TryParse("$Value", [System.Globalization.CultureInfo]::CurrentCulture, $styles, [ref]$parsedDate) -or
                    [datetime]::TryParse("$Value", [System.Globalization.CultureInfo]::GetCultureInfo('nl-NL'), $styles, [ref]$parsedDate))) {
                throw "The value [$Value] of field mapping [$FieldName] is not a valid date"
            }
            $Value = $parsedDate
        }
        return $Value.ToString("yyyy-MM-dd'T'00:00:00.000", [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return $Value
}

function ConvertTo-Unit4ERPxUpdateBody {
    [CmdletBinding()]
    param (
        [System.Collections.Specialized.OrderedDictionary]
        $MappedData,

        [string[]]
        $ChangedFieldNames,

        [object]
        $Account
    )
    $contactPointPaths = @{
        'contactPoints.eMail'       = 'additionalContactInfo.eMail'
        'contactPoints.countryCode' = 'address.countryCode'
    }

    # A JSON Patch path points to a contact point by its position in contactPoints, so the position in ERPx is used
    $contactPoints = @()
    if ($null -ne $Account.contactPoints) {
        $contactPoints = @($Account.contactPoints)
    }
    $contactPointPosition = $null
    for ($position = 0; $position -lt $contactPoints.Count; $position++) {
        if ("$($contactPoints[$position].contactPointType)" -eq "$($actionContext.Configuration.ContactPointType)") {
            $contactPointPosition = $position
            break
        }
    }

    # Build the JSON Patch operations 1:1 from the changed field mapping fields.
    # When the contact point does not exist yet, the contactPoints.* fields are combined into one new contact point
    $operations = [System.Collections.Generic.List[object]]::new()
    $newContactPoint = [ordered]@{}
    foreach ($fieldName in $ChangedFieldNames) {
        $value = ConvertTo-Unit4ERPxApiValue -FieldName $fieldName -Value $MappedData[$fieldName]
        if (-not $fieldName.StartsWith('contactPoints.')) {
            $operations.Add([PSCustomObject]@{ op = 'replace'; path = '/' + $fieldName.Replace('.', '/'); value = $value })
            continue
        }
        if (-not $contactPointPaths.ContainsKey($fieldName)) {
            throw "Field mapping [$fieldName] is not supported. Supported contact point fields: [$($contactPointPaths.Keys -join ', ')]"
        }
        $path = $contactPointPaths[$fieldName]
        if ($null -ne $contactPointPosition) {
            $operations.Add([PSCustomObject]@{ op = 'replace'; path = "/contactPoints/$contactPointPosition/" + $path.Replace('.', '/'); value = $value })
            continue
        }

        $target = $newContactPoint
        $segments = $path.Split('.')
        for ($i = 0; $i -lt ($segments.Count - 1); $i++) {
            if (-not $target.Contains($segments[$i])) {
                $target[$segments[$i]] = [ordered]@{}
            }
            $target = $target[$segments[$i]]
        }
        $target[$segments[-1]] = $value
    }
    if ($newContactPoint.Count -gt 0) {
        if ([string]::IsNullOrEmpty($actionContext.Configuration.ContactPointType)) {
            throw 'The configuration setting [ContactPointType] is empty. It is required to store the contact point fields'
        }
        $newContactPoint.Insert(0, 'contactPointType', "$($actionContext.Configuration.ContactPointType)")
        $operations.Add([PSCustomObject]@{ op = 'add'; path = '/contactPoints/-'; value = $newContactPoint })
    }
    Write-Output $operations
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

function Set-Unit4ERPxReadOnlyField {
    [CmdletBinding()]
    param (
        [object]
        $Data,

        [object]
        $Account,

        [string[]]
        $FieldNames
    )
    # Fields with mapping mode None are never sent to ERPx. Their values in ERPx are only returned to HelloID in the account data
    $accountData = ConvertTo-Unit4ERPxAccountObject -Account $Account -FieldNames $FieldNames
    foreach ($fieldName in $FieldNames) {
        $value = $accountData
        foreach ($segment in $fieldName.Split('.')) {
            $value = $value.$segment
        }

        $segments = $fieldName.Split('.')
        $target = $Data
        for ($i = 0; $i -lt ($segments.Count - 1); $i++) {
            if ($null -eq $target.($segments[$i])) {
                $target | Add-Member -NotePropertyName $segments[$i] -NotePropertyValue ([PSCustomObject]@{}) -Force
            }
            $target = $target.($segments[$i])
        }
        $target | Add-Member -NotePropertyName $segments[-1] -NotePropertyValue $value -Force
    }
}
#endregion

try {
    # Verify if [accountReference] has a value
    if ([string]::IsNullOrEmpty($($actionContext.References.Account))) {
        throw 'The account reference could not be found'
    }

    # Field mapping fields without the _extension object (not sent to ERPx and not stored in the account data)
    $mappedData = Get-Unit4ERPxFlatProperty -InputObject ($actionContext.Data | Select-Object -Property * -ExcludeProperty '_extension') -Prefix ''

    $mappedFieldNames = @($mappedData.Keys)

    # Fields with mapping mode None are not in actionContext.Data, HelloID only adds them (empty) to outputContext.Data.
    # They are not compared or sent, only returned from ERPx in the account data
    $readOnlyFieldNames = @((Get-Unit4ERPxFlatProperty -InputObject ($outputContext.Data | Select-Object -Property * -ExcludeProperty '_extension') -Prefix '').Keys | Where-Object { $_ -notin $mappedFieldNames })

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
        $outputContext.PreviousData = ConvertTo-Unit4ERPxAccountObject -Account $correlatedAccount -FieldNames ($mappedFieldNames + $readOnlyFieldNames)

        # Without a PATCH response (no changes or dry run) the read-only fields are returned from the current account
        $outputContext.Data = $actionContext.Data | Select-Object -Property * -ExcludeProperty '_extension'
        Set-Unit4ERPxReadOnlyField -Data $outputContext.Data -Account $correlatedAccount -FieldNames $readOnlyFieldNames

        # Always compare the account against the current account in target system.
        # Values are compared as text, so that null and '' are equal (for example an empty e-mail address). Compare-Object ignores case
        $currentData = Get-Unit4ERPxFlatProperty -InputObject $outputContext.PreviousData -Prefix ''
        $referenceProperties = foreach ($fieldName in $mappedFieldNames) {
            [PSCustomObject]@{ Name = $fieldName; Value = "$($currentData[$fieldName])" }
        }
        $differenceProperties = foreach ($fieldName in $mappedFieldNames) {
            [PSCustomObject]@{ Name = $fieldName; Value = "$($mappedData[$fieldName])" }
        }
        $splatCompareProperties = @{
            ReferenceObject  = @($referenceProperties)
            DifferenceObject = @($differenceProperties)
            Property         = @('Name', 'Value')
        }
        # A mapped field without a value is a change when ERPx has a value, so the value in ERPx is cleared
        $propertiesChanged = @(Compare-Object @splatCompareProperties -PassThru | Where-Object { $_.SideIndicator -eq '=>' })
        if ($propertiesChanged.Count -gt 0) {
            $lifecycleProcess = 'UpdateAccount'
        }
        else {
            $lifecycleProcess = 'NoChanges'
        }
    }
    else {
        $lifecycleProcess = 'NotFound'
    }

    # Process
    switch ($lifecycleProcess) {
        'UpdateAccount' {
            Write-Information "Account property(s) required to update: $($propertiesChanged.Name -join ', ')"

            $operations = ConvertTo-Unit4ERPxUpdateBody -MappedData $mappedData -ChangedFieldNames $propertiesChanged.Name -Account $correlatedAccount

            $splatUpdateParams = @{
                Uri         = "$($actionContext.Configuration.BaseUrl)/v1/users/$([System.Uri]::EscapeDataString($actionContext.References.Account))?companyId=$([System.Uri]::EscapeDataString($actionContext.Configuration.CompanyId))"
                Method      = 'PATCH'
                Headers     = $headers
                Body        = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject @($operations) -Depth 10))
                ContentType = 'application/json-patch+json; charset=utf-8'
            }

            if (-not($actionContext.DryRun -eq $true)) {
                Write-Information "Updating Unit4ERPx account with accountReference: [$($actionContext.References.Account)]"
                $updatedAccount = Invoke-RestMethod @splatUpdateParams -Verbose:$false
                if ($null -ne $updatedAccount -and -not [string]::IsNullOrEmpty($updatedAccount.userId)) {
                    $outputContext.Data = ConvertTo-Unit4ERPxAccountObject -Account $updatedAccount -FieldNames ($mappedFieldNames + $readOnlyFieldNames)
                }
            }
            else {
                Write-Information "[DryRun] Update Unit4ERPx account with accountReference: [$($actionContext.References.Account)], will be executed during enforcement"
            }

            $outputContext.Success = $true
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = "Update account was successful, Account property(s) updated: [$($propertiesChanged.Name -join ',')]"
                    IsError = $false
                })
            break
        }

        'NoChanges' {
            Write-Information "No changes to Unit4ERPx account with accountReference: [$($actionContext.References.Account)]"
            $outputContext.Success = $true
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = "Skipped updating Unit4ERPx account with AccountReference: [$($actionContext.References.Account)]. Reason: No changes."
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
    $outputContext.Success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-Unit4ERPxError -ErrorObject $ex
        $auditLogMessage = "Could not update Unit4ERPx account: [$($actionContext.References.Account)]. Error: $($errorObj.FriendlyMessage)"
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditLogMessage = "Could not update Unit4ERPx account: [$($actionContext.References.Account)]. Error: $($ex.Exception.Message)"
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Message = $auditLogMessage
            IsError = $true
        })
}
