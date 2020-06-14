<#
The MIT License (MIT)
Copyright (c) Microsoft Corporation  
Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.  
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE. 
.SYNOPSIS
This script is part of the scripts chain for joining a student VM to an Active Directory domain. It retrieves the info of the student assigned to this Lab VM. Then it adds the student domain account to the local RDP group. 
.LINK https://docs.microsoft.com/en-us/azure/lab-services/classroom-labs/how-to-connect-peer-virtual-network
.PARAMETER LabAccountResourceGroupName
Resource group name of Lab Account.
.PARAMETER LabAccountName
Name of Lab Account.
.PARAMETER LabName
Name of Lab.
.PARAMETER DomainServiceAddress
One or more AD Domain Services Server addresses.
.PARAMETER Domain
Domain Name (e.g. contoso.com).
.PARAMETER LocalUser
Local User created when setting up the Lab.
.PARAMETER DomainUser
Domain User (e.g. CONTOSO\frbona or frbona@contoso.com). It must have permissions to add computers to the domain.
.PARAMETER LocalPassword
Password of the Local User.
.PARAMETER DomainPassword
Password of the Domain User.
.NOTES
.EXAMPLE
. ".\Join-AzLabADStudent_AddStudent.ps1" `
    -LabAccountResourceGroupName 'labaccount-rg' `
    -LabAccountName 'labaccount' `
    -LabName 'Mobile App Development' `
    -DomainServiceAddress '10.0.23.5','10.0.23.6' `
    -Domain 'contoso.com' `
    -LocalUser 'localUser' `
    -DomainUser 'domainUser' `
    -LocalPassword 'localPassword' `
    -DomainPassword 'domainPassword'
#>

[CmdletBinding()]
param(
    [parameter(Mandatory = $true, HelpMessage = "Resource group name of Lab Account.", ValueFromPipeline = $true)]
    [ValidateNotNullOrEmpty()]
    $LabAccountResourceGroupName,

    [parameter(Mandatory = $true, HelpMessage = "Name of Lab Account.", ValueFromPipeline = $true)]
    [ValidateNotNullOrEmpty()]
    $LabAccountName,
  
    [parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true, HelpMessage = "Name of Lab.")]
    [ValidateNotNullOrEmpty()]
    $LabName,

    [parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true, HelpMessage = "One or more AD Domain Services Server addresses.")]
    [ValidateNotNullOrEmpty()]
    [string[]] $DomainServiceAddress,

    [parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true, HelpMessage = "Domain Name (e.g. contoso.com).")]
    [ValidateNotNullOrEmpty()]
    [string] $Domain,

    [parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true, HelpMessage = "Local User created when setting up the Lab.")]
    [ValidateNotNullOrEmpty()]
    [string] $LocalUser,

    [parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true, HelpMessage = "Domain User (e.g. CONTOSO\frbona or frbona@contoso.com). It must have permissions to add computers to the domain.")]
    [ValidateNotNullOrEmpty()]
    [string] $DomainUser,

    [parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true, HelpMessage = "Password of the Local User.")]
    [ValidateNotNullOrEmpty()]
    [string] $LocalPassword,

    [parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true, HelpMessage = "Password of the Domain User.")]
    [ValidateNotNullOrEmpty()]
    [string] $DomainPassword,

    [parameter(Mandatory = $false, ValueFromPipelineByPropertyName = $true, HelpMessage = "Name of the task this script is run from (optional).")]
    [string]
    $CurrentTaskName
)

###################################################################################################

# Default exit code
$ExitCode = 0

try {

    $ErrorActionPreference = "Stop"

    . ".\Utils.ps1"

    Write-LogFile "Importing AzLab Module"
    Import-AzLabModule

    Write-LogFile "Getting information on the currently running Student VM"
    $labAccount = Get-AzLabAccount -ResourceGroupName $LabAccountResourceGroupName -LabAccountName $LabAccountName
    $lab = $labAccount | Get-AzLab -LabName $LabName
    $studentVm = $lab | Get-AzLabCurrentStudentVmFromLab

    if ($studentVm.properties.isClaimed) {

        # Get the student who claimed this VM
        $student = $lab | Get-AzLabUserForCurrentVm -Vm $studentVm
        Write-LogFile "VM '$env:COMPUTERNAME' has been claimed by student '$($student.properties.email)'"
    
        Write-LogFile "Trying to add student '$($student.properties.email)' to the Remote Desktop Users group"
        
        $computerDomain = (Get-WmiObject Win32_ComputerSystem).Domain
        $username = $student.properties.email.Split("@")[0]
        $domainUser = "$computerDomain\$username"

        $rdpGroupMembers = Get-LocalGroupMember "Remote Desktop Users"
        foreach ($rdpMember in $rdpGroupMembers) {
            
            if ($rdpMember.Name.Split("\")[1] -ieq $username) {
               
                # Domain user already in the RDP group
                Write-LogFile "Domain User '$domainUser' has already been added to the RDP group"
                exit
            }
        }

        Add-LocalGroupMember -Group "Remote Desktop Users" -Member $domainUser

        # Remove Azure credentials
        Clear-AzContext -Scope CurrentUser -Confirm:$false -Force

        # TODO Should be Optional
        # Schedule MDM Intune enrollment task

        $MDMTaskName = "Schedule created by enrollment client for automatically enrolling in MDM from AAD"
        $MDMScriptPath = Join-Path (Resolve-Path .\).Path $JoinAzLabADStudentIntuneEnrollmentScriptName

        $repeat = New-TimeSpan -Minutes 5
        $duration = New-TimeSpan -Days 1
        $timeTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval $repeat -RepetitionDuration $duration

        $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RunOnlyIfNetworkAvailable -DontStopOnIdleEnd

        Register-ScheduledScriptTask `
                -TaskName $MDMTaskName `
                -ScriptPath $MDMScriptPath `
                -TimeTrigger $timeTrigger `
                -Settings $taskSettings `
                -AsSystem
    }
    else { # VM not claimed
        Write-LogFile "VM '$env:COMPUTERNAME' has not been claimed yet. Waiting for a student to be added..."
    }
} 

catch
{
    $message = $Error[0].Exception.Message
    if ($message) {
        Write-LogFile "`nERROR: $message"
    }

    Write-LogFile "`nThe script failed to run.`n"

    # Important note: Throwing a terminating error (using $ErrorActionPreference = "stop") still returns exit 
    # code zero from the powershell script. The workaround is to use try/catch blocks and return a non-zero 
    # exit code from the catch block. 
    $ExitCode = -1
}

finally {

    Write-LogFile "Exiting with $ExitCode" 
    exit $ExitCode
}