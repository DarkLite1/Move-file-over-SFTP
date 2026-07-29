#Requires -Modules Pester
#Requires -Version 7

<#
    .SYNOPSIS
        Test the function 'Invoke-WithOptionalParallelismHC'.

    .DESCRIPTION
        The function is not stored in a module, it is defined in both
        'Move file over SFTP.ps1' and 'Move file.ps1'. The tests below read the
        function out of both scripts with the PowerShell parser, verify that
        the two copies are still identical and then test the behavior of the
        function.
#>

BeforeAll {
    $testFunctionName = 'Invoke-WithOptionalParallelismHC'

    $testScriptFile = @(
        Join-Path $PSScriptRoot '../Move file over SFTP.ps1'
        Join-Path $PSScriptRoot '../Move file.ps1'
    )

    function Get-FunctionTextHC {
        param (
            [Parameter(Mandatory)]
            [String]$Path,
            [Parameter(Mandatory)]
            [String]$Name
        )

        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $Path, [ref]$null, [ref]$null
        )

        $function = $ast.FindAll(
            {
                ($args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and
                ($args[0].Name -eq $Name)
            },
            $true
        )

        if ($function.Count -ne 1) {
            throw "Found $($function.Count) definitions of '$Name' in '$Path'"
        }

        $function[0].Extent.Text
    }

    $testFunctionText = foreach ($testFile in $testScriptFile) {
        Get-FunctionTextHC -Path $testFile -Name $testFunctionName
    }

    . ([scriptblock]::Create($testFunctionText[0]))
}
Describe 'the function is defined' {
    It 'in every script that runs code in parallel' {
        $testFunctionText | Should -HaveCount $testScriptFile.Count
    }
    It 'with the same code in every script' {
        $testNormalized = $testFunctionText.foreach(
            {
                ($_ -split '\r?\n').foreach({ $_.Trim() }) -join "`n"
            }
        )

        $testNormalized | Select-Object -Unique | Should -HaveCount 1
    }
}
Describe 'when ThrottleLimit is 1 or less the code runs sequentially' {
    It 'the scriptblock is called once for every input object' {
        $actual = Invoke-WithOptionalParallelismHC -InputObject @('a', 'b', 'c') -ThrottleLimit 1 -ScriptBlock {
            param($testItem)

            "processed-$testItem"
        }

        $actual | Should -HaveCount 3
        $actual | Should -Be @('processed-a', 'processed-b', 'processed-c')
    }
    It 'the order of the input objects is preserved' {
        $actual = Invoke-WithOptionalParallelismHC -InputObject (1..5) -ThrottleLimit 1 -ScriptBlock {
            param($testItem)

            $testItem * 10
        }

        $actual | Should -Be @(10, 20, 30, 40, 50)
    }
    It 'ArgumentList is passed to the scriptblock' {
        $actual = Invoke-WithOptionalParallelismHC -InputObject @('a', 'b') -ThrottleLimit 1 -ArgumentList 'PRE', 'POST' -ScriptBlock {
            param($testItem, $testPrefix, $testSuffix)

            "$testPrefix-$testItem-$testSuffix"
        }

        $actual | Should -Be @('PRE-a-POST', 'PRE-b-POST')
    }
    It 'no input objects does not call the scriptblock' {
        $testBag = [System.Collections.Concurrent.ConcurrentBag[String]]::new()

        $actual = Invoke-WithOptionalParallelismHC -InputObject @() -ThrottleLimit 1 -ArgumentList (, $testBag) -ScriptBlock {
            param($testItem, $testSink)

            $testSink.Add('called')
        }

        $testBag.Count | Should -Be 0
        $actual | Should -BeNullOrEmpty
    }
    It 'ThrottleLimit <_> runs on the current thread' -ForEach @(-1, 0, 1) {
        $testCounter = @{
            count = 0
        }

        $null = Invoke-WithOptionalParallelismHC -InputObject @(1, 2, 3) -ThrottleLimit $_ -ArgumentList (, $testCounter) -ScriptBlock {
            param($testItem, $testSink)

            $testSink.count++
        }

        $testCounter.count | Should -Be 3
    }
}
Describe 'when ThrottleLimit is more than 1 the code runs in parallel' {
    It 'the scriptblock is called once for every input object' {
        $actual = Invoke-WithOptionalParallelismHC -InputObject @('a', 'b', 'c', 'd') -ThrottleLimit 4 -ScriptBlock {
            param($testItem)

            "processed-$testItem"
        }

        $actual | Should -HaveCount 4
        $actual | Sort-Object | Should -Be @(
            'processed-a', 'processed-b', 'processed-c', 'processed-d'
        )
    }
    It 'ArgumentList is passed to the scriptblock' {
        $actual = Invoke-WithOptionalParallelismHC -InputObject @('a', 'b') -ThrottleLimit 2 -ArgumentList 'PRE', 'POST' -ScriptBlock {
            param($testItem, $testPrefix, $testSuffix)

            "$testPrefix-$testItem-$testSuffix"
        }

        $actual | Sort-Object | Should -Be @('PRE-a-POST', 'PRE-b-POST')
    }
    It 'no input objects does not call the scriptblock' {
        $testBag = [System.Collections.Concurrent.ConcurrentBag[String]]::new()

        $actual = Invoke-WithOptionalParallelismHC -InputObject @() -ThrottleLimit 4 -ArgumentList (, $testBag) -ScriptBlock {
            param($testItem, $testSink)

            $testSink.Add('called')
        }

        $testBag.Count | Should -Be 0
        $actual | Should -BeNullOrEmpty
    }
    It 'ThrottleLimit <_> runs in multiple runspaces' -ForEach @(2, 10) {
        # a ConcurrentBag is thread safe and passed by reference
        $testBag = [System.Collections.Concurrent.ConcurrentBag[Int]]::new()

        $null = Invoke-WithOptionalParallelismHC -InputObject @(1, 2, 3) -ThrottleLimit $_ -ArgumentList (, $testBag) -ScriptBlock {
            param($testItem, $testSink)

            $testSink.Add($testItem)
        }

        $testBag.Count | Should -Be 3
        $testBag | Sort-Object | Should -Be @(1, 2, 3)
    }
    It 'an object stored in the input object is passed by reference' {
        # this is how the scripts hand over a job object to the scriptblock
        $testJobs = 1..4 | ForEach-Object {
            [PSCustomObject]@{
                Id     = $_
                Result = @{
                    Value = $null
                }
            }
        }

        $null = Invoke-WithOptionalParallelismHC -InputObject $testJobs -ThrottleLimit 4 -ScriptBlock {
            param($testJob)

            $testJob.Result.Value = "done $($testJob.Id)"
        }

        $testJobs.Result.Value | Sort-Object | Should -Be @(
            'done 1', 'done 2', 'done 3', 'done 4'
        )
    }
}
