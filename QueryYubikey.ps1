<#
.SYNOPSIS
    Lookup and optionally unassign a YubiKey from a user in GreenRADIUS.

.DESCRIPTION
    This script accepts either a full YubiKey OTP or a 12-character
    YubiKey public ID, searches GreenRADIUS for the assigned user,
    displays assignment details, and optionally removes the token
    assignment after confirmation.

.NOTES
    Author: Jarett LeBlang
    Requires: GreenRADIUS Management API access
#>

# GreenRADIUS server hostname
$serverHOST = '<server>'

# Prompt for a YubiKey OTP or Public ID
$keyToFind = Read-Host "Enter YubiKey OTP or first 12-character public ID"
$keyToFind = $keyToFind.Trim()

# If a full OTP was provided, extract the first 12 characters
# which represent the YubiKey public ID used by GreenRADIUS.
if ($keyToFind.Length -gt 12) {
    $keyToFind = $keyToFind.Substring(0, 12)
}

Write-Output ("Searching token/public ID: {0}" -f $keyToFind)

# GreenRADIUS API endpoint used to lookup token assignments
$uri = 'https://{0}/gras-api/v2/mgmt/tokenassignment' -f $serverHOST

# Build API authentication headers
$headers = @{
    'Authorization' = 'Basic ' + [Convert]::ToBase64String(
        [Text.Encoding]::ASCII.GetBytes('<apiuser:apipassword>')
    )
    'Content-Type' = 'application/json'
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
        $token   = $tokenProperty.Value

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
    $deleteConfirm = Read-Host `
        "Type Yes to delete/unassign this YubiKey from the mapped user(s)"

    if ($deleteConfirm -eq 'Yes') {

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
        Write-Output "Delete skipped."
    }
}
catch {
    Write-Error "Error: $($_.Exception.Message)"

    if ($_.Exception.InnerException) {
        Write-Error "Inner Exception: $($_.Exception.InnerException.Message)"
    }
}
