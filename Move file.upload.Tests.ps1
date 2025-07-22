#Requires -Modules Pester
#Requires -Version 7

BeforeAll {
    $params = @{
        TypeName     = 'System.Management.Automation.PSCredential'
        ArgumentList = 'bob', ('pass' | ConvertTo-SecureString -AsPlainText -Force)
    }

    $testScript = $PSCommandPath.Replace('.upload.Tests.ps1', '.ps1')
    $testParams = @{
        SftpComputerName           = 'PC1'
        SftpCredential             = New-Object @params
        Paths                      = @{
            Source      = (New-Item 'TestDrive:/f1' -ItemType 'Directory').FullName
            Destination = 'sftp:/report/'
        }
        MaxConcurrentActions       = 1
        SftpPort                   = 22
        MatchFileNameRegex         = '.*'
        OverwriteFile              = $false
        ExcludeZeroSizeFile        = $false
        AttemptCount               = 1
        WaitSecondsBetweenAttempts = 1
    }

    Mock Get-SFTPChildItem
    Mock Set-SFTPItem
    Mock Get-SFTPItem
    Mock New-SFTPItem
    Mock Move-SFTPItem
    Mock Rename-SFTPFile
    Mock Remove-SFTPItem
    Mock Remove-SFTPSession
    Mock Test-SFTPPath
    Mock New-SFTPSession {
        [PSCustomObject]@{
            SessionID = 1
        }
    }
}
Describe 'when there is no file in the source folder' {
    BeforeAll {
        $testResult = .$testScript @testParams
    }
    it 'no SFTP sessions is started' {
        Should -Not -Invoke New-SFTPSession -Scope Describe
    }
    It 'no object is returned' {
        $testResult | Should -BeNullOrEmpty
    }
}
Describe 'When a file is found in the source folder' {
    BeforeAll {
        $testNewItemParams = @{
            Path     = $testParams.Paths.Source
            Name     = 'b.txt'
            ItemType = 'File'
        }
        New-Item @testNewItemParams

        $testResult = .$testScript @testParams
    }
    It 'Get list of files on the SFTP server recursively' {
        Should -Invoke Get-SFTPChildItem -Times 1 -Exactly -Scope Describe -ParameterFilter {
            ($SessionId -eq 1) -and
            ($Path -eq '/report/') -and
            ($Recurse)
        }
    }
    It 'upload file from local temp folder to SFTP temp folder' {
        Should -Invoke Set-SFTPItem -Times 1 -Exactly -Scope Describe -ParameterFilter {
            ($SessionId -eq 1) -and
            ($Path -eq "$($testParams.Paths.Source)\sftpTransfer\upload\b.txt") -and
            ($Destination -eq '/report/sftpTransfer/upload') -and
            ($Force)
        }
    }
    It 'move file from SFTP temp folder to SFTP destination folder' {
        Should -Invoke Move-SFTPItem -Times 1 -Exactly -Scope Describe -ParameterFilter {
            ($SessionId -eq 1) -and
            ($Path -eq '/report/sftpTransfer/upload/b.txt') -and
            ($Destination -eq '/report/b.txt')
        }
    }
    It 'remove file in local source folder' {
        "$($testParams.Paths.Source)\sftpTransfer\upload\b.txt" |
        Should -Not -Exist
    }
    Context 'a success object is created with property' {
        It 'DateTime' {
            $testResult.DateTime | Should -Not -BeNullOrEmpty
        }
        It 'Source' {
            $testResult.Source | Should -Be $testParams.Paths.Source
        }
        It 'Destination' {
            $testResult.Destination | Should -Be $testParams.Paths.Destination
        }
        It 'FileName' {
            $testResult.FileName | Should -Be 'b.txt'
        }
        Context 'Actions' {
            It 'returns 4 strings:' {
                $testResult.Actions.Count | Should -Be 4
            }
            It '<_>' -ForEach @(
                'moved file from local source folder to local temp folder',
                'uploaded file from local temp folder to SFTP temp folder',
                'moved file from SFTP temp folder to SFTP destination folder',
                'removed file in local temp folder'
            ) {
                $testResult.Actions | Should -Contain $_
            }
        }
        It 'Moved' {
            $testResult.Moved | Should -BeTrue
        }
        It 'Errors' {
            $testResult.Errors | Should -BeNullOrEmpty
        }
    }
}
Describe 'when a file is' {
    Context 'in the destination folder and OverwriteFile is false' {
        BeforeAll {
            Mock Get-SFTPChildItem {
                @{
                    Name        = 'b.txt'
                    FullName    = '/report/b.txt'
                    isDirectory = $false
                }
            }

            $testNewItemParams = @{
                Path     = $testParams.Paths.Source
                Name     = 'b.txt'
                ItemType = 'File'
            }
            New-Item @testNewItemParams

            $testParams.OverwriteFile = $false

            $testResult = .$testScript @testParams
        }
        It 'the upload is not started' {
            Should -Not -Invoke Set-SFTPItem -Scope Context
        }
        Context 'an error object is created with property' {
            It 'DateTime' {
                $testResult.DateTime | Should -Not -BeNullOrEmpty
            }
            It 'Source' {
                $testResult.Source | Should -Be $testParams.Paths.Source
            }
            It 'Destination' {
                $testResult.Destination | Should -Be $testParams.Paths.Destination
            }
            It 'FileName' {
                $testResult.FileName | Should -Be 'b.txt'
            }
            Context 'Actions' {
                It 'returns 0 strings:' {
                    $testResult.Actions.Count | Should -Be 0
                }
            }
            It 'Moved' {
                $testResult.Moved | Should -BeFalse
            }
            Context 'Errors' {
                It 'returns 1 string' {
                    $testResult.Errors.count | Should -Be 1
                }
                It '<_>' -ForEach @(
                    'Duplicate file in destination folder, use OverwriteFile if needed'
                ) {
                    $testResult.Errors | Should -Be $_
                }
            }
        }
    }
    Context 'in the destination folder and OverwriteFile is true' {
        BeforeAll {
            Mock Get-SFTPChildItem {
                @{
                    Name        = 'b.txt'
                    FullName    = '/report/b.txt'
                    isDirectory = $false
                }
            }

            $testNewItemParams = @{
                Path     = $testParams.Paths.Source
                Name     = 'b.txt'
                ItemType = 'File'
            }
            New-Item @testNewItemParams

            $testParams.OverwriteFile = $true

            $testResult = .$testScript @testParams
        }
        It 'the upload is started' {
            Should -Invoke Set-SFTPItem -Times 1 -Exactly -Scope Context -ParameterFilter {
                ($SessionId -eq 1) -and
                ($Path -eq "$($testParams.Paths.Source)\sftpTransfer\upload\b.txt") -and
                ($Destination -eq '/report/sftpTransfer/upload') -and
                ($Force)
            }
        }
        Context 'a success object is created with property' {
            It 'DateTime' {
                $testResult.DateTime | Should -Not -BeNullOrEmpty
            }
            It 'Source' {
                $testResult.Source | Should -Be $testParams.Paths.Source
            }
            It 'Destination' {
                $testResult.Destination | Should -Be $testParams.Paths.Destination
            }
            It 'FileName' {
                $testResult.FileName | Should -Be 'b.txt'
            }
            Context 'Actions' {
                It 'returns 5 strings:' {
                    $testResult.Actions.Count | Should -Be 5
                }
                It '<_>' -ForEach @(
                    'moved file from local source folder to local temp folder', 'uploaded file from local temp folder to SFTP temp folder',
                    "removed duplicate file 'SFTP:/report/b.txt'",
                    'moved file from SFTP temp folder to SFTP destination folder',
                    'removed file in local temp folder'
                ) {
                    $testResult.Actions | Should -Contain $_
                }
            }
            It 'Moved' {
                $testResult.Moved | Should -BeTrue
            }
            Context 'Errors' {
                It 'returns 0 string' {
                    $testResult.Errors.Count | Should -Be 0
                }
            }
        }
    }
}
Describe 'When ExcludeZeroSizeFile is TRUE' {
    BeforeAll {
        $testParams.ExcludeZeroSizeFile = $true

        $testNewItemParams = @{
            Path     = $testParams.Paths.Source
            Name     = 'b.txt'
            ItemType = 'File'
        }
        $testFile = New-Item @testNewItemParams

        $testResult = .$testScript @testParams
    }
    It 'the file is not moved to the local temp folder' {
        $testFile | Should -Exist
    }
    It 'the upload is not started' {
        Should -Not -Invoke Set-SFTPItem -Scope Describe
        Should -Not -Invoke Move-SFTPItem -Scope Describe
    }
    Context 'a success object is created with property' {
        It 'DateTime' {
            $testResult.DateTime | Should -Not -BeNullOrEmpty
        }
        It 'Source' {
            $testResult.Source | Should -Be $testParams.Paths.Source
        }
        It 'Destination' {
            $testResult.Destination | Should -Be $testParams.Paths.Destination
        }
        It 'FileName' {
            $testResult.FileName | Should -Be 'b.txt'
        }
        Context 'Actions' {
            It 'returns 1 string:' {
                $testResult.Actions.Count | Should -Be 1
            }
            It '<_>' -ForEach @(
                "file size 0 bytes, file not moved, option 'ExcludeZeroSizeFile' enabled"
            ) {
                $testResult.Actions | Should -Contain $_
            }
        }
        It 'Moved' {
            $testResult.Moved | Should -BeFalse
        }
        It 'Errors' {
            $testResult.Errors | Should -BeNullOrEmpty
        }
    }
}