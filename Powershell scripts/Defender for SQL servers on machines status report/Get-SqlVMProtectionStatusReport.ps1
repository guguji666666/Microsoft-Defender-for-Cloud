﻿<#
.SYNOPSIS
    Retrieves registry values from all underlying VMs of your SQL Virtual Machines (in the scope of the current subscription)
    for every SQL instance (under HKLM:\SOFTWARE\Microsoft\AzureDefender\SQL\) and exports the results to an Excel file.

.DESCRIPTION
    For each SQL VM (as returned by Get-AzSqlVM), this script:
      - Determines its underlying Virtual Machine.
      - Invokes a run command (with -AsJob) on that VM. The remote script:
           • Enumerates all instance names (subkeys) under HKLM:\SOFTWARE\Microsoft\AzureDefender\SQL\
           • Retrieves the registry values "SqlQueryProtection_Status" and "SqlQueryProtection_Timestamp"
           • Converts the .NET ticks timestamp into an ISO 8601 date/time
           • Outputs a JSON array of objects (one per SQL instance)
      - The local script waits for all jobs to complete, parses each job’s JSON output (using the Message property).
      - Finally, the results are exported to an Excel file.

.NOTES
    - Requires the Az modules (Az.Accounts, Az.Compute, Az.SqlVirtualMachine) and the ImportExcel module.
    - Ensure you are connected to your Azure account (Connect-AzAccount).
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$SubscriptionIdOrName
)

# ----------------------
# Connect to Azure if not already connected and set the subscription context
# ----------------------
if (-not $SubscriptionIdOrName -or [string]::IsNullOrWhiteSpace($SubscriptionIdOrName)) {
    Write-Error "A valid subscription id or name must be provided."
    exit
}
if (-not (Get-AzContext)) { Connect-AzAccount }

$subscription = Get-AzSubscription | Where-Object { $_.Id -eq $SubscriptionIdOrName -or $_.Name -eq $SubscriptionIdOrName }

if (-not $subscription) {
    Write-Error "Subscription not found. Exiting."
    exit
}

Write-Output "Processing subscription: $($subscription.Name) ($($subscription.Id))"
Set-AzContext -SubscriptionId $subscription.Id | Out-Null

# Import Excel for the output
Import-Module ImportExcel -ErrorAction Stop

# ----------------------
# 1. Define Remote Script
# ----------------------
$remoteScript = @'
$baseRegPath = "HKLM:\SOFTWARE\Microsoft\AzureDefender\SQL"
$results = @()

# Enumerate each subkey (instance) under the SQL key
try {
    $instances = Get-ChildItem -Path $baseRegPath -ErrorAction SilentlyContinue
    foreach ($instance in $instances) {
        $instanceName = $instance.PSChildName
        try {
            # Attempt to retrieve the registry values for this instance.
            $regValues = Get-ItemProperty -Path $instance.PSPath -Name "SqlQueryProtection_Status", "SqlQueryProtection_Timestamp" -ErrorAction Stop

            # Convert the .NET ticks (100-nanosecond intervals since 0001-01-01) into an ISO 8601 timestamp.
            $ticks = $regValues.SqlQueryProtection_Timestamp
            $baseDate = [datetime]"0001-01-01T00:00:00Z"
            $dt = $baseDate.AddTicks($ticks)
            $iso = $dt.ToString("o")

            # Build the output object for this instance.
            $obj = [PSCustomObject]@{
                InstanceName     = $instanceName
                ProtectionStatus = $regValues.SqlQueryProtection_Status
                LastUpdate       = $iso
            }
            $results += $obj
        }
        catch {
            Write-Error "Failed to retrieve registry values for instance '$instanceName'. Error: $_"
        }
    }
}
catch {
    Write-Error "Failed to enumerate SQL registry keys under $baseRegPath. Error: $_"
}

# Output the collected objects as JSON.
$results | ConvertTo-Json -Depth 4
'@

# ----------------------
# 2. Loop Through SQL VMs and Start Jobs
# ----------------------
$jobs = @()
$finalResults = @()

# Retrieve SQL Virtual Machines in this subscription.
$sqlVms = Get-AzSqlVM
if (-not $sqlVms) {
    Write-Output "No SQL VMs found in subscription $($subscription.Name). Exiting."
    exit
}

foreach ($sqlVm in $sqlVms) {
    # Get the underlying Virtual Machine's resource id.
    $underlyingVmResourceId = $sqlVm.VirtualMachineId #VirtualMachineResourceId
    if (-not $underlyingVmResourceId) {
        Write-Warning "SQL VM '$($sqlVm.Name)' does not have an underlying Virtual Machine resource id. Skipping."
        continue
    }

    # Parse the resource id to extract the resource group and VM name.
    # Expected format: /subscriptions/{subId}/resourceGroups/{rgName}/providers/Microsoft.Compute/virtualMachines/{vmName}
    $parts = $underlyingVmResourceId -split '/'
    if ($parts.Count -lt 9) {
        Write-Warning "Unexpected resource id format for SQL VM '$($sqlVm.Name)'. Skipping."
        continue
    }
    $vmResourceGroup = $parts[4]
    $vmName = $parts[8]

    # Invoke the run command on the underlying VM as a job.
    $job = Invoke-AzVMRunCommand -ResourceGroupName $vmResourceGroup `
                                 -Name $vmName `
                                 -CommandId 'RunPowerShellScript' `
                                 -ScriptString $remoteScript `
                                 -AsJob

    # Attach extra metadata to the job for later aggregation.
    $job | Add-Member -MemberType NoteProperty -Name "SqlVmName" -Value $sqlVm.Name -Force
    $job | Add-Member -MemberType NoteProperty -Name "SQLVMResourceId" -Value $sqlVm.ResourceId -Force

    $jobs += $job
}

if ($jobs.Count -eq 0) {
    Write-Output "No run command jobs were started. Exiting."
    return
}

Write-Output "Waiting for all run command jobs to complete..."
Wait-Job -Job $jobs

# ----------------------
# 3. Process Job Outputs and Aggregate Results
# ----------------------
# Process each job’s output.
foreach ($job in $jobs) {
    try {
        $jobOutput = Receive-Job -Job $job

        $jsonOutput = $jobOutput.Value[0].Message

        try {
            $parsed = $jsonOutput | ConvertFrom-Json
        }
        catch {
            Write-Warning "Failed to parse JSON output for SQL VM '$($job.SqlVmName)'. Raw output: $jsonOutput"
            continue
        }

        # Ensure the parsed output is an array.
        if ($parsed -isnot [System.Collections.IEnumerable]) {
            $parsed = @($parsed)
        }

        foreach ($item in $parsed) {
            $obj = [PSCustomObject]@{
                "SQL VM Name"        = $job.SqlVmName
                "Instance Name"      = $item.InstanceName
                "Protection Status"  = $item.ProtectionStatus
                "Last Update"        = $item.LastUpdate.ToString("o")
                "SQL VM Resource ID" = $job.SQLVMResourceId
            }
            $finalResults += $obj
        }
    }
    catch {
        Write-Warning "An error occurred processing job for SQL VM '$($job.SqlVmName)'. Error: $_"
    }
}

# ----------------------
# 4. Export Results to Excel with Subscription ID in the filename and versioning if needed
# ----------------------
$baseName = "SqlVmProtectionResults_$($subscription.Id)"
$excelFile = "$baseName.xlsx"
$version = 1

while (Test-Path $excelFile) {
    $excelFile = "${baseName}($version).xlsx"
    $version++
}

$finalResults | Export-Excel -Path $excelFile -AutoSize -WorksheetName "SQLVMs"

Write-Output "Export complete. Results saved to $excelFile."
