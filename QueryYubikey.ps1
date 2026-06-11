<#
.SYNOPSIS
    Lookup and optionally unassign a YubiKey from a user in GreenRADIUS.

.DESCRIPTION
    This script can look up a YubiKey assignment using either:

        1. A full YubiKey OTP / YubiKey press / 12-character public ID
        2. The decimal serial number printed on the back of the YubiKey

    Option 1 preserves the original working behavior:
        - Accept OTP or public ID
        - Trim to first 12 characters
        - Search GreenRADIUS directly

    Option 2 converts:
        Decimal Serial -> Hexadecimal -> ModHex

.NOTES
    Author: Jarett LeBlang but mostly just ChatGPT
    Requires: GreenRADIUS Management API access
#>

# GreenRADIUS server hostname
$serverHOST = '<GreenRADIUS server FQDN or IP>'

Write-Output "Choose lookup method:"
Write-Output "1. YubiKey press / full OTP / first 12-character public ID"
Write-Output "2. Decimal serial number from back of YubiKey"
Write-Output ""

$lookupMode = Read-Host "Enter 1 or 2"

$keyToFind = $null

if ($lookupMode -eq '1') {

    # Original working YubiKey OTP / public ID behavior
    $keyToFind = Read-Host "Enter YubiKey OTP or first 12-character public ID"
    $keyToFind = $keyToFind.Trim()

    if ($keyToFind.Length -gt 12) {
        $keyToFind = $keyToFind.Substring(0, 12)
    }

    Write-Output ("Searching token/public ID: {0}" -f $keyToFind)
}
elseif ($lookupMode -eq '2') {

    $serialNumber = Read-Host "Enter decimal serial number from back of YubiKey"
    $serialNumber = $serialNumber.Trim()

    if ($serialNumber -notmatch '^\d+$') {
        Write-Output "Invalid serial number. Decimal serial numbers should contain digits only."
        return
    }

    $decimalSerial = [UInt64]$serialNumber
    $hexSerial = '{0:x}' -f $decimalSerial

    $modhexMap = @{
        '0' = 'c'
        '1' = 'b'
        '2' = 'd'
        '3' = 'e'
        '4' = 'f'
        '5' = 'g'
        '6' = 'h'
        '7' = 'i'
        '8' = 'j'
        '9' = 'k'
        'a' = 'l'
        'b' = 'n'
        'c' = 'r'
        'd' = 't'
        'e' = 'u'
        'f' = 'v'
    }

    $modhexSerial = -join ($hexSerial.ToCharArray() | ForEach-Object {
            $modhexMap[[string]$_]
        })

    $keyToFind = $modhexSerial.PadLeft(12, 'c')

    Write-Output ("Decimal Serial : {0}" -f $decimalSerial)
    Write-Output ("Hex Serial     : {0}" -f $hexSerial)
    Write-Output ("ModHex Serial  : {0}" -f $modhexSerial)
    Write-Output ("Searching token/public ID: {0}" -f $keyToFind)
}
else {
    Write-Output "Invalid selection. Exiting."
    return
}

# GreenRADIUS API endpoint used to lookup token assignments
$uri = 'https://{0}/gras-api/v2/mgmt/tokenassignment' -f $serverHOST

# Build API authentication headers
$headers = @{
    'Authorization' = 'Basic ' + [Convert]::ToBase64String(
        [Text.Encoding]::ASCII.GetBytes('<APIUser:APIPassword>')
    )
    'Content-Type'  = 'application/json'
}

# API expects token IDs as an array
$jsonBody = @{
    token_id = @($keyToFind)
} | ConvertTo-Json -Depth 10

try {

    # Query GreenRADIUS for token assignment information
    $response = Invoke-RestMethod `
        -SkipCertificateCheck `
        -Uri $uri `
        -Method Get `
        -Headers $headers `
        -Body $jsonBody `
        -ErrorAction Stop

    $records = $response.records_with_mappings.records

    if (-not $records) {
        Write-Output "No user mapping found for token/key: $keyToFind"
        return
    }

    Write-Output ""
    Write-Output "Token/key found:"
    Write-Output "================"

    # Store mapped users for potential deletion later
    $mappedUsers = @()

    # Each token is returned as a property under the records object
    foreach ($tokenProperty in $records.PSObject.Properties) {

        $tokenId = $tokenProperty.Name
        $token = $tokenProperty.Value

        Write-Output ("Token ID: {0}" -f $tokenId)
        Write-Output ("Token Type: {0}" -f $token.token_type)

        # Enumerate assigned users
        foreach ($userProperty in $token.user_mappings.PSObject.Properties) {

            $userData = $userProperty.Value

            Write-Output ("User: {0}" -f $userData.user)
            Write-Output ("Status: {0}" -f $userData.status)
            Write-Output ("Directory State: {0}" -f $userData.state_in_directory_server)

            # Convert Unix timestamp to local date/time
            if ($userData.assigned_on) {
                $assignedDate = [DateTimeOffset]::FromUnixTimeSeconds(
                    [int64]$userData.assigned_on
                ).LocalDateTime

                Write-Output ("Assigned On: {0}" -f $assignedDate)
            }

            Write-Output ""

            # Save user for optional unassignment
            if ($userData.user) {
                $mappedUsers += $userData.user
            }
        }
    }

    if (-not $mappedUsers) {
        Write-Output "Token was found, but no mapped users were returned."
        return
    }

    # Safety confirmation before deleting assignments
    # First confirmation - require explicit DELETE
    $deleteConfirm = Read-Host `
        "Type DELETE to unassign this YubiKey from the mapped user(s)"

    if ($deleteConfirm -ceq 'DELETE') {

        Write-Output ""
        Write-Output "WARNING: This will remove the YubiKey assignment(s) listed above."
        Write-Output ""

        # Second confirmation
        $finalConfirm = Read-Host "Are you absolutely sure? (Y/N)"

        if ($finalConfirm -notmatch '^(Y|y)$') {
            Write-Output "Delete cancelled."
            return
        }

        # Continue with deletion...

        # GreenRADIUS API endpoint for removing assignments
        $deleteUri = 'https://{0}/gras-api/v2/mgmt/mappings' -f $serverHOST

        $deleteUsers = @()

        foreach ($mappedUser in $mappedUsers) {
            $deleteUsers += @{
                username = $mappedUser
                token_id = @($keyToFind)
            }
        }

        $deleteBody = @{
            users = $deleteUsers
        } | ConvertTo-Json -Depth 10

        try {

            # Remove token assignment(s)
            $null = Invoke-RestMethod `
                -SkipCertificateCheck `
                -Uri $deleteUri `
                -Method Delete `
                -Headers $headers `
                -Body $deleteBody `
                -ErrorAction Stop

            # Audit logging
            foreach ($mappedUser in $mappedUsers) {

                $logLine = "{0} | Token: {1} | User: {2} | Removed By: {3}" -f `
                (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), `
                    $keyToFind, `
                    $mappedUser, `
                    $env:USERNAME

                Add-Content `
                    -Path "C:\Logs\YubiKeyRemovals.log" `
                    -Value $logLine
            }

            Write-Output ""
            Write-Output "YubiKey successfully deleted/unassigned from:"

            foreach ($mappedUser in $mappedUsers) {
                Write-Output ("- {0}" -f $mappedUser)
            }
        }
        catch {
            Write-Error "Delete failed: $($_.Exception.Message)"

            if ($_.Exception.InnerException) {
                Write-Error "Inner Exception: $($_.Exception.InnerException.Message)"
            }
        }
    }
    else {
        Write-Output "DELETE was not entered. Operation cancelled."
    }
}
catch {
    Write-Error "Error: $($_.Exception.Message)"

    if ($_.Exception.InnerException) {
        Write-Error "Inner Exception: $($_.Exception.InnerException.Message)"
    }
}
