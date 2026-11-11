#################################################
# HelloID-Conn-Prov-Target-Unit4ERPx-Create
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

function ConvertTo-Unit4ERPxCreateBody {
    [CmdletBinding()]
    param (
        [System.Collections.Specialized.OrderedDictionary]
        $MappedData
    )
    $today = (Get-Date).ToString("yyyy-MM-dd'T'00:00:00.000", [System.Globalization.CultureInfo]::InvariantCulture)
    $endDate = '2099-12-31T00:00:00.000'
    $contactPointPaths = @{
        'contactPoints.eMail'       = 'additionalContactInfo.eMail'
        'contactPoints.countryCode' = 'address.countryCode'
    }

    # Build the request body 1:1 from the field mapping. The contactPoints.* fields are combined into one contact point
    $body = [ordered]@{}
    $contactPoint = [ordered]@{}
    foreach ($fieldName in $MappedData.Keys) {
        $value = $MappedData[$fieldName]
        # An empty date or contact point field is not sent
        if ($fieldName -in @('security.disabledUntil', 'security.passwordExpiryDate') -and [string]::IsNullOrEmpty("$value")) {
            continue
        }
        $target = $body
        $path = $fieldName
        if ($fieldName.StartsWith('contactPoints.')) {
            if (-not $contactPointPaths.ContainsKey($fieldName)) {
                throw "Field mapping [$fieldName] is not supported. Supported contact point fields: [$($contactPointPaths.Keys -join ', ')]"
            }
            if ([string]::IsNullOrEmpty("$value")) {
                continue
            }
            $target = $contactPoint
            $path = $contactPointPaths[$fieldName]
        }

        $segments = $path.Split('.')
        for ($i = 0; $i -lt ($segments.Count - 1); $i++) {
            if (-not $target.Contains($segments[$i])) {
                $target[$segments[$i]] = [ordered]@{}
            }
            $target = $target[$segments[$i]]
        }
        $target[$segments[-1]] = ConvertTo-Unit4ERPxApiValue -FieldName $fieldName -Value $value
    }
    if ($contactPoint.Count -gt 0) {
        if (-not [string]::IsNullOrEmpty($actionContext.Configuration.ContactPointType)) {
            $contactPoint.Insert(0, 'contactPointType', "$($actionContext.Configuration.ContactPointType)")
        }
        $body['contactPoints'] = @($contactPoint)
    }

    # Accounts are created inactive: status P (parked). Enable sets status N
    $body['userStatus'] = [ordered]@{
        status   = 'P'
        dateFrom = $today
        dateTo   = $endDate
    }

    if ($actionContext.Configuration.AddDefaultRoleAndCompanyOnCreate -eq $true) {
        $defaultEntry = [ordered]@{
            companyId               = "$($actionContext.Configuration.CompanyId)"
            roleConnectionValidFrom = $today
            roleConnectionValidTo   = $endDate
            roleConnectionStatus    = 'N'
        }
        if (-not [string]::IsNullOrEmpty($actionContext.Data._extension.personId)) {
            $defaultEntry['personId'] = "$($actionContext.Data._extension.personId)"
        }
        if (-not [string]::IsNullOrEmpty($actionContext.Configuration.DefaultRoleId)) {
            $defaultEntry['roleId'] = "$($actionContext.Configuration.DefaultRoleId)"
        }
        $body['roleAndCompany'] = @($defaultEntry)
        $body['defaultLogonCompany'] = "$($actionContext.Configuration.CompanyId)"
    }
    Write-Output $body
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
    # Initial Assignments
    $outputContext.AccountReference = 'Currently not available'

    # Field mapping fields without the _extension object (not sent to ERPx and not stored in the account data)
    $mappedData = Get-Unit4ERPxFlatProperty -InputObject ($actionContext.Data | Select-Object -Property * -ExcludeProperty '_extension') -Prefix ''

    $mappedFieldNames = @($mappedData.Keys)

    # Fields with mapping mode None are not in actionContext.Data, HelloID only adds them (empty) to outputContext.Data.
    # They are not sent, only returned from ERPx in the account data
    $readOnlyFieldNames = @((Get-Unit4ERPxFlatProperty -InputObject ($outputContext.Data | Select-Object -Property * -ExcludeProperty '_extension') -Prefix '').Keys | Where-Object { $_ -notin $mappedFieldNames })

    if ([string]::IsNullOrEmpty($actionContext.Data.userId)) {
        throw 'The field [userId] is empty. Please make sure it is correctly mapped'
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

    # Validate correlation configuration
    $correlatedAccount = $null
    if ($actionContext.CorrelationConfiguration.Enabled) {
        $correlationField = $actionContext.CorrelationConfiguration.AccountField
        $correlationValue = $actionContext.CorrelationConfiguration.PersonFieldValue

        if ([string]::IsNullOrEmpty($($correlationField))) {
            throw 'Correlation is enabled but not configured correctly'
        }
        if ($correlationField -ne 'userId') {
            throw "Correlation on account field [$correlationField] is not supported. Only [userId] is supported"
        }
        if ([string]::IsNullOrEmpty($($correlationValue))) {
            throw 'Correlation is enabled but [accountFieldValue] is empty. Please make sure it is correctly mapped'
        }
        if ("$correlationValue" -ne "$($actionContext.Data.userId)") {
            throw "The correlation value [$correlationValue] is not equal to the mapped userId [$($actionContext.Data.userId)]. The person correlation field and the userId field mapping must use the same source"
        }

        # Determine if a user needs to be [created] or [correlated]
        Write-Information "Verifying if a Unit4ERPx account exists where $correlationField is: [$correlationValue]"
        $splatGetUserParams = @{
            Uri     = "$($actionContext.Configuration.BaseUrl)/v1/users/$([System.Uri]::EscapeDataString($correlationValue))?companyId=$([System.Uri]::EscapeDataString($actionContext.Configuration.CompanyId))"
            Method  = 'GET'
            Headers = $headers
        }
        try {
            $correlatedAccount = Invoke-RestMethod @splatGetUserParams -Verbose:$false
        }
        catch {
            # HTTP 404 means the account does not exist
            if ([int]$_.Exception.Response.StatusCode -ne 404) {
                throw
            }
        }
    }

    $correlatedAccounts = @($correlatedAccount | Where-Object { $null -ne $_ })
    if ($correlatedAccounts.Count -eq 0) {
        $lifecycleProcess = 'CreateAccount'
    }
    elseif ($correlatedAccounts.Count -eq 1) {
        $lifecycleProcess = 'CorrelateAccount'
    }
    else {
        throw "Multiple accounts found for person where $correlationField is: [$correlationValue]"
    }

    # Process
    switch ($lifecycleProcess) {
        'CreateAccount' {
            $body = ConvertTo-Unit4ERPxCreateBody -MappedData $mappedData
            $splatCreateParams = @{
                Uri         = "$($actionContext.Configuration.BaseUrl)/v1/users"
                Method      = 'POST'
                Headers     = $headers
                Body        = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $body -Depth 10))
                ContentType = 'application/json; charset=utf-8'
            }

            $createdAccount = $null
            if (-not($actionContext.DryRun -eq $true)) {
                Write-Information 'Creating and correlating Unit4ERPx account'
                $createdAccount = Invoke-RestMethod @splatCreateParams -Verbose:$false
            }
            else {
                Write-Information '[DryRun] Create and correlate Unit4ERPx account, will be executed during enforcement'
            }
            $outputContext.Data = $actionContext.Data | Select-Object -Property * -ExcludeProperty '_extension'
            Set-Unit4ERPxReadOnlyField -Data $outputContext.Data -Account $createdAccount -FieldNames $readOnlyFieldNames
            $outputContext.AccountReference = "$($actionContext.Data.userId)"
            $auditLogMessage = "Create account was successful. AccountReference is: [$($outputContext.AccountReference)]"
            break
        }

        'CorrelateAccount' {
            Write-Information 'Correlating Unit4ERPx account'
            $outputContext.Data = ConvertTo-Unit4ERPxAccountObject -Account $correlatedAccounts[0] -FieldNames ($mappedFieldNames + $readOnlyFieldNames)
            $outputContext.AccountReference = "$($correlatedAccounts[0].userId)"
            $outputContext.AccountCorrelated = $true
            $auditLogMessage = "Correlated account: [$($outputContext.AccountReference)] on field: [$($correlationField)] with value: [$($correlationValue)]"
            break
        }
    }

    $outputContext.success = $true
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Action  = $lifecycleProcess
            Message = $auditLogMessage
            IsError = $false
        })
}
catch {
    $outputContext.success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-Unit4ERPxError -ErrorObject $ex
        $auditLogMessage = "Could not create or correlate Unit4ERPx account: [$($actionContext.Data.userId)]. Error: $($errorObj.FriendlyMessage)"
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditLogMessage = "Could not create or correlate Unit4ERPx account: [$($actionContext.Data.userId)]. Error: $($ex.Exception.Message)"
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Message = $auditLogMessage
            IsError = $true
        })
}
