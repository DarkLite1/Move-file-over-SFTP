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

        $testResult.Error | Should -Be "Failed creating an SFTP session to '$($testNewParams.SftpComputerName)': Failed authenticating"

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

            $testResult.Error |
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

            $testResult.Error |
                Should -Be "Failed retrieving the content of SFTP folder '/notExisting/'. Most likely the path does not exist on the SFTP server: path not found"

            Should -Not -Invoke Get-SFTPItem
            Should -Not -Invoke Rename-SFTPFile
        }
    }
    It 'the download folder does not exist' {
        $testNewParams = Copy-ObjectHC $testParams
        $testNewParams.Paths.Destination = 'TestDrive:/notExisting/'

        $testResult = .$testScript @testNewParams

        $testResult.Error |
            Should -BeLike "*Path 'TestDrive:/notExisting/' not found on the file system"

        Should -Not -Invoke Get-SFTPItem
        Should -Not -Invoke Rename-SFTPFile
    }
    Context 'the file download fails' {
        It 'Get-SFTPItem creates a warning' {
            Mock Get-SFTPItem {
                # bug in CmdLet, dos not throw bu creates warning
                # throw 'Oops' 
                Write-Warning 'Oops'
            }

            $error.Clear()

            $testResult = .$testScript @testParams

            $testResult.Error | Should -BeLike 'Failed to download file*Oops'

            $error | Should -HaveCount 0
        }
        It 'Get-SFTPItem throws a terminating warning' {
            Mock Get-SFTPItem {
                # bug in CmdLet, dos not throw bu creates warning
                # throw 'Oops' 
                throw 'Oops'
            }

            $error.Clear()

            $testResult = .$testScript @testParams

            $testResult.Error | Should -BeLike 'Failed to download file*Oops'

            $error | Should -HaveCount 0
        } 
    }
    It 'a duplicate file is in the destination folder and OverWriteFile is false' {
        Mock Get-SFTPChildItem {
            @{
                Name        = 'b.txt'
                FullName    = '/report/b.txt'
                isDirectory = $false
            }
        }

        $testNewParams = Copy-ObjectHC $testParams
        $testNewParams.OverwriteFile = $false

        @(
            "$($testNewParams.Paths.Destination)\b.txt"
        ).ForEach(
            { New-Item -Path $_ -ItemType 'File' }
        )

        $testResult = .$testScript @testNewParams

        $testResult.FileName | Should -Be 'b.txt'
        $testResult.Error | Should -Be 'Duplicate file in destination folder, use OverwriteFile if desired'

        Should -Not -Invoke Get-SFTPItem
        Should -Not -Invoke Rename-SFTPFile
    }
}
Describe 'when a file is in use by another process on the SFTP server' {
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
    Context 'it cannot be moved to the temp folder on the sftp server and' {
        It 'an error object is created' {
            $testResult.Error | Should -Be "Failed moving file 'sftp:/report/b.txt' to 'sftp:/report/sftpTransfer/download/b.txt', file most likely in use by another process: oops"
        }
        It 'the download is not started' {
            Should -Not -Invoke Get-SFTPItem -Scope Describe
        }
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
    It 'Get list of files on the SFTP server' {
        Should -Invoke Get-SFTPChildItem -Times 1 -Exactly -Scope Describe
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
} -Tag test