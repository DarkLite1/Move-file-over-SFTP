#Requires -Modules Pester
#Requires -Modules Toolbox.EventLog, Toolbox.HTML
#Requires -Version 5.1

BeforeAll {
    $params = @{
        TypeName     = 'System.Management.Automation.PSCredential'
        ArgumentList = 'bob', ('pass' | ConvertTo-SecureString -AsPlainText -Force)
    }

    $testScript = $PSCommandPath.Replace('.download.Tests.ps1', '.ps1')
    $testParams = @{
        SftpComputerName           = 'PC1'
        SftpCredential             = New-Object @params
        Paths                      = @{
            Source      = 'sftp:/report/'
            Destination = (New-Item 'TestDrive:/f2' -ItemType 'Directory').FullName
        }
        MaxConcurrentJobs          = 1
        FileExtensions             = @()
        OverwriteFile              = $false
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
Describe 'When a file is found on the SFTP server' {
    BeforeAll {
        Remove-Item "$($testParams.Paths.Destination)/*" -Recurse

        Mock Get-SFTPChildItem {
            [PSCustomObject]@{
                Name        = 'b.txt'
                FullName    = '/report/b.txt'
                isDirectory = $false
            }
        }

        Mock Get-SFTPItem {
            $testNewItemParams = @{
                Path     = '{0}\sftpTransfer\download\b.txt' -f 
                $testParams.Paths.Destination
                ItemType = 'File'
            }
            New-Item @testNewItemParams
        }
    
        $testResult = .$testScript @testParams
    }
    It 'Get list of files on the SFTP server recursively' {
        Should -Invoke Get-SFTPChildItem -Times 1 -Exactly -Scope Describe -ParameterFilter {
            ($SessionId -eq 1) -and
            ($Path -eq '/report/') -and
            ($Recurse)
        }
    }
    It 'Create a temp folder on the SFTP server' {
        Should -Invoke New-SFTPItem -Times 1 -Exactly -Scope Describe -ParameterFilter {
            ($Path -eq '/report/sftpTransfer/download' ) -and
            ($ItemType -eq 'Directory') -and
            ($Recurse)
        }
    }
    It 'create a temp folder on the local file system' {
        $testJoinParams = @{
            Path      = $testParams.Paths.Destination 
            ChildPath = 'sftpTransfer/download' 
        }
        $testTempFolder = Join-Path @testJoinParams

        $testTempFolder | Should -Exist
    }
    It 'Move the file from the source to the temp folder on the SFTP server' {
        Should -Invoke Move-SFTPItem -Times 1 -Exactly -Scope Describe -ParameterFilter {
            ($SessionId -eq 1) -and
            ($Path -eq '/report/b.txt') -and
            ($Destination -eq '/report/sftpTransfer/download/b.txt' )
        }
    }
    It 'Download the file from the temp folder on the SFTP server to the temp folder on the local file system' {
        Should -Invoke Get-SFTPItem -Times 1 -Exactly -Scope Describe -ParameterFilter {
            ($SessionId -eq 1) -and
            ($Path -eq '/report/sftpTransfer/download/b.txt') -and
            ($Destination -eq "$($testParams.Paths.Destination)\sftpTransfer\download\b.txt" )
        }
    }
    It 'Move the file from the local temp folder to the destination folder on the local file system' {
        "$($testParams.Paths.Destination)\b.txt" | Should -Exist
    }
    It 'The file is no longer in the temp folder on the local file system' {
        '{0}\sftpTransfer\download\b.txt' -f 
        "$($testParams.Paths.Destination)\sftpTransfer\download\b.txt" | 
            Should -Not -Exist
    }
}
Describe 'Create an object with Error property when' {
    BeforeAll {
        Mock Get-SFTPChildItem {
            [PSCustomObject]@{
                Name        = 'b.txt'
                FullName    = '/report/b.txt'
                isDirectory = $false
            }
        }
    }
    It 'authentication to the SFTP server fails' {
        $testNewParams = Copy-ObjectHC $testParams
        $testNewParams.Paths = @(
            @{
                Source      = 'sftp:/data/'
                Destination = $testSource.Folder
            }
        )

        Mock New-SFTPSession {
            throw 'Failed authenticating'
        }

        $error.Clear()

        $testResult = .$testScript @testParams

        $testResult.Errors | Should -Be "Failed creating an SFTP session to '$($testNewParams.SftpComputerName)': Failed authenticating"

        $error | Should -HaveCount 0

        Should -Not -Invoke Get-SFTPItem
        Should -Not -Invoke Rename-SFTPFile
    }
    Context 'file list cannot be retrieved or SFTP path does not exist' {
        It 'Get-SFTPChildItem throws a terminating error' {
            $testNewParams = Copy-ObjectHC $testParams
            $testNewParams.Paths.Source = 'sftp:/notExisting/'

            Mock Get-SFTPChildItem {
                throw 'path not found'
            }

            $testResult = .$testScript @testNewParams

            $testResult.Errors |
                Should -Be "Failed retrieving the content of SFTP folder '/notExisting/'. Most likely the path does not exist on the SFTP server: path not found"

            Should -Not -Invoke Get-SFTPItem
            Should -Not -Invoke Rename-SFTPFile
        }
        It 'Get-SFTPChildItem creates a non terminating error' {
            $testNewParams = Copy-ObjectHC $testParams
            $testNewParams.Paths.Source = 'sftp:/notExisting/'

            Mock Get-SFTPChildItem {
                Write-Error 'path not found'
            }

            $testResult = .$testScript @testNewParams

            $testResult.Errors |
                Should -Be "Failed retrieving the content of SFTP folder '/notExisting/'. Most likely the path does not exist on the SFTP server: path not found"

            Should -Not -Invoke Get-SFTPItem
            Should -Not -Invoke Rename-SFTPFile
        }
    }
    It 'the download folder does not exist' {
        $testNewParams = Copy-ObjectHC $testParams
        $testNewParams.Paths.Destination = 'TestDrive:/notExisting/'

        $testResult = .$testScript @testNewParams

        $testResult.Errors |
            Should -BeLike "*Path 'TestDrive:/notExisting/' not found on the file system"

        Should -Not -Invoke Get-SFTPItem
        Should -Not -Invoke Rename-SFTPFile
    }
    Context 'Get-SFTPItem' {
        It 'creates a warning' {
            Mock Get-SFTPItem {
                # bug in CmdLet, dos not throw bu creates warning
                # throw 'Oops' 
                Write-Warning 'Oops'
            }

            $error.Clear()

            $testResult = .$testScript @testParams

            $testResult.Errors | Should -BeLike 'Failed to download file*Oops'

            $error | Should -HaveCount 0
        }
        It 'throws a terminating warning' {
            Mock Get-SFTPItem {
                # bug in CmdLet, dos not throw bu creates warning
                # throw 'Oops' 
                throw 'Oops'
            }

            $error.Clear()

            $testResult = .$testScript @testParams

            $testResult.Errors | Should -BeLike 'Failed to download file*Oops'

            $error | Should -HaveCount 0
        } 
    }
}
Describe 'When a duplicate file is in the destination folder and' {
    BeforeAll {
        Mock Get-SFTPChildItem {
            @{
                Name        = 'b.txt'
                FullName    = '/report/b.txt'
                isDirectory = $false
            }
        }

        $testNewParams = Copy-ObjectHC $testParams

        $testDuplicateFile = New-Item -Path "$($testNewParams.Paths.Destination)\b.txt" -ItemType 'File' -Force
    }
    Context 'OverWriteFile is false' {
        BeforeAll {
            $testNewParams.OverwriteFile = $false
            
            $testResult = .$testScript @testNewParams
        }
        It 'an error objects ic created' {
            $testResult.FileName | Should -Be 'b.txt'
            $testResult.Errors | Should -Be 'Duplicate file in destination folder, use OverwriteFile if desired'
        }
        It 'the download is not started' {
            Should -Not -Invoke Get-SFTPItem -Scope Context
        }
        It 'the duplicate file is left untouched' {
            $testDuplicateFile.FullName | Should -Exist
        }
    }
    Context 'OverWriteFile is true and destination file not in use' {
        BeforeAll {
            Mock Get-SFTPItem {
                $testNewItemParams = @{
                    Path     = '{0}\sftpTransfer\download\b.txt' -f 
                    $testParams.Paths.Destination
                    ItemType = 'File'
                }
                New-Item @testNewItemParams
            }

            $testNewParams.OverwriteFile = $true
            
            $testResult = .$testScript @testNewParams
        }
        It 'the download is started' {
            Should -Invoke Get-SFTPItem -Scope Context
        }
        It 'a success objects ic created' {
            $testResult.FileName | Should -Be 'b.txt'
            $testResult.Moved | Should -BeTrue
            $testResult.Errors | Should -BeNullOrEmpty
        }
        It 'the file is no longer in the temp folder on the local file system' {
            '{0}\sftpTransfer\download\b.txt' -f 
            $testParams.Paths.Destination | Should -Not -Exist
        }
    }
    Context 'OverWriteFile is true and destination file is in use' {
        BeforeAll {
            Mock Get-SFTPItem {
                $testNewItemParams = @{
                    Path     = '{0}\sftpTransfer\download\b.txt' -f 
                    $testParams.Paths.Destination
                    ItemType = 'File'
                }
                New-Item @testNewItemParams
            }

            Mock Remove-Item {
                throw 'The process cannot access the file because it is being used by another process'
            }

            $testNewParams.OverwriteFile = $true
            
            $testResult = .$testScript @testNewParams
        }
        It 'the download is started' {
            Should -Invoke Get-SFTPItem -Scope Context -Times 1 -Exactly
        }
        It 'an error object ic created' {
            $testResult.FileName | Should -Be 'b.txt'
            $testResult.Moved | Should -BeFalse
            $testResult.Errors | Should -BeLike 'Failed to remove duplicate file*The process cannot access the file because it is being used by another process'
        }
        It 'the file in the local temp folder stays in place' {
            "$($testNewParams.Paths.Destination)\sftpTransfer\download\b.txt" | 
                Should -Exist
        }
    }
}
Describe 'when the source file on the SFTP server is in use' {
    BeforeAll {
        Mock Get-SFTPChildItem {
            [PSCustomObject]@{
                Name        = 'b.txt'
                FullName    = '/report/b.txt'
                isDirectory = $false
            }
        }

        Mock Move-SFTPItem {
            throw 'oops'
        }

        $testResult = .$testScript @testParams
    }
    It 'the file cannot be moved to the SFTP temp folder' {
        Should -Invoke Move-SFTPItem -Times 1 -Exactly -Scope Describe -ParameterFilter {
            ($SessionId -eq 1) -and
            ($Path -eq '/report/b.txt') -and
            ($Destination -eq '/report/sftpTransfer/download/b.txt')
        }
    }
    It 'an error object is created' {
        $testResult.Errors | Should -Be "Failed moving file 'sftp:/report/b.txt' to 'sftp:/report/sftpTransfer/download/b.txt', file most likely in use by another process: oops"
    }
    It 'the download is not started' {
        Should -Not -Invoke Get-SFTPItem -Scope Describe
    }
}
Describe 'When there are no files on the SFTP server' {
    BeforeAll {
        Mock Get-SFTPChildItem 

        $testResult = .$testScript @testParams

    }
    It 'Get-SFTPChildItem is called to get the list of files' {
        Should -Invoke Get-SFTPChildItem -Scope Describe
    }
    It 'Other SFTP functions are not called' {
        @(
            'Get-SFTPItem',
            'Move-SFTPItem',
            'Rename-SFTPFile',
            'Test-SFTPPath'
        ).ForEach(
            { Should -Not -Invoke $_ -Scope Describe }
        )
    }
    It 'there is no output from the script' {
        $testResult | Should -BeNullOrEmpty
    }
}
Describe 'When a download fails' {
    BeforeAll {
        Mock Get-SFTPChildItem {
            [PSCustomObject]@{
                Name        = 'b.txt'
                FullName    = '/report/b.txt'
                isDirectory = $false
            }
        }

        Mock Get-SFTPItem {
            $testNewItemParams = @{
                Path     = '{0}\sftpTransfer\download\b.txt' -f 
                $testParams.Paths.Destination
                ItemType = 'File'
            }
            New-Item @testNewItemParams

            throw 'Oops'
        }
        
        $testResult = .$testScript @testParams
    }
    It 'the partially downloaded file is removed in the local temp folder' {
        "$($testParams.Paths.Destination)\sftpTransfer\download\b.txt" | 
            Should -Not -Exist
    }
    Context 'the moved file is still present in the SFTP temp folder because' {
        It 'the file was moved the SFTP temp folder' {
            Should -Invoke Move-SFTPItem -Times 1 -Exactly -Scope Describe -ParameterFilter {
            ($SessionId -eq 1) -and
            ($Path -eq '/report/b.txt') -and
            ($Destination -eq '/report/sftpTransfer/download/b.txt')
            }
        }
        It 'and the file was not deleted on the SFTP server' {
            Should -Not -Invoke Remove-SFTPItem -Scope Describe
        }
    }
    It 'an error object is created' {
        $testResult.Moved | Should -BeFalse
        $testResult.Errors | Should -BeLike "*Failed to download file 'sftp:/report/sftpTransfer/download/b.txt' to*\sftpTransfer\download\b.txt': Oops*"
    }
}
Describe 'Previously failed download' {
    Context 'when there is a file in the sftp temp folder because of file transfer issues' {
        BeforeAll {
            Mock Get-SFTPChildItem {
                [PSCustomObject]@{
                    Name        = 'b.txt'
                    FullName    = '/report/sftpTransfer/download/b.txt'
                    isDirectory = $false
                }
            }

            $testParams.OverwriteFile = $true

            $testResult = .$testScript @testParams
        }
        It 'the file is downloaded again' {
            Should -Invoke Get-SFTPItem -Times 1 -Exactly -Scope Context -ParameterFilter {
            ($SessionId -eq 1) -and
            ($Path -eq '/report/sftpTransfer/download/b.txt') -and
            ($Destination -eq "$($testParams.Paths.Destination)\sftpTransfer\download\b.txt" )
            }
        }
    }
    Context 'when there is a file in the local temp folder because of file in use in the destination folder' {
        BeforeAll {
            Mock Get-SFTPChildItem
            
            $testNewParams = Copy-ObjectHC $testParams
    
            New-Item -Path "$($testNewParams.Paths.Destination)\sftpTransfer\download" -ItemType Directory
    
            New-Item -Path "$($testNewParams.Paths.Destination)\sftpTransfer\download\b.txt" -ItemType File
    
            $testResult = .$testScript @testParams
        }
        It 'the file is moved to the destination folder' {
            "$($testNewParams.Paths.Destination)\b.txt" | 
                Should -Exist
        }
        It 'the file is no longer in the temp download folder' {
            "$($testNewParams.Paths.Destination)\sftpTransfer\download\b.txt" | 
                Should -Not -Exist
        }
        It 'a success object is created' {
            $testResult.Moved | Should -BeTrue
            $testResult.Actions | Should -Be 'moved previously downloaded file to destination folder, as the file in the destination folder was in use during the previous run'
            $testResult.Errors | Should -BeNullOrEmpty
        }
    }
}
