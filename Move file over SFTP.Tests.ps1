#Requires -Modules Pester
#Requires -Version 7

BeforeAll {
    $testInputFile = @{
        MaxConcurrentActions = 1
        Tasks             = @(
            @{
                TaskName = 'App x'
                Sftp     = @{
                    ComputerName = 'sftp.server.com'
                    Credential   = @{
                        UserName        = 'envVarBob'
                        Password        = 'envVarPasswordBob'
                        PasswordKeyFile = $null
                    }
                }
                Option   = @{
                    OverwriteFile  = $false
                    MatchFileNameRegex = '\.txt$'
                }
                Actions  = @(
                    @{
                        ComputerName = 'PC1'
                        Paths        = @(
                            @{
                                Source      = (New-Item 'TestDrive:\a' -ItemType Directory).FullName
                                Destination = 'sftp:/folder/a/'
                            }
                            @{
                                Source      = 'sftp:/folder/b/'
                                Destination = (New-Item 'TestDrive:\b' -ItemType Directory).FullName
                            }
                        )
                    }
                )
            }
        )
        SendMail          = @{
            To   = 'bob@contoso.com'
            When = 'Always'
        }
        ExportExcelFile   = @{
            When = 'OnlyOnErrorOrAction'
        }
    }

    $testData = @(
        [PSCustomObject]@{
            Source      = $testInputFile.Tasks[0].Actions[0].Paths[0].Source
            Destination = $testInputFile.Tasks[0].Actions[0].Paths[0].Destination
            FileName    = 'a.txt'
            FileLength  = 5KB
            DateTime    = Get-Date
            Moved       = $true
            Actions     = @('File moved after previous unsuccessful move')
            Errors      = @()
        }
        [PSCustomObject]@{
            Source      = $testInputFile.Tasks[0].Actions[0].Paths[1].Source
            Destination = $testInputFile.Tasks[0].Actions[0].Paths[1].Destination
            FileName    = 'b.txt'
            FileLength  = 3KB
            DateTime    = Get-Date
            Moved       = $true
            Actions     = @('File moved')
            Errors      = @()
        }
    )

    $testExportedExcelRows = @(
        [PSCustomObject]@{
            TaskName            = $testInputFile.Tasks[0].TaskName
            SourceComputer      = $testInputFile.Tasks[0].Actions[0].ComputerName
            DestinationComputer = $testInputFile.Tasks[0].Sftp.ComputerName
            SourcePath          = $testData[0].Source
            DestinationPath     = $testData[0].Destination
            FileName            = $testData[0].FileName
            FileSize            = $testData[0].FileLength / 1KB
            DateTime            = $testData[0].DateTime
            Moved               = $testData[0].Moved
            Actions             = $testData[0].Actions -join ', '
            Errors              = $null
        }
        [PSCustomObject]@{
            TaskName            = $testInputFile.Tasks[0].TaskName
            SourceComputer      = $testInputFile.Tasks[0].Sftp.ComputerName
            DestinationComputer = $testInputFile.Tasks[0].Actions[0].ComputerName
            SourcePath          = $testData[1].Source
            DestinationPath     = $testData[1].Destination
            FileName            = $testData[1].FileName
            FileSize            = $testData[1].FileLength / 1KB
            DateTime            = $testData[1].DateTime
            Moved               = $testData[1].Moved
            Actions             = $testData[1].Actions -join ', '
            Errors              = $null
        }
    )

    $testOutParams = @{
        FilePath = (New-Item 'TestDrive:/Test.json' -ItemType File).FullName
        Encoding = 'utf8'
    }

    $testScript = $PSCommandPath.Replace('.Tests.ps1', '.ps1')
    $testParams = @{
        ConfigurationJsonFile  = $testOutParams.FilePath
        ScriptPath  = @{
            MoveFile = (New-Item 'TestDrive:/u.ps1' -ItemType 'File').FullName
        }
    }

    Function Get-EnvironmentVariableValueHC {
        Param(
            [String]$Name
        )
    }

    $testPsSession = New-PSSession

    $testSecureStringPassword = ConvertTo-SecureString -String 'pw' -AsPlainText -Force

    Mock Get-EnvironmentVariableValueHC {
        'bobUserName'
    } -ParameterFilter {
        $Name -eq $testInputFile.Tasks[0].Sftp.Credential.UserName
    }
    Mock Get-EnvironmentVariableValueHC {
        'bobPassword'
    } -ParameterFilter {
        $Name -eq $testInputFile.Tasks[0].Sftp.Credential.Password
    }
    Mock ConvertTo-SecureString {
        $testSecureStringPassword
    } -ParameterFilter {
        $String -eq 'bobPassword'
    }
    Mock Invoke-Command {
        $testData
    }
    Mock New-PSSession {
        $testPsSession
    }
    Mock Remove-PSSession
    Mock Send-MailHC
    Mock Write-EventLog
}
Describe 'the mandatory parameters are' {
    It '<_>' -ForEach @('ConfigurationJsonFile') {
        (Get-Command $testScript).Parameters[$_].Attributes.Mandatory |
            Should -BeTrue
    }
}
Describe 'create an error log file when' {
    It 'the log folder cannot be created' {
        $testNewInputFile = Copy-ObjectHC $testInputFile
        $testNewInputFile.Settings.SaveLogFiles.Where.Folder = 'x:\notExistingLocation'

        & $realCmdLet.OutFile @testOutParams -InputObject (
            $testNewInputFile | ConvertTo-Json -Depth 7
        )

        .$testScript @testParams

        $LASTEXITCODE | Should -Be 1

        Should -Not -Invoke Out-File
    }
    Context 'the ImportFile' {
        It 'is not found' {
            $testNewParams = $testParams.clone()
            $testNewParams.ConfigurationJsonFile = 'nonExisting.json'

            .$testScript @testNewParams

            $LASTEXITCODE | Should -Be 1

            Should -Not -Invoke Out-File
        }
        Context 'property' {
            It 'Tasks.<_> not found' -ForEach @(
                'TaskName', 'Sftp', 'Option', 'Actions'
            ) {
                $testNewInputFile = Copy-ObjectHC $testInputFile
                $testNewInputFile.Tasks[0].$_ = $null

                & $realCmdLet.OutFile @testOutParams -InputObject (
                    $testNewInputFile | ConvertTo-Json -Depth 7
                )

                .$testScript @testParams

                $LASTEXITCODE | Should -Be 1

                Should -Invoke Out-File -Times 1 -Exactly -ParameterFilter {
                    ($LiteralPath -like '* - Errors.json') -and
                    ($InputObject -like "*Property 'Tasks.$_' not found*")
                }
            }
            It 'Tasks.Sftp.<_> not found' -ForEach @(
                'ComputerName', 'Credential'
            ) {
                $testNewInputFile = Copy-ObjectHC $testInputFile
                $testNewInputFile.Tasks[0].Sftp.$_ = $null

                & $realCmdLet.OutFile @testOutParams -InputObject (
                    $testNewInputFile | ConvertTo-Json -Depth 7
                )

                .$testScript @testParams

                $LASTEXITCODE | Should -Be 1

                Should -Invoke Out-File -Times 1 -Exactly -ParameterFilter {
                    ($LiteralPath -like '* - Errors.json') -and
                    ($InputObject -like "*Property 'Tasks.Sftp.$_' not found*")
                }
            }
            It 'Tasks.Sftp.Credential.<_> not found' -ForEach @(
                'UserName'
            ) {
                $testNewInputFile = Copy-ObjectHC $testInputFile
                $testNewInputFile.Tasks[0].Sftp.Credential.$_ = $null

                & $realCmdLet.OutFile @testOutParams -InputObject (
                    $testNewInputFile | ConvertTo-Json -Depth 7
                )

                .$testScript @testParams

                $LASTEXITCODE | Should -Be 1

                Should -Invoke Out-File -Times 1 -Exactly -ParameterFilter {
                    ($LiteralPath -like '* - Errors.json') -and
                    ($InputObject -like "*Property 'Tasks.Sftp.Credential.$_' not found*")
                }
            }
            It 'Tasks.Option.<_> not found' -ForEach @(
                'MatchFileNameRegex'
            ) {
                $testNewInputFile = Copy-ObjectHC $testInputFile
                $testNewInputFile.Tasks[0].Option.$_ = $null

                & $realCmdLet.OutFile @testOutParams -InputObject (
                    $testNewInputFile | ConvertTo-Json -Depth 7
                )

                .$testScript @testParams

                $LASTEXITCODE | Should -Be 1

                Should -Invoke Out-File -Times 1 -Exactly -ParameterFilter {
                    ($LiteralPath -like '* - Errors.json') -and
                    ($InputObject -like "*Property 'Tasks.Option.$_' not found*")
                }
            }
            It 'Tasks.Actions.<_> not found' -ForEach @(
                'ComputerName', 'Paths'
            ) {
                $testNewInputFile = Copy-ObjectHC $testInputFile
                $testNewInputFile.Tasks[0].Option.$_ = $null

                & $realCmdLet.OutFile @testOutParams -InputObject (
                    $testNewInputFile | ConvertTo-Json -Depth 7
                )

                .$testScript @testParams

                $LASTEXITCODE | Should -Be 1

                Should -Invoke Out-File -Times 1 -Exactly -ParameterFilter {
                    ($LiteralPath -like '* - Errors.json') -and
                    ($InputObject -like "*Property 'Tasks.Option.$_' not found*")
                }
            }
        }
    }
}
Describe 'correct the import file' {
    Context "add trailing slashes to Paths starting with 'sftp:/'" {
        It 'Source' {
            $testNewInputFile = Copy-ObjectHC $testInputFile
            $testNewInputFile.Tasks[0].Actions[0].Paths[0].Source = 'sftp:/a'
            $testNewInputFile.Tasks[0].Actions[0].Paths[0].Destination = 'TestDrive:\b'

            $testNewInputFile | ConvertTo-Json -Depth 7 |
                Out-File @testOutParams

            .$testScript @testParams

            $Tasks[0].Actions[0].Paths[0].Source | Should -Be 'sftp:/a/'
            $Tasks[0].Actions[0].Paths[0].Destination | Should -Be 'TestDrive:\b'
        }
        It 'Destination' {
            $testNewInputFile = Copy-ObjectHC $testInputFile
            $testNewInputFile.Tasks[0].Actions[0].Paths[0].Source = 'TestDrive:\b'
            $testNewInputFile.Tasks[0].Actions[0].Paths[0].Destination = 'sftp:/a'

            $testNewInputFile | ConvertTo-Json -Depth 7 |
                Out-File @testOutParams

            .$testScript @testParams

            $Tasks[0].Actions[0].Paths[0].Source | Should -Be 'TestDrive:\b'
            $Tasks[0].Actions[0].Paths[0].Destination | Should -Be 'sftp:/a/'
        }
    }
}
Describe 'execute the SFTP script when' {
    BeforeAll {
        $testJobArguments = @(
            {
                ($Session) -and
                ($FilePath -eq $testParams.ScriptPath.MoveFile) -and
                ($ArgumentList[0] -eq $testInputFile.Tasks[0].Sftp.ComputerName) -and
                ($ArgumentList[1].GetType().Name -eq 'PSCredential') -and
                ($ArgumentList[2].GetType().BaseType.Name -eq 'Array') -and
                ($ArgumentList[3] -eq $testInputFile.MaxConcurrentActions) -and
                ($ArgumentList[4] -eq 22) -and
                ($ArgumentList[5] -eq $testInputFile.Tasks[0].Option.MatchFileNameRegex) -and
                (-not $ArgumentList[6])
                ($ArgumentList[7] -eq $testInputFile.Tasks[0].Option.OverwriteFile)
            }
        )

        $testNewInputFile = Copy-ObjectHC $testInputFile
        $testNewInputFile.Tasks[0].Actions = @(
            $testNewInputFile.Tasks[0].Actions[0]
        )
    }
    Context 'Tasks.Actions.ComputerName is not the localhost' {
        BeforeAll {
            $testNewInputFile | ConvertTo-Json -Depth 7 |
                Out-File @testOutParams

            .$testScript @testParams
        }
        It 'call New-PSSession' {
            Should -Invoke New-PSSession -Times 1 -Exactly -Scope Context -ParameterFilter {
                ($ErrorAction -eq 'SilentlyContinue') -and
                ($ConfigurationName -eq $PSSessionConfiguration) -and
                ($ComputerName -eq $testNewInputFile.Tasks[0].Actions[0].ComputerName)
            }
        }
        It 'call Invoke-Command' {
            Should -Invoke Invoke-Command -Times 1 -Exactly -Scope Context -ParameterFilter {
                (& $testJobArguments[0])
            }
        }
        It 'call Remove-PSSession' {
            Should -Invoke Remove-PSSession -Times 1 -Exactly -Scope Context -ParameterFilter {
                ($Session -eq $testPsSession)
            }
        }
    }
    Context 'Tasks.Actions.ComputerName is the localhost' {
        BeforeAll {
            $testNewInputFile.Tasks[0].Actions[0].ComputerName = 'localhost'

            $testNewInputFile | ConvertTo-Json -Depth 7 |
                Out-File @testOutParams

            .$testScript @testParams
        }
        It 'do not call Invoke-Command ' {
            Should -Not -Invoke Invoke-Command -Scope Context
        }
        It 'do not call New-PSSession ' {
            Should -Not -Invoke New-PSSession -Scope Context
        }
        It 'do not call Remove-PSSession ' {
            Should -Not -Invoke Remove-PSSession -Scope Context
        }
    }
    Context 'with Tasks.Sftp.Credential.PasswordKeyFile' {
        BeforeAll {
            $testNewInputFile = Copy-ObjectHC $testInputFile
            $testNewInputFile.Tasks[0].Actions = @(
                $testNewInputFile.Tasks[0].Actions[0]
            )

            'sadfsd' | Out-File 'TestDrive:\key.txt'

            $testNewInputFile.Tasks[0].Sftp.Credential.Password = $null
            $testNewInputFile.Tasks[0].Sftp.Credential.PasswordKeyFile = 'TestDrive:\key.txt'

            $testNewInputFile | ConvertTo-Json -Depth 7 |
                Out-File @testOutParams

            .$testScript @testParams
        }
        It 'call Invoke-Command' {
            Should -Invoke Invoke-Command -Times 1 -Exactly -Scope Context -ParameterFilter {
                ($ArgumentList[4] -ne $null)
            }
        }
    }
}
Describe 'when the SFTP script runs successfully' {
    BeforeAll {
        $testInputFile | ConvertTo-Json -Depth 7 |
            Out-File @testOutParams

        .$testScript @testParams
    }
    Context 'create an Excel file' {
        BeforeAll {
            $testExcelLogFile = Get-ChildItem $testParams.LogFolder -File -Recurse -Filter "* - $((Split-Path $testOutParams.FilePath -Leaf).TrimEnd('.json')) - Log.xlsx"

            $actual = Import-Excel -Path $testExcelLogFile.FullName -WorksheetName 'Overview'
        }
        It 'in the log folder' {
            $testExcelLogFile | Should -Not -BeNullOrEmpty
        }
        It 'with the correct total rows' {
            $actual | Should -HaveCount $testExportedExcelRows.Count
        }
        It 'with the correct data in the rows' {
            foreach ($testRow in $testExportedExcelRows) {
                $actualRow = $actual | Where-Object {
                    $_.SourcePath -eq $testRow.SourcePath
                }
                $actualRow.TaskName | Should -Be $testRow.TaskName
                $actualRow.SourceComputer | Should -Be $testRow.SourceComputer
                $actualRow.DestinationComputer | Should -Be $testRow.DestinationComputer
                $actualRow.DestinationPath | Should -Be $testRow.DestinationPath
                $actualRow.Moved | Should -Be $testRow.Moved
                $actualRow.DateTime.ToString('yyyyMMdd') |
                    Should -Be $testRow.DateTime.ToString('yyyyMMdd')
                $actualRow.Actions -join ', ' | 
                    Should -Be ($testRow.Actions -join ', ')
                $actualRow.FileName | Should -Be $testRow.FileName
                $actualRow.FileSize | Should -Be $testRow.FileSize
                $actualRow.Errors -join ', ' | 
                    Should -Be ($testRow.Errors -join ', ')
            }
        }
    }
    Context 'send an e-mail' {
        It 'with attachment to the user' {
            Should -Invoke Send-MailHC -Exactly 1 -Scope Describe -ParameterFilter {
            ($To -eq $testInputFile.SendMail.To) -and
            ($Priority -eq 'Normal') -and
            ($Subject -eq '2 moved') -and
            ($Attachments -like '*- Log.xlsx') -and
            ($Message -like "*Summary of SFTP actions*table*$($testInputFile.Tasks[0].TaskName)*$($testInputFile.Tasks[0].Sftp.ComputerName)*Source*Destination*Result*$($testInputFile.Tasks[0].Actions[0].Paths[0].Source)*$($testInputFile.Tasks[0].Actions[0].Paths[0].Destination)*1 moved*$($testInputFile.Tasks[0].Actions[0].Paths[1].Source)*$($testInputFile.Tasks[0].Actions[0].Paths[1].Destination)*1 moved*2 moved on $($testInputFile.Tasks[0].Actions[0].ComputerName)*")
            }
        }
    }
}
Describe 'ExportExcelFile.When' {
    Context 'create no Excel file' {
        It "'Never'" {
            $testNewInputFile = Copy-ObjectHC $testInputFile
            $testNewInputFile.ExportExcelFile.When = 'Never'

            $testNewInputFile | ConvertTo-Json -Depth 7 |
                Out-File @testOutParams

            .$testScript @testParams

            Get-ChildItem $testParams.LogFolder -File -Recurse -Filter '*.xlsx' |
                Should -BeNullOrEmpty
        }
        It "'OnlyOnError' and no errors are found" {
            $testNewInputFile = Copy-ObjectHC $testInputFile
            $testNewInputFile.ExportExcelFile.When = 'OnlyOnError'

            $testNewInputFile | ConvertTo-Json -Depth 7 |
                Out-File @testOutParams

            .$testScript @testParams

            Get-ChildItem $testParams.LogFolder -File -Recurse -Filter '*.xlsx' |
                Should -BeNullOrEmpty
        }
        It "'OnlyOnErrorOrAction' and there are no errors and no actions" {
            Mock Invoke-Command {
            } -ParameterFilter {
                $FilePath -eq $testParams.ScriptPath.MoveFile
            }

            $testNewInputFile = Copy-ObjectHC $testInputFile
            $testNewInputFile.ExportExcelFile.When = 'OnlyOnErrorOrAction'

            $testNewInputFile | ConvertTo-Json -Depth 7 |
                Out-File @testOutParams

            .$testScript @testParams

            Get-ChildItem $testParams.LogFolder -File -Recurse -Filter '*.xlsx' |
                Should -BeNullOrEmpty
        }
    }
    Context 'create an Excel file' {
        It "'OnlyOnError' and there are errors" {
            Mock Invoke-Command {
                [PSCustomObject]@{
                    Path     = 'a'
                    DateTime = Get-Date
                    Actions  = @()
                    Errors   = 'oops'
                }
            } -ParameterFilter {
                $FilePath -eq $testParams.ScriptPath.MoveFile
            }

            $testNewInputFile = Copy-ObjectHC $testInputFile
            $testNewInputFile.ExportExcelFile.When = 'OnlyOnError'

            $testNewInputFile | ConvertTo-Json -Depth 7 |
                Out-File @testOutParams

            .$testScript @testParams

            Get-ChildItem $testParams.LogFolder -File -Recurse -Filter '*.xlsx' |
                Should -Not -BeNullOrEmpty
        }
        It "'OnlyOnErrorOrAction' and there are actions but no errors" {
            Mock Invoke-Command {
                [PSCustomObject]@{
                    Path     = 'a'
                    DateTime = Get-Date
                    Moved    = $true
                    Actions  = @('upload')
                    Errors   = $null
                }
            } -ParameterFilter {
                $FilePath -eq $testParams.ScriptPath.MoveFile
            }

            $testNewInputFile = Copy-ObjectHC $testInputFile
            $testNewInputFile.ExportExcelFile.When = 'OnlyOnErrorOrAction'

            $testNewInputFile | ConvertTo-Json -Depth 7 |
                Out-File @testOutParams

            .$testScript @testParams

            Get-ChildItem $testParams.LogFolder -File -Recurse -Filter '*.xlsx' |
                Should -Not -BeNullOrEmpty
        }
        It "'OnlyOnErrorOrAction' and there are errors but no actions" {
            Mock Invoke-Command {
                [PSCustomObject]@{
                    Path     = 'a'
                    Moved    = $false
                    DateTime = Get-Date
                    Actions  = @()
                    Errors   = @('oops')
                }
            } -ParameterFilter {
                $FilePath -eq $testParams.ScriptPath.MoveFile
            }

            $testNewInputFile = Copy-ObjectHC $testInputFile
            $testNewInputFile.ExportExcelFile.When = 'OnlyOnErrorOrAction'

            $testNewInputFile | ConvertTo-Json -Depth 7 |
                Out-File @testOutParams

            .$testScript @testParams

            Get-ChildItem $testParams.LogFolder -File -Recurse -Filter '*.xlsx' |
                Should -Not -BeNullOrEmpty
        }
    }
}
Describe 'SendMail.When' {
    BeforeAll {
        $testParamFilter = @{
            ParameterFilter = { $To -eq $testNewInputFile.SendMail.To }
        }
    }
    Context 'send no e-mail to the user' {
        It "'Never'" {
            $testNewInputFile = Copy-ObjectHC $testInputFile
            $testNewInputFile.SendMail.When = 'Never'

            $testNewInputFile | ConvertTo-Json -Depth 7 |
                Out-File @testOutParams

            .$testScript @testParams

            Should -Not -Invoke Send-MailHC @testParamFilter
        }
        It "'OnlyOnError' and no errors are found" {
            $testNewInputFile = Copy-ObjectHC $testInputFile
            $testNewInputFile.SendMail.When = 'OnlyOnError'

            $testNewInputFile | ConvertTo-Json -Depth 7 |
                Out-File @testOutParams

            .$testScript @testParams

            Should -Not -Invoke Send-MailHC
        }
        It "'OnlyOnErrorOrAction' and there are no errors and no actions" {
            Mock Invoke-Command {
            } -ParameterFilter {
                $FilePath -eq $testParams.ScriptPath.MoveFile
            }

            $testNewInputFile = Copy-ObjectHC $testInputFile
            $testNewInputFile.SendMail.When = 'OnlyOnErrorOrAction'

            $testNewInputFile | ConvertTo-Json -Depth 7 |
                Out-File @testOutParams

            .$testScript @testParams

            Should -Not -Invoke Send-MailHC
        }
    }
    Context 'send an e-mail to the user' {
        It "'OnlyOnError' and there are errors" {
            Mock Invoke-Command {
                [PSCustomObject]@{
                    Path     = 'a'
                    DateTime = Get-Date
                    Actions  = @()
                    Errors   = @('oops')
                }
            } -ParameterFilter {
                $FilePath -eq $testParams.ScriptPath.MoveFile
            }

            $testNewInputFile = Copy-ObjectHC $testInputFile
            $testNewInputFile.SendMail.When = 'OnlyOnError'

            $testNewInputFile | ConvertTo-Json -Depth 7 |
                Out-File @testOutParams

            .$testScript @testParams

            Should -Invoke Send-MailHC @testParamFilter
        }
        It "'OnlyOnErrorOrAction' and there are errors but no actions" {
            Mock Invoke-Command {
                [PSCustomObject]@{
                    Path     = 'a'
                    DateTime = Get-Date
                    Actions  = @()
                    Errors   = @('oops')
                }
            } -ParameterFilter {
                $FilePath -eq $testParams.ScriptPath.MoveFile
            }

            $testNewInputFile = Copy-ObjectHC $testInputFile
            $testNewInputFile.SendMail.When = 'OnlyOnErrorOrAction'

            $testNewInputFile | ConvertTo-Json -Depth 7 |
                Out-File @testOutParams

            .$testScript @testParams

            Should -Invoke Send-MailHC @testParamFilter
        }
    }
}
Describe 'ReportOnly' {
    BeforeAll {
    }
    Context 'when no previously exported Excel file is found' {
        BeforeAll {
            Get-ChildItem $testParams.LogFolder -Recurse -Filter '*.xlsx' |
                Should -BeNullOrEmpty

            $testInputFile | ConvertTo-Json -Depth 7 |
                Out-File @testOutParams

            .$testScript @testParams -ReportOnly
        }
        It 'no not create an Excel file' {
            Get-ChildItem $testParams.LogFolder -Recurse -Filter '*.xlsx' |
                Should -BeNullOrEmpty
        }
        It 'do not call the SFTP script' {
            Should -Not -Invoke New-PSSession
            Should -Not -Invoke Invoke-Command
        }
        It 'send an e-mail' {
            Should -Invoke Send-MailHC -Exactly 1 -Scope Context

            Should -Invoke Send-MailHC -Exactly 1 -Scope Context -ParameterFilter {
                ($To -eq $testInputFile.SendMail.To) -and
                ($Priority -eq 'Normal') -and
                ($Subject -eq '0 moved') -and
                (-not $Attachments) -and
                ($Message -like "*Summary of all SFTP actions <b>executed today</b>*table*$($testInputFile.Tasks[0].TaskName)*$($testInputFile.Tasks[0].Sftp.ComputerName)*Source*Destination*Result*$($testInputFile.Tasks[0].Actions[0].Paths[0].Source)*$($testInputFile.Tasks[0].Actions[0].Paths[0].Destination)*0 moved*$($testInputFile.Tasks[0].Actions[0].Paths[1].Source)*$($testInputFile.Tasks[0].Actions[0].Paths[1].Destination)*0 moved*0 moved on $($testInputFile.Tasks[0].Actions[0].ComputerName)*")
            }
        }
    }
    Context 'when a previously exported Excel file is found' {
        BeforeAll {
            $testExportParams = @{
                WorksheetName = 'Overview'
                Path          = $testParams.LogFolder + '\' + (Get-Date).ToString('yyyy-MM-dd') + ' - ' + $testParams.ScriptName + ' - ' + (Split-Path $testParams.ConfigurationJsonFile -Leaf).TrimEnd('.json') + ' - Log.xlsx'
            }
            $testExportedExcelRows | Export-Excel @testExportParams

            $testInputFile | ConvertTo-Json -Depth 7 |
                Out-File @testOutParams

            .$testScript @testParams -ReportOnly
        }
        It 'do not call the SFTP script' {
            Should -Not -Invoke New-PSSession
            Should -Not -Invoke Invoke-Command
        }
        It 'send an e-mail' {
            Should -Invoke Send-MailHC -Exactly 1 -Scope Context -ParameterFilter {
            ($To -eq $testInputFile.SendMail.To) -and
            ($Attachments -eq $testExportParams.Path) -and
            ($Priority -eq 'Normal') -and
            ($Subject -eq '2 moved') -and
            ($Message -like "*Summary of all SFTP actions <b>executed today</b>*table*$($testInputFile.Tasks[0].TaskName)*$($testInputFile.Tasks[0].Sftp.ComputerName)*Source*Destination*Result*$($testInputFile.Tasks[0].Actions[0].Paths[0].Source)*$($testInputFile.Tasks[0].Actions[0].Paths[0].Destination)*1 moved*$($testInputFile.Tasks[0].Actions[0].Paths[1].Source)*$($testInputFile.Tasks[0].Actions[0].Paths[1].Destination)*1 moved*2 moved on $($testInputFile.Tasks[0].Actions[0].ComputerName)*")
            }
        }
    }
}
