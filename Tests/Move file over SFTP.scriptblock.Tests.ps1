#Requires -Modules Pester
#Requires -Version 7

<#
    .SYNOPSIS
        Test the scriptblock that executes a single action.

    .DESCRIPTION
        The Pester tests in 'Move file over SFTP.Tests.ps1' all run with
        'MaxConcurrent.ActionsTotal' set to 1, because a Pester mock is not
        visible in a parallel runspace. That leaves the parallel code path
        untested, while that is exactly the path where a scriptblock that
        reaches for a variable or a function of the parent scope breaks.

        The tests below read the scriptblock out of the script with the
        PowerShell parser and execute it with a real script file instead of a
        mock. Nothing is mocked, so the same tests run with a ThrottleLimit of
        1 and of 3 and have to give the same result.

        Only actions that run on the local computer are used, because the
        remote code path calls the real 'New-PSSession'.
#>

BeforeDiscovery {
    $testThrottleLimit = @(1, 3)
}
BeforeAll {
    $testScriptFile = Join-Path $PSScriptRoot '../Move file over SFTP.ps1'

    $testAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $testScriptFile, [ref]$null, [ref]$null
    )

    #region Get the scriptblock that executes one action
    $testAssignment = $testAst.FindAll(
        {
            ($args[0] -is [System.Management.Automation.Language.AssignmentStatementAst]) -and
            ($args[0].Left.Extent.Text -eq '$scriptBlock') -and
            ($args[0].Right.Expression -is [System.Management.Automation.Language.ScriptBlockExpressionAst])
        },
        $true
    )

    if ($testAssignment.Count -ne 1) {
        throw "Found $($testAssignment.Count) scriptblock assignments in '$testScriptFile'"
    }

    $testActionScriptBlock = $testAssignment[0].Right.Expression.ScriptBlock.GetScriptBlock()
    #endregion

    #region Get the function that runs the scriptblock
    $testFunction = $testAst.FindAll(
        {
            ($args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and
            ($args[0].Name -eq 'Invoke-WithOptionalParallelismHC')
        },
        $true
    )

    . ([scriptblock]::Create($testFunction[0].Extent.Text))
    #endregion

    #region Create the scripts that replace 'Move file.ps1'
    # the real file system path is used and not 'TestDrive:\', because a
    # parallel runspace does not have the TestDrive PSDrive
    $testStub = @{
        Success   = Join-Path $TestDrive 'stubSuccess.ps1'
        Transient = Join-Path $TestDrive 'stubTransient.ps1'
        Partial   = Join-Path $TestDrive 'stubPartial.ps1'
    }

    $testAttemptFile = Join-Path $TestDrive 'attempts.txt'

    @'
param (
    $SftpComputerName, $SftpCredential, $Paths, $MaxConcurrentPaths,
    $SftpPort, $MatchFileNameRegex, $SftpOpenSshKeyFile, $OverwriteFile,
    $ExcludeZeroSizeFile
)

[PSCustomObject]@{
    SftpComputerName    = $SftpComputerName
    Source              = $Paths[0].Source
    MaxConcurrentPaths  = $MaxConcurrentPaths
    SftpPort            = $SftpPort
    MatchFileNameRegex  = $MatchFileNameRegex
    OverwriteFile       = $OverwriteFile
    ExcludeZeroSizeFile = $ExcludeZeroSizeFile
}
'@ | Set-Content -LiteralPath $testStub.Success

    @"
param (
    `$SftpComputerName, `$SftpCredential, `$Paths, `$MaxConcurrentPaths,
    `$SftpPort, `$MatchFileNameRegex, `$SftpOpenSshKeyFile, `$OverwriteFile,
    `$ExcludeZeroSizeFile
)

`$attemptFile = '$testAttemptFile'

`$attempt = 1 + [int](Get-Content -LiteralPath `$attemptFile -Raw)
Set-Content -LiteralPath `$attemptFile -Value `$attempt

if (`$attempt -lt 3) {
    throw 'An item with the same key has already been added. Key: Alias'
}

[PSCustomObject]@{ FileName = 'a.txt' }
"@ | Set-Content -LiteralPath $testStub.Transient

    @'
param (
    $SftpComputerName, $SftpCredential, $Paths, $MaxConcurrentPaths,
    $SftpPort, $MatchFileNameRegex, $SftpOpenSshKeyFile, $OverwriteFile,
    $ExcludeZeroSizeFile
)

[PSCustomObject]@{ FileName = 'a.txt' }
[PSCustomObject]@{ FileName = 'b.txt' }

throw 'Failed to connect to the SFTP server'
'@ | Set-Content -LiteralPath $testStub.Partial
    #endregion

    function New-TestJobHC {
        param (
            [String]$ScriptPath,
            [String]$TaskName = 'App x',
            $EventLogData = ([System.Collections.Concurrent.ConcurrentBag[PSObject]]::new())
        )

        $testAction = [PSCustomObject]@{
            ComputerName = $ENV:COMPUTERNAME
            Job          = @{
                Results = @()
                Error   = $null
            }
        }

        [PSCustomObject]@{
            TaskName               = $TaskName
            ComputerName           = $ENV:COMPUTERNAME
            Action                 = $testAction
            RunOnLocalComputer     = $true
            PSSessionConfiguration = 'PowerShell.7'
            PSSessionOption        = $null
            ScriptPathMoveFile     = $ScriptPath
            SftpComputerName       = 'sftp.server.com'
            SftpCredential         = $null
            SftpPort               = 22
            SftpOpenSshKeyFile     = $null
            Paths                  = @(
                [PSCustomObject]@{
                    Source      = 'c:\a'
                    Destination = 'sftp:/a/'
                }
            )
            MaxConcurrentPaths     = 2
            MatchFileNameRegex     = '.*'
            OverwriteFile          = $true
            ExcludeZeroSizeFile    = $false
            EventLogData           = $EventLogData
            VerbosePreference      = 'SilentlyContinue'
            Retry                  = @{
                AttemptCount               = 3
                WaitSecondsBetweenAttempts = 0
                TransientErrorRegex        = @(
                    'An item with the same key has already been added'
                )
            }
        }
    }
}
Describe 'with ThrottleLimit <_> an action' -ForEach $testThrottleLimit {
    BeforeAll {
        $testThrottle = $_
    }
    It 'is executed and its results are stored on the action' {
        $testJobs = 1..3 | ForEach-Object {
            New-TestJobHC -ScriptPath $testStub.Success
        }

        Invoke-WithOptionalParallelismHC -InputObject $testJobs -ScriptBlock $testActionScriptBlock -ThrottleLimit $testThrottle

        # member enumeration returns an array with one entry per action, so
        # the entries that are $null have to be filtered out first
        $testJobs.Action.Job.Error.Where({ $_ }).Count | Should -Be 0

        $testJobs.Action.Job.Results | Should -HaveCount 3
    }
    It 'receives every value of the job object' {
        # a property that is missing from the job object is not visible when
        # the code runs in sequence, but breaks in a parallel runspace
        $testJobs = @(New-TestJobHC -ScriptPath $testStub.Success)

        Invoke-WithOptionalParallelismHC -InputObject $testJobs -ScriptBlock $testActionScriptBlock -ThrottleLimit $testThrottle

        $testResult = $testJobs[0].Action.Job.Results[0]

        $testResult.SftpComputerName | Should -Be 'sftp.server.com'
        $testResult.Source | Should -Be 'c:\a'
        $testResult.MaxConcurrentPaths | Should -Be 2
        $testResult.SftpPort | Should -Be 22
        $testResult.MatchFileNameRegex | Should -Be '.*'
        $testResult.OverwriteFile | Should -BeTrue
        $testResult.ExcludeZeroSizeFile | Should -BeFalse
    }
    It 'writes to the shared event log collection' {
        $testEventLogData = [System.Collections.Concurrent.ConcurrentBag[PSObject]]::new()

        $testJobs = 1..3 | ForEach-Object {
            New-TestJobHC -ScriptPath $testStub.Success -EventLogData $testEventLogData
        }

        Invoke-WithOptionalParallelismHC -InputObject $testJobs -ScriptBlock $testActionScriptBlock -ThrottleLimit $testThrottle

        # one entry when the action starts and one when it is done
        $testEventLogData | Should -HaveCount 6
    }
    It 'is retried when the error is transient' {
        Set-Content -LiteralPath $testAttemptFile -Value 0

        $testJobs = @(New-TestJobHC -ScriptPath $testStub.Transient)

        Invoke-WithOptionalParallelismHC -InputObject $testJobs -ScriptBlock $testActionScriptBlock -ThrottleLimit $testThrottle -WarningAction 'SilentlyContinue'

        (Get-Content -LiteralPath $testAttemptFile -Raw).Trim() |
        Should -Be '3'

        $testJobs[0].Action.Job.Error | Should -BeNullOrEmpty
        $testJobs[0].Action.Job.Results | Should -HaveCount 1
    }
    It 'keeps the results that came in before the error' {
        $testJobs = @(New-TestJobHC -ScriptPath $testStub.Partial)

        Invoke-WithOptionalParallelismHC -InputObject $testJobs -ScriptBlock $testActionScriptBlock -ThrottleLimit $testThrottle -WarningAction 'SilentlyContinue'

        $testJobs[0].Action.Job.Error |
        Should -BeLike '*Failed to connect to the SFTP server*'

        $testJobs[0].Action.Job.Results.FileName |
        Should -Be @('a.txt', 'b.txt')
    }
    It 'stores the error on its own action only' {
        $testJobs = @(
            New-TestJobHC -ScriptPath $testStub.Partial
            New-TestJobHC -ScriptPath $testStub.Success
        )

        Invoke-WithOptionalParallelismHC -InputObject $testJobs -ScriptBlock $testActionScriptBlock -ThrottleLimit $testThrottle -WarningAction 'SilentlyContinue'

        $testJobs[0].Action.Job.Error | Should -Not -BeNullOrEmpty
        $testJobs[1].Action.Job.Error | Should -BeNullOrEmpty
    }
}
