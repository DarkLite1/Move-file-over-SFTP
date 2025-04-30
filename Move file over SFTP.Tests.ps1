#Requires -Modules Pester
#Requires -Modules Toolbox.EventLog, Toolbox.HTML
#Requires -Version 5.1

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
                    FileExtensions = @('.txt')
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
        ScriptName  = 'Test (Brecht)'
        ConfigurationJsonFile  = $testOutParams.FilePath
        ScriptPath  = @{
            MoveFile = (New-Item 'TestDrive:/u.ps1' -ItemType 'File').FullName
        }
        LogFolder   = (New-Item 'TestDrive:/log' -ItemType Directory).FullName
        ScriptAdmin = 'admin@contoso.com'
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
    It '<_>' -ForEach @('ConfigurationJsonFile', 'ScriptName') {
        (Get-Command $testScript).Parameters[$_].Attributes.Mandatory |
            Should -BeTrue
    }
}
Describe 'send an e-mail to the admin when' {
    BeforeAll {
        $MailAdminParams = {
            ($To -eq $testParams.ScriptAdmin) -and
            ($Priority -eq 'High') -and
            ($Subject -eq 'FAILURE')
        }
    }
    It 'the log folder cannot be created' {
        $testNewParams = Copy-ObjectHC $testParams
        $testNewParams.LogFolder = 'xxx:://notExistingLocation'

        .$testScript @testNewParams

        Should -Invoke Send-MailHC -Exactly 1 -ParameterFilter {
            (&$MailAdminParams) -and
            ($Message -like '*Failed creating the log folder*')
        }
    }
    Context 'the file is not found' {
        It 'ScriptPath.MoveFile' {
            $testNewParams = Copy-ObjectHC $testParams
            $testNewParams.ScriptPath.MoveFile = 'c:\upDoesNotExist.ps1'

            $testInputFile | ConvertTo-Json -Depth 7 |
                Out-File @testOutParams

            .$testScript @testNewParams

            Should -Invoke Send-MailHC -Exactly 1 -ParameterFilter {
                    (&$MailAdminParams) -and ($Message -like "*ScriptPath.MoveFile 'c:\upDoesNotExist.ps1' not found*")
            }
            Should -Invoke Write-EventLog -Exactly 1 -ParameterFilter {
                $EntryType -eq 'Error'
            }
        }
    }
    Context 'the ConfigurationJsonFile' {
        It 'is not found' {
            $testNewParams = Copy-ObjectHC $testParams
            $testNewParams.ConfigurationJsonFile = 'nonExisting.json'

            .$testScript @testNewParams

            Should -Invoke Send-MailHC -Exactly 1 -ParameterFilter {
                    (&$MailAdminParams) -and ($Message -like 'Cannot find Path*nonExisting.json*')
            }
            Should -Invoke Write-EventLog -Exactly 1 -ParameterFilter {
                $EntryType -eq 'Error'
            }
        }
        Context 'property' {
            It '<_> not found' -ForEach @(
                'MaxConcurrentActions', 'Tasks', 'SendMail', 'ExportExcelFile'
            ) {
                $testNewInputFile = Copy-ObjectHC $testInputFile
                $testNewInputFile.$_ = $null

                $testNewInputFile | ConvertTo-Json -Depth 7 |
                    Out-File @testOutParams

                .$testScript @testParams

                Should -Invoke Send-MailHC -Exactly 1 -ParameterFilter {
                        (&$MailAdminParams) -and
                        ($Message -like "*$ConfigurationJsonFile*Property '$_' not found*")
                }
                Should -Invoke Write-EventLog -Exactly 1 -ParameterFilter {
                    $EntryType -eq 'Error'
                }
            }
            It 'MaxConcurrentActions not a number' {
                $testNewInputFile = Copy-ObjectHC $testInputFile
                $testNewInputFile.MaxConcurrentActions = 'wrong'

                $testNewInputFile | ConvertTo-Json -Depth 7 |
                    Out-File @testOutParams

                .$testScript @testParams

                Should -Invoke Send-MailHC -Exactly 1 -ParameterFilter {
                        (&$MailAdminParams) -and
                        ($Message -like "*$ConfigurationJsonFile*Property 'MaxConcurrentActions' needs to be a number, the value 'wrong' is not supported.*")
                }
                Should -Invoke Write-EventLog -Exactly 1 -ParameterFilter {
                    $EntryType -eq 'Error'
                }
            }
            It 'Tasks.<_> not found' -ForEach @(
                'TaskName', 'Sftp', 'Actions', 'Option'
            ) {
                $testNewInputFile = Copy-ObjectHC $testInputFile
                $testNewInputFile.Tasks[0].$_ = $null

                $testNewInputFile | ConvertTo-Json -Depth 7 |
                    Out-File @testOutParams

                .$testScript @testParams

                Should -Invoke Send-MailHC -Exactly 1 -ParameterFilter {
                    (&$MailAdminParams) -and
                    ($Message -like "*$ConfigurationJsonFile*Property 'Tasks.$_' not found*")
                }
                Should -Invoke Write-EventLog -Exactly 1 -ParameterFilter {
                    $EntryType -eq 'Error'
                }
            }
            It 'Tasks.TaskName not found' {
                $testNewInputFile = Copy-ObjectHC $testInputFile
                $testNewInputFile.Tasks[0].TaskName = $null

                $testNewInputFile | ConvertTo-Json -Depth 7 |
                    Out-File @testOutParams

                .$testScript @testParams

                Should -Invoke Send-MailHC -Exactly 1 -ParameterFilter {
                        (&$MailAdminParams) -and
                        ($Message -like "*$ConfigurationJsonFile*Property 'Tasks.TaskName' not found*")
                }
            }
            It 'Tasks.Sftp.<_> not found' -ForEach @(
                'ComputerName', 'Credential'
            ) {
                $testNewInputFile = Copy-ObjectHC $testInputFile
                $testNewInputFile.Tasks[0].Sftp.$_ = $null

                $testNewInputFile | ConvertTo-Json -Depth 7 |
                    Out-File @testOutParams

                .$testScript @testParams

                Should -Invoke Send-MailHC -Exactly 1 -ParameterFilter {
                        (&$MailAdminParams) -and
                        ($Message -like "*$ConfigurationJsonFile*Property 'Tasks.Sftp.$_' not found*")
                }
                Should -Invoke Write-EventLog -Exactly 1 -ParameterFilter {
                    $EntryType -eq 'Error'
                }
            }
            It 'Tasks.Sftp.Credential.<_> not found' -ForEach @(
                'UserName'
            ) {
                $testNewInputFile = Copy-ObjectHC $testInputFile
                $testNewInputFile.Tasks[0].Sftp.Credential.$_ = $null

                $testNewInputFile | ConvertTo-Json -Depth 7 |
                    Out-File @testOutParams

                .$testScript @testParams

                Should -Invoke Send-MailHC -Exactly 1 -ParameterFilter {
                        (&$MailAdminParams) -and
                        ($Message -like "*$ConfigurationJsonFile*Property 'Tasks.Sftp.Credential.$_' not found*")
                }
                Should -Invoke Write-EventLog -Exactly 1 -ParameterFilter {
                    $EntryType -eq 'Error'
                }
            }
            Context 'Tasks.Sftp.Credential' {
                It 'Password or PasswordKeyFile are missing' {
                    $testNewInputFile = Copy-ObjectHC $testInputFile
                    $testNewInputFile.Tasks[0].Sftp.Credential.Password = $null
                    $testNewInputFile.Tasks[0].Sftp.Credential.PasswordKeyFile = $null

                    $testNewInputFile | ConvertTo-Json -Depth 7 |
                        Out-File @testOutParams

                    .$testScript @testParams

                    Should -Invoke Send-MailHC -Exactly 1 -ParameterFilter {
                            (&$MailAdminParams) -and
                            ($Message -like "*$ConfigurationJsonFile*Property 'Tasks.Sftp.Credential.Password' or 'Tasks.Sftp.Credential.PasswordKeyFile' not found*")
                    }
                    Should -Invoke Write-EventLog -Exactly 1 -ParameterFilter {
                        $EntryType -eq 'Error'
                    }
                }
                It 'Password and PasswordKeyFile used at the same time' {
                    $testNewInputFile = Copy-ObjectHC $testInputFile
                    $testNewInputFile.Tasks[0].Sftp.Credential.Password = 'a'
                    $testNewInputFile.Tasks[0].Sftp.Credential.PasswordKeyFile = 'b'

                    $testNewInputFile | ConvertTo-Json -Depth 7 |
                        Out-File @testOutParams

                    .$testScript @testParams

                    Should -Invoke Send-MailHC -Exactly 1 -ParameterFilter {
                            (&$MailAdminParams) -and
                            ($Message -like "*$ConfigurationJsonFile*Property 'Tasks.Sftp.Credential.Password' and 'Tasks.Sftp.Credential.PasswordKeyFile' cannot be used at the same time*")
                    }
                    Should -Invoke Write-EventLog -Exactly 1 -ParameterFilter {
                        $EntryType -eq 'Error'
                    }
                }
                It 'PasswordKeyFile does not exist' {
                    $testNewInputFile = Copy-ObjectHC $testInputFile
                    $testNewInputFile.Tasks[0].Sftp.Credential.Password = $null
                    $testNewInputFile.Tasks[0].Sftp.Credential.PasswordKeyFile = 'a'

                    $testNewInputFile | ConvertTo-Json -Depth 7 |
                        Out-File @testOutParams

                    .$testScript @testParams

                    Should -Invoke Send-MailHC -Exactly 1 -ParameterFilter {
                            (&$MailAdminParams) -and
                            ($Message -like "*$ConfigurationJsonFile*Failed converting the task.Sftp.Credential.PasswordKeyFile*")
                    }
                    Should -Invoke Write-EventLog -Exactly 1 -ParameterFilter {
                        $EntryType -eq 'Error'
                    }
                }
                It 'PasswordKeyFile is an empty file' {
                    $testNewInputFile = Copy-ObjectHC $testInputFile
                    $testNewInputFile.Tasks[0].Sftp.Credential.Password = $null
                    $testNewInputFile.Tasks[0].Sftp.Credential.PasswordKeyFile = (New-Item 'TestDrive:\a.pub' -ItemType File).FullName

                    $testNewInputFile | ConvertTo-Json -Depth 7 |
                        Out-File @testOutParams

                    .$testScript @testParams

                    Should -Invoke Send-MailHC -Exactly 1 -ParameterFilter {
                            (&$MailAdminParams) -and
                            ($Message -like "*$ConfigurationJsonFile*Failed converting the task.Sftp.Credential.PasswordKeyFile*")
                    }
                    Should -Invoke Write-EventLog -Exactly 1 -ParameterFilter {
                        $EntryType -eq 'Error'
                    }
                }
            }

            Context 'Tasks.Actions' {
                It 'Tasks.Actions.<_> not found' -ForEach @(
                    'Paths'
                ) {
                    $testNewInputFile = Copy-ObjectHC $testInputFile
                    $testNewInputFile.Tasks[0].Actions[0].$_ = $null

                    $testNewInputFile | ConvertTo-Json -Depth 7 |
                        Out-File @testOutParams

                    .$testScript @testParams

                    Should -Invoke Send-MailHC -Exactly 1 -ParameterFilter {
                        (&$MailAdminParams) -and
                        ($Message -like "*$ConfigurationJsonFile*Property 'Tasks.Actions.$_' not found*")
                    }
                    Should -Invoke Write-EventLog -Exactly 1 -ParameterFilter {
                        $EntryType -eq 'Error'
                    }
                }
                Context 'Tasks.Actions.ComputerName' {
                    It 'property ComputerName not found' {
                        $testNewInputFile = Copy-ObjectHC $testInputFile
                        $testNewInputFile.Tasks[0].Actions[0].Remove('ComputerName')

                        $testNewInputFile | ConvertTo-Json -Depth 7 |
                            Out-File @testOutParams

                        .$testScript @testParams

                        Should -Invoke Send-MailHC -Exactly 1 -ParameterFilter {
                            (&$MailAdminParams) -and
                            ($Message -like "*$ConfigurationJsonFile*Property 'Tasks.Actions.ComputerName' not found*")
                        }
                        Should -Invoke Write-EventLog -Exactly 1 -ParameterFilter {
                            $EntryType -eq 'Error'
                        }
                    }
                    It 'Duplicate ComputerName' {
                        $testNewInputFile = Copy-ObjectHC $testInputFile

                        $testNewInputFile.Tasks[0].Actions = @(
                            $testNewInputFile.Tasks[0].Actions[0],
                            $testNewInputFile.Tasks[0].Actions[0]
                        )

                        $testNewInputFile | ConvertTo-Json -Depth 7 |
                            Out-File @testOutParams

                        .$testScript @testParams

                        Should -Invoke Send-MailHC -Exactly 1 -ParameterFilter {
                            (&$MailAdminParams) -and
                            ($Message -like "*$ConfigurationJsonFile*Duplicate 'Tasks.Actions.ComputerName' found: $($testNewInputFile.Tasks[0].Actions[0].ComputerName)*")
                        }
                        Should -Invoke Write-EventLog -Exactly 1 -ParameterFilter {
                            $EntryType -eq 'Error'
                        }
                    }
                }
                It 'Tasks.Actions.Paths.<_> not found' -ForEach @(
                    'Source', 'Destination'
                ) {
                    $testNewInputFile = Copy-ObjectHC $testInputFile
                    $testNewInputFile.Tasks[0].Actions[0].Paths[0].$_ = $null

                    $testNewInputFile | ConvertTo-Json -Depth 7 |
                        Out-File @testOutParams

                    .$testScript @testParams

                    Should -Invoke Send-MailHC -Exactly 1 -ParameterFilter {
                        (&$MailAdminParams) -and
                        ($Message -like "*$ConfigurationJsonFile*Property 'Tasks.Actions.Paths.$_' not found*")
                    }
                    Should -Invoke Write-EventLog -Exactly 1 -ParameterFilter {
                        $EntryType -eq 'Error'
                    }
                }
                Context 'Tasks.Actions.Paths' {
                    It 'Source + Destination are both local paths' {
                        $testNewInputFile = Copy-ObjectHC $testInputFile
                        $testNewInputFile.Tasks[0].Actions[0].Paths[0].Source = 'TestDrive:\a'
                        $testNewInputFile.Tasks[0].Actions[0].Paths[0].Destination = 'TestDrive:\b'

                        $testNewInputFile | ConvertTo-Json -Depth 7 |
                            Out-File @testOutParams

                        .$testScript @testParams

                        Should -Invoke Send-MailHC -Exactly 1 -ParameterFilter {
                            (&$MailAdminParams) -and
                            ($Message -like "*$ConfigurationJsonFile*Property 'Tasks.Actions.Paths.Source' and 'Tasks.Actions.Paths.Destination' needs to have one SFTP path ('sftp:/....') and one folder path (c:\... or \\server$\...)*")
                        }
                        Should -Invoke Write-EventLog -Exactly 1 -ParameterFilter {
                            $EntryType -eq 'Error'
                        }
                    }
                    It 'Source + Destination are both SFTP paths' {
                        $testNewInputFile = Copy-ObjectHC $testInputFile
                        $testNewInputFile.Tasks[0].Actions[0].Paths[0].Source = '/out/a'
                        $testNewInputFile.Tasks[0].Actions[0].Paths[0].Destination = '/out/b'

                        $testNewInputFile | ConvertTo-Json -Depth 7 |
                            Out-File @testOutParams

                        .$testScript @testParams

                        Should -Invoke Send-MailHC -Exactly 1 -ParameterFilter {
                            (&$MailAdminParams) -and
                            ($Message -like "*$ConfigurationJsonFile*Property 'Tasks.Actions.Paths.Source' and 'Tasks.Actions.Paths.Destination' needs to have one SFTP path ('sftp:/....') and one folder path (c:\... or \\server$\...)*")
                        }
                        Should -Invoke Write-EventLog -Exactly 1 -ParameterFilter {
                            $EntryType -eq 'Error'
                        }
                    }
                    It "Source + Destination both start with 'sftp'" {
                        $testNewInputFile = Copy-ObjectHC $testInputFile
                        $testNewInputFile.Tasks[0].Actions[0].Paths[0].Source = 'sftp/a'
                        $testNewInputFile.Tasks[0].Actions[0].Paths[0].Destination = 'sftp\b'

                        $testNewInputFile | ConvertTo-Json -Depth 7 |
                            Out-File @testOutParams

                        .$testScript @testParams

                        Should -Invoke Send-MailHC -Exactly 1 -ParameterFilter {
                            (&$MailAdminParams) -and
                            ($Message -like "*$ConfigurationJsonFile*Property 'Tasks.Actions.Paths.Source' and 'Tasks.Actions.Paths.Destination' needs to have one SFTP path ('sftp:/....') and one folder path (c:\... or \\server$\...)*")
                        }
                        Should -Invoke Write-EventLog -Exactly 1 -ParameterFilter {
                            $EntryType -eq 'Error'
                        }
                    }
                    It "Source + Destination have not path starting with 'sftp:/'" {
                        $testNewInputFile = Copy-ObjectHC $testInputFile
                        $testNewInputFile.Tasks[0].Actions[0].Paths[0].Source = '/a/'
                        $testNewInputFile.Tasks[0].Actions[0].Paths[0].Destination = 'TestDrive:\b'

                        $testNewInputFile | ConvertTo-Json -Depth 7 |
                            Out-File @testOutParams

                        .$testScript @testParams

                        Should -Invoke Send-MailHC -Exactly 1 -ParameterFilter {
                            (&$MailAdminParams) -and
                            ($Message -like "*$ConfigurationJsonFile*Property 'Tasks.Actions.Paths.Source' and 'Tasks.Actions.Paths.Destination' needs to have one SFTP path ('sftp:/....') and one folder path (c:\... or \\server$\...)*")
                        }
                        Should -Invoke Write-EventLog -Exactly 1 -ParameterFilter {
                            $EntryType -eq 'Error'
                        }
                    }
                    It 'Duplicate Source paths' {
                        $testNewInputFile = Copy-ObjectHC $testInputFile

                        $testSourceFolder = (New-Item 'TestDrive:\i' -ItemType Directory).FullName

                        $testNewInputFile.Tasks[0].Actions[0].Paths = @(
                            @{
                                Source      = $testSourceFolder
                                Destination = 'sftp:/folder/a/'
                            }
                            @{
                                Source      = $testSourceFolder
                                Destination = 'sftp:/folder/b/'
                            }
                        )

                        $testNewInputFile | ConvertTo-Json -Depth 7 |
                            Out-File @testOutParams

                        .$testScript @testParams

                        Should -Invoke Send-MailHC -Exactly 1 -ParameterFilter {
                            (&$MailAdminParams) -and
                            ($Message -like "*$ConfigurationJsonFile*Duplicate 'Tasks.Actions.Paths.Source' found: '$testSourceFolder'*")
                        }
                        Should -Invoke Write-EventLog -Exactly 1 -ParameterFilter {
                            $EntryType -eq 'Error'
                        }
                    }
                    It 'Duplicate Destination paths' {
                        $testNewInputFile = Copy-ObjectHC $testInputFile

                        $testNewInputFile.Tasks[0].Actions[0].Paths = @(
                            @{
                                Source      = (New-Item 'TestDrive:\e' -ItemType Directory).FullName
                                Destination = 'sftp:/folder/a/'
                            }
                            @{
                                Source      = (New-Item 'TestDrive:\g' -ItemType Directory).FullName
                                Destination = 'sftp:/folder/a/'
                            }
                        )

                        $testNewInputFile | ConvertTo-Json -Depth 7 |
                            Out-File @testOutParams

                        .$testScript @testParams

                        Should -Invoke Send-MailHC -Exactly 1 -ParameterFilter {
                            (&$MailAdminParams) -and
                            ($Message -like "*$ConfigurationJsonFile*Duplicate 'Tasks.Actions.Paths.Destination' found: '$($testNewInputFile.Tasks[0].Actions[0].Paths[0].Destination)'*")
                        }
                        Should -Invoke Write-EventLog -Exactly 1 -ParameterFilter {
                            $EntryType -eq 'Error'
                        }
                    }
                }
            }
            It 'Tasks.Option.<_> not a boolean' -ForEach @(
                'OverwriteFile'
            ) {
                $testNewInputFile = Copy-ObjectHC $testInputFile
                $testNewInputFile.Tasks[0].Option.$_ = $null

                $testNewInputFile | ConvertTo-Json -Depth 7 |
                    Out-File @testOutParams

                .$testScript @testParams

                Should -Invoke Send-MailHC -Exactly 1 -ParameterFilter {
                        (&$MailAdminParams) -and
                        ($Message -like "*$ConfigurationJsonFile*Property 'Tasks.Option.$_' is not a boolean value*")
                }
            }
            It 'SendMail.<_> not found' -ForEach @(
                'To', 'When'
            ) {
                $testNewInputFile = Copy-ObjectHC $testInputFile
                $testNewInputFile.SendMail.$_ = $null

                $testNewInputFile | ConvertTo-Json -Depth 7 |
                    Out-File @testOutParams

                .$testScript @testParams

                Should -Invoke Send-MailHC -Exactly 1 -ParameterFilter {
                        (&$MailAdminParams) -and
                        ($Message -like "*$ConfigurationJsonFile*Property 'SendMail.$_' not found*")
                }
                Should -Invoke Write-EventLog -Exactly 1 -ParameterFilter {
                    $EntryType -eq 'Error'
                }
            }
            It 'ExportExcelFile.<_> not found' -ForEach @(
                'When'
            ) {
                $testNewInputFile = Copy-ObjectHC $testInputFile
                $testNewInputFile.ExportExcelFile.$_ = $null

                $testNewInputFile | ConvertTo-Json -Depth 7 |
                    Out-File @testOutParams

                .$testScript @testParams

                Should -Invoke Send-MailHC -Exactly 1 -ParameterFilter {
                        (&$MailAdminParams) -and
                        ($Message -like "*$ConfigurationJsonFile*Property 'ExportExcelFile.$_' not found*")
                }
                Should -Invoke Write-EventLog -Exactly 1 -ParameterFilter {
                    $EntryType -eq 'Error'
                }
            }
            It 'ExportExcelFile.When is not valid' {
                $testNewInputFile = Copy-ObjectHC $testInputFile
                $testNewInputFile.ExportExcelFile.When = 'wrong'

                $testNewInputFile | ConvertTo-Json -Depth 7 |
                    Out-File @testOutParams

                .$testScript @testParams

                Should -Invoke Send-MailHC -Exactly 1 -ParameterFilter {
                        (&$MailAdminParams) -and
                        ($Message -like "*$ConfigurationJsonFile*Property 'ExportExcelFile.When' with value 'wrong' is not valid. Accepted values are 'Never', 'OnlyOnError' or 'OnlyOnErrorOrAction'*")
                }
                Should -Invoke Write-EventLog -Exactly 1 -ParameterFilter {
                    $EntryType -eq 'Error'
                }
            }
            It 'SendMail.When is not valid' {
                $testNewInputFile = Copy-ObjectHC $testInputFile
                $testNewInputFile.SendMail.When = 'wrong'

                $testNewInputFile | ConvertTo-Json -Depth 7 |
                    Out-File @testOutParams

                .$testScript @testParams

                Should -Invoke Send-MailHC -Exactly 1 -ParameterFilter {
                        (&$MailAdminParams) -and
                        ($Message -like "*$ConfigurationJsonFile*Property 'SendMail.When' with value 'wrong' is not valid. Accepted values are 'Always', 'Never', 'OnlyOnError' or 'OnlyOnErrorOrAction'*")
                }
                Should -Invoke Write-EventLog -Exactly 1 -ParameterFilter {
                    $EntryType -eq 'Error'
                }
            }
            It 'Tasks.Name is not unique' {
                $testNewInputFile = Copy-ObjectHC $testInputFile
                $testNewInputFile.Tasks = @(
                    Copy-ObjectHC $testInputFile.Tasks[0]
                    Copy-ObjectHC $testInputFile.Tasks[0]
                )
                $testNewInputFile.Tasks[0].TaskName = 'Name1'
                $testNewInputFile.Tasks[1].TaskName = 'Name1'

                $testNewInputFile | ConvertTo-Json -Depth 7 |
                    Out-File @testOutParams

                .$testScript @testParams

                Should -Invoke Send-MailHC -Exactly 1 -ParameterFilter {
                        (&$MailAdminParams) -and
                        ($Message -like "*$ConfigurationJsonFile*Property 'Tasks.TaskName' with value 'Name1' is not unique*")
                }
            }
            It 'Tasks.Actions.Parameter.FileExtension does not start with a dot' {
                $testNewInputFile = Copy-ObjectHC $testInputFile
                $testNewInputFile.Tasks[0].Option.FileExtensions = @('txt', '.xml')

                $testNewInputFile | ConvertTo-Json -Depth 7 |
                    Out-File @testOutParams

                .$testScript @testParams

                Should -Invoke Send-MailHC -Exactly 1 -ParameterFilter {
                        (&$MailAdminParams) -and
                        ($Message -like "*$ConfigurationJsonFile*Property 'Tasks.Option.FileExtensions' needs to start with a dot. For example: '.txt', '.xml'*")
                }
            }
        }
        It 'the SFTP password is not found in the environment variables' {
            Mock Get-EnvironmentVariableValueHC {
                'user'
            } -ParameterFilter {
                $Name -eq $testInputFile.Tasks[0].Sftp.Credential.UserName
            }
            Mock Get-EnvironmentVariableValueHC -ParameterFilter {
                $Name -eq $testInputFile.Tasks[0].Sftp.Credential.Password
            }

            $testInputFile | ConvertTo-Json -Depth 7 |
                Out-File @testOutParams

            .$testScript @testParams

            Should -Invoke Send-MailHC -Exactly 1 -ParameterFilter {
                    (&$MailAdminParams) -and ($Message -like "*Environment variable '`$ENV:$($testInputFile.Tasks[0].Sftp.Credential.Password)' in 'Sftp.Credential.Password' not found*")
            }
            Should -Invoke Write-EventLog -Exactly 1 -ParameterFilter {
                $EntryType -eq 'Error'
            }
        }
        It 'the SFTP user name is not found in the environment variables' {
            Mock Get-EnvironmentVariableValueHC {
                'pass'
            } -ParameterFilter {
                $Name -eq $testInputFile.Tasks[0].Sftp.Credential.Password
            }
            Mock Get-EnvironmentVariableValueHC -ParameterFilter {
                $Name -eq $testInputFile.Tasks[0].Sftp.Credential.UserName
            }

            $testInputFile | ConvertTo-Json -Depth 7 |
                Out-File @testOutParams

            .$testScript @testParams

            Should -Invoke Send-MailHC -Exactly 1 -ParameterFilter {
                    (&$MailAdminParams) -and ($Message -like "*Environment variable '`$ENV:$($testInputFile.Tasks[0].Sftp.Credential.UserName)' in 'Sftp.Credential.UserName' not found*")
            }
            Should -Invoke Write-EventLog -Exactly 1 -ParameterFilter {
                $EntryType -eq 'Error'
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
                (-not $ArgumentList[4]) -and
                ($ArgumentList[5] -eq $testInputFile.Tasks[0].Option.FileExtensions) -and
                ($ArgumentList[6] -eq $testInputFile.Tasks[0].Option.OverwriteFile)
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
