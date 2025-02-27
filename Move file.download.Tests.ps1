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

    $testLocalTempFolder = '{0}\sftpTransfer\download' -f 
    $testParams.Paths.Destination

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
            $null = New-Item @testNewItemParams
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
            ($Destination -eq '/report/sftpTransfer/download/b.txt' ) -and
            ($Force)
        }
    }
    It 'Download the file from the temp folder on the SFTP server to the temp folder on the local file system' {
        Should -Invoke Get-SFTPItem -Times 1 -Exactly -Scope Describe -ParameterFilter {
            ($SessionId -eq 1) -and
            ($Path -eq '/report/sftpTransfer/download/b.txt') -and
            ($Destination -eq "$($testParams.Paths.Destination)\sftpTransfer\download" ) -and
            ($Force)
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
                $testResult.Actions | Should -HaveCount 4
            }
            It '<_>' -ForEach @(
                'file moved to SFTP temp folder',
                'downloaded to local temp folder',
                'removed file in SFTP temp folder',
                'temp file moved to destination folder'
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
Describe 'When a duplicate file' {
    Describe 'is in the sftp source folder and in the destination folder and' {
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
                It 'Actions' {
                    $testResult.Actions | Should -HaveCount 0
                }
                It 'Moved' {
                    $testResult.Moved | Should -BeFalse
                }
                Context 'Errors' {
                    It '<_>' -ForEach @(
                        'Duplicate file in destination folder, use OverwriteFile if needed'
                    ) {
                        $testResult.Errors | Should -Contain $_
                    }
                }
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
                    $null = New-Item @testNewItemParams
                }

                $testNewParams.OverwriteFile = $true
            
                $testResult = .$testScript @testNewParams
            }
            It 'the download is started' {
                Should -Invoke Get-SFTPItem -Scope Context
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
                        $testResult.Actions | Should -HaveCount 5
                    }
                    It '<_>' -ForEach @(
                        'file moved to SFTP temp folder',
                        'downloaded to local temp folder',
                        'removed file in SFTP temp folder',
                        'removed duplicate file in destination folder',
                        'temp file moved to destination folder'
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
                    $null = New-Item @testNewItemParams
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
            It 'an error object is created' {
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
    Describe 'is in the sftp source and sftp temp folder and' {
        Describe 'there is no destination file with the same name' {
            BeforeAll {
                Mock Get-SFTPChildItem {
                    [PSCustomObject]@{
                        Name        = 'b.txt'
                        FullName    = '/report/b.txt'
                        isDirectory = $false
                    }
                    [PSCustomObject]@{
                        Name        = 'b.txt'
                        FullName    = '/report/sftpTransfer/download/b.txt'
                        isDirectory = $false
                    }
                }
            }
            Context 'OverWriteFile is false' {
                BeforeAll {
                    $testParams.OverwriteFile = $false
            
                    $testResult = .$testScript @testParams
                }
                It 'the temp sftp file is downloaded again, because it failed previously' {
                    Should -Invoke Get-SFTPItem -Times 1 -Exactly -Scope Context -ParameterFilter {
                        ($SessionId -eq 1) -and
                        ($Path -eq '/report/sftpTransfer/download/b.txt') -and
                        ($Destination -eq "$($testParams.Paths.Destination)\sftpTransfer\download" )
                    }
                }
                It 'the new sftp source file is not downloaded' {
                    Should -Not -Invoke Move-SFTPItem -Scope Context -ParameterFilter {
                        ($Path -eq '/report/b.txt') 
                    }
                    Should -Not -Invoke Get-SFTPItem -Scope Context -ParameterFilter {
                        ($Path -eq '/report/b.txt') 
                    }
                }
                Context 'a success object is returned' {
                    BeforeAll {
                        $testResult = $testResult | Where-Object {
                            $_.Source -eq $testLocalTempFolder
                        }
                    }
                    It 'only one object' {
                        $testResult | Should -HaveCount 1
                    }
                    It 'Source' {
                        $testResult.Source | Should -Be $testLocalTempFolder
                    }
                    It 'Destination' {
                        $testResult.Destination | 
                            Should -Be $testParams.Paths.Destination
                    }
                    It 'FileName' {
                        $testResult.FileName | Should -Be 'b.txt'
                    }
                    It 'Moved' {
                        $testResult.Moved | Should -BeTrue
                    }
                    It 'Errors' {
                        $testResult.Errors | Should -BeNullOrEmpty
                    }
                    It 'Actions' {
                        $testActions = @(
                            'moved previously downloaded file to destination folder, as the file in the destination folder was in use during the previous run'
                        )
                            
                        $testActions | ForEach-Object {
                            $testResult.Actions | Should -Contain $_
                        }
    
                        $testResult.Actions | 
                            Should -HaveCount $testActions.Count
                    }
                }
            }
            Context 'OverWriteFile is true' {
                BeforeAll {
                    Mock Move-Item

                    $testNewParams.OverwriteFile = $true
            
                    $testResult = .$testScript @testNewParams
                }
                It 'the file in the sftp temp folder is overwritten' {
                    Should -Invoke Move-SFTPItem -Times 1 -Exactly -Scope Context -ParameterFilter {
                    ($SessionId -eq 1) -and
                    ($Path -eq '/report/b.txt') -and
                    ($Destination -eq '/report/sftpTransfer/download/b.txt')
                    }
                }
                It 'the new file is downloaded' {
                    Should -Invoke Get-SFTPItem -Times 1 -Exactly -Scope Context -ParameterFilter {
                    ($SessionId -eq 1) -and
                    ($Path -eq '/report/sftpTransfer/download/b.txt') -and
                    ($Destination -eq "$($testParams.Paths.Destination)\sftpTransfer\download" )
                    }
                }
                It 'a single success object is created' {
                    $testResult | Should -HaveCount 1
                    $testResult.FileName | Should -Be 'b.txt'
                    $testResult.Errors | Should -BeNullOrEmpty
                    $testResult.Actions | Should -Contain 'overwritten duplicate file in SFTP temp folder'
                }
            }
        }
        Describe 'there is a destination file with the same name' {
            BeforeAll {
                Mock Get-SFTPChildItem {
                    [PSCustomObject]@{
                        Name        = 'b.txt'
                        FullName    = '/report/b.txt'
                        isDirectory = $false
                    }
                    [PSCustomObject]@{
                        Name        = 'b.txt'
                        FullName    = '/report/sftpTransfer/download/b.txt'
                        isDirectory = $false
                    }
                }

                $testNewParams = Copy-ObjectHC $testParams
            }
            Context 'OverWriteFile is false' {
                BeforeAll {
                    $testNewParams.OverwriteFile = $false
            
                    $testResult = .$testScript @testNewParams
                }
                It 'the download is not started' {
                    Should -Not -Invoke Get-SFTPItem -Scope Context
                }
                It 'an single error object is created' {
                    $testResult | Should -HaveCount 1
                    $testResult.FileName | Should -Be 'b.txt'
                    $testResult.Errors | Should -BeLike 'Duplicate file in the sftp temp folder*use OverwriteFile if desired'
                }
            }
            Context 'OverWriteFile is true' {
                BeforeAll {
                    Mock Move-Item

                    $testNewParams.OverwriteFile = $true
            
                    $testResult = .$testScript @testNewParams
                }
                It 'the file in the sftp temp folder is overwritten' {
                    Should -Invoke Move-SFTPItem -Times 1 -Exactly -Scope Context -ParameterFilter {
                    ($SessionId -eq 1) -and
                    ($Path -eq '/report/b.txt') -and
                    ($Destination -eq '/report/sftpTransfer/download/b.txt')
                    }
                }
                It 'the new file is downloaded' {
                    Should -Invoke Get-SFTPItem -Times 1 -Exactly -Scope Context -ParameterFilter {
                    ($SessionId -eq 1) -and
                    ($Path -eq '/report/sftpTransfer/download/b.txt') -and
                    ($Destination -eq "$($testParams.Paths.Destination)\sftpTransfer\download" )
                    }
                }
                It 'a single success object is created' {
                    $testResult | Should -HaveCount 1
                    $testResult.FileName | Should -Be 'b.txt'
                    $testResult.Errors | Should -BeNullOrEmpty
                    $testResult.Actions | Should -Contain 'overwritten duplicate file in SFTP temp folder'
                }
            }
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
            $null = New-Item @testNewItemParams

            throw 'Oops'
        }
        
        $testResult = .$testScript @testParams
    }
    It 'the partially downloaded file is removed in the local temp folder' {
        "$($testParams.Paths.Destination)\sftpTransfer\download\b.txt" | 
            Should -Not -Exist
    }
    It 'the destination folder is left untouched' {
        $testParams.Paths.Destination | Should -Exist
    }
    Context 'the moved file is still present in the SFTP temp folder because' {
        It 'the file was moved from the SFTP source folder to the SFTP temp folder' {
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
    Context 'when there is a file in the sftp temp folder because of file transfer issues during the previous run' {
        BeforeAll {
            Mock Get-SFTPChildItem {
                [PSCustomObject]@{
                    Name        = 'b.txt'
                    FullName    = '/report/sftpTransfer/download/b.txt'
                    isDirectory = $false
                }
            }

            Mock Get-SFTPItem {
                $testNewItemParams = @{
                    Path     = '{0}\sftpTransfer\download\b.txt' -f 
                    $testParams.Paths.Destination
                    ItemType = 'File'
                }
                $null = New-Item @testNewItemParams
            }

            $testParams.OverwriteFile = $true

            $testResult = .$testScript @testParams
        }
        It 'the file is downloaded again' {
            Should -Invoke Get-SFTPItem -Times 1 -Exactly -Scope Context -ParameterFilter {
            ($SessionId -eq 1) -and
            ($Path -eq '/report/sftpTransfer/download/b.txt') -and
            ($Destination -eq "$($testParams.Paths.Destination)\sftpTransfer\download" )
            }
        }
        It 'a single success object is created' {
            $testResult | Should -HaveCount 1
            $testResult.FileName | Should -Be 'b.txt'
            $testResult.Errors | Should -BeNullOrEmpty
            $testResult.Actions | Should -Contain 'file not moved from the SFTP source folder to the SFTP temp folder as it was already in the SFTP temp SFTP folder due to a previously failed download'
        }
    }
    Context 'when there is a file in the local temp folder because the file in the destination folder was in use by another process ' {
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
            $testResult.Actions | Should -Contain 'moved previously downloaded file to destination folder, as the file in the destination folder was in use during the previous run'
            $testResult.Errors | Should -BeNullOrEmpty
        }
    }
}
Describe 'When a file is locked' {
    BeforeAll {
        function Lock-FileHC {
            <# 
                .SYNOPSIS
                    Lock a file
        
                .EXAMPLE
                    $file = 'C:\file.txt'
        
                    # lock a file
                    $lockedFile = Lock-FileHC -Path $file
        
                    # unlock a file
                    Unlock-FileHC -LockedFile $lockedFile -Verbose
            #>
            Param (
                [Parameter(Mandatory)]
                [ValidateScript({ Test-Path -Path $_ -PathType Leaf })]
                [string]$Path
            )
        
            try {
                Write-Verbose "Lock file '$Path'"
                [System.io.File]::Open($Path, 'Open', 'Read', 'None')
            }
            catch {
                throw "Failed to lock file '$Path': $_"
            }
        }
        
        function Unlock-FileHC {
            <# 
                .SYNOPSIS
                    Unlock a file
        
                .EXAMPLE
                    $file = 'C:\file.txt'
        
                    # lock a file
                    $lockedFile = Lock-FileHC -Path $file
        
                    # unlock a file
                    Unlock-FileHC -LockedFile $lockedFile -Verbose
            #>
            Param (
                [Parameter(Mandatory)]
                [System.IO.FileStream]$LockedFile
            )
        
            try {
                Write-Verbose "Unlock file '$LockedFile'"
                $LockedFile.Close()
            }
            catch {
                throw "Failed to unlock file: $_"
            }
        }
    }
    Context 'in the sftp source folder' {
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
            Should -Invoke Move-SFTPItem -Times 1 -Exactly -Scope Context -ParameterFilter {
                ($SessionId -eq 1) -and
                ($Path -eq '/report/b.txt') -and
                ($Destination -eq '/report/sftpTransfer/download/b.txt')
            }
        }
        It 'an error object is created' {
            $testResult.Errors | Should -Be "Failed moving file 'sftp:/report/b.txt' to 'sftp:/report/sftpTransfer/download/b.txt', file most likely in use by another process: oops"
        }
        It 'the download is not started' {
            Should -Not -Invoke Get-SFTPItem -Scope Context
        }
    }
    Context 'in the destination folder' {
        BeforeAll {
            $testFile = @{
                localTempPath   = '{0}\b.txt' -f $testLocalTempFolder
                destinationPath = '{0}\b.txt' -f $testParams.Paths.Destination
            }
        }
        Context 'on the first run' {
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
                        Path     = $testFile.localTempPath
                        ItemType = 'File'
                    }
                    $null = New-Item @testNewItemParams
                }
    
                $testNewItemParams = @{
                    Path     = $testFile.destinationPath
                    ItemType = 'File'
                }
                $null = New-Item @testNewItemParams
    
                $testLockedFile = Lock-FileHC -Path $testFile.destinationPath
    
                $testParams.OverwriteFile = $true
    
                $testResult = .$testScript @testParams
    
                Unlock-FileHC -LockedFile $testLockedFile
            }
            It 'the destination file could not be removed' {
                $testFile.destinationPath | Should -Exist
            }
            It 'the downloaded file is left in the local temp folder' {
                $testFile.localTempPath | Should -Exist
            }
            Context 'an error object is created with property' {
                It 'Source' {
                    $testResult.Source | Should -Be 'sftp:/report/'
                }
                It 'Destination' {
                    $testResult.Destination | 
                        Should -Be $testParams.Paths.Destination
                }
                It 'FileName' {
                    $testResult.FileName | Should -Be 'b.txt'
                }
                It 'Moved' {
                    $testResult.Moved | Should -BeFalse
                }
                It 'Errors' {
                    $testResult.Errors | Should -BeLike "Failed to remove duplicate file '*\f2\b.txt': The process cannot access the file '*\f2\b.txt' because it is being used by another process."
                }
                It 'Actions' {
                    $testActions = @(
                        'file moved to SFTP temp folder',
                        'downloaded to local temp folder',
                        'removed file in SFTP temp folder'
                    )
                        
                    $testActions | ForEach-Object {
                        $testResult.Actions | Should -Contain $_
                    }

                    $testResult.Actions | Should -HaveCount $testActions.Count
                }
            }
        }
        Context 'on the second run when the file is unlocked and' {
            Context 'there is no temp local file' {
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
                            Path     = $testFile.localTempPath
                            ItemType = 'File'
                        }
                        $null = New-Item @testNewItemParams
                    }

                    $testNewItemParams = @{
                        Path     = $testFile.destinationPath
                        ItemType = 'File'
                    }
                    $null = New-Item @testNewItemParams
    
                    $testParams.OverwriteFile = $true
    
                    $testResult = .$testScript @testParams
                }
                It 'the downloaded file is in the local temp folder is removed' {
                    $testFile.localTempPath | Should -Not -Exist
                }
                It 'the destination file is overwritten' {
                    $testFile.destinationPath | Should -Exist
                }
                Context 'a success object is created with property' {
                    It 'Source' {
                        $testResult.Source | Should -Be 'sftp:/report/'
                    }
                    It 'Destination' {
                        $testResult.Destination | 
                            Should -Be $testParams.Paths.Destination
                    }
                    It 'FileName' {
                        $testResult.FileName | Should -Be 'b.txt'
                    }
                    It 'Moved' {
                        $testResult.Moved | Should -BeTrue
                    }
                    It 'Errors' {
                        $testResult.Errors | Should -BeNullOrEmpty
                    }
                    It 'Actions' {
                        $testActions = @(
                            'file moved to SFTP temp folder',
                            'downloaded to local temp folder',
                            'removed file in SFTP temp folder',
                            'removed duplicate file in destination folder',
                            'temp file moved to destination folder'
                        )
                        
                        $testActions | ForEach-Object {
                            $testResult.Actions | Should -Contain $_
                        }

                        $testResult.Actions | Should -HaveCount $testActions.Count
                    }
                }
            }
            Context 'there is a temp local file' {
                BeforeAll {
                    Remove-Item "$($testParams.Paths.Destination)/*" -Recurse

                    Mock Get-SFTPChildItem {
                        [PSCustomObject]@{
                            Name        = 'b.txt'
                            FullName    = '/report/b.txt'
                            isDirectory = $false
                        }
                    }
    
                    Mock Get-SFTPItem 
    
                    #region Create destination and local temp file
                    $testNewItemParams = @{
                        Path     = $testLocalTempFolder
                        ItemType = 'Directory'
                        Force    = $true
                    }
                    $null = New-Item @testNewItemParams

                    $testNewItemParams = @{
                        Path     = $testFile.destinationPath
                        ItemType = 'File'
                    }
                    $null = New-Item @testNewItemParams

                    $testNewItemParams = @{
                        Path     = $testFile.localTempPath
                        ItemType = 'File'
                    }
                    $null = New-Item @testNewItemParams
                    #endregion
    
                    $testParams.OverwriteFile = $true
    
                    $testResult = .$testScript @testParams
                }
                It 'the local temp file is moved to the destination folder' {
                    $testFile.localTempPath | Should -Not -Exist
                    $testFile.destinationPath | Should -Exist
                }
                It 'the local temp folder is empty' {
                    Get-ChildItem $testLocalTempFolder | Should -BeNullOrEmpty
                }
                It 'the new sftp source file is not downloaded, that happens next run' {
                    Should -Not -Invoke Get-SFTPItem -Scope Context
                    Should -Not -Invoke Remove-SFTPItem -Scope Context
                }
                It 'a single success object is returned' {
                    $testResult | Should -HaveCount 1
                }
                Context '1 object for the previously downloaded file' {
                    BeforeAll {
                        $testResult = $testResult | Where-Object {
                            $_.Source -eq $testLocalTempFolder
                        }
                    }
                    It 'Source' {
                        $testResult.Source | Should -Be $testLocalTempFolder
                    }
                    It 'Destination' {
                        $testResult.Destination | 
                            Should -Be $testParams.Paths.Destination
                    }
                    It 'FileName' {
                        $testResult.FileName | Should -Be 'b.txt'
                    }
                    It 'Moved' {
                        $testResult.Moved | Should -BeTrue
                    }
                    It 'Errors' {
                        $testResult.Errors | Should -BeNullOrEmpty
                    }
                    It 'Actions' {
                        $testActions = @(
                            'moved previously downloaded file to destination folder, as the file in the destination folder was in use during the previous run'
                        )
                            
                        $testActions | ForEach-Object {
                            $testResult.Actions | Should -Contain $_
                        }
    
                        $testResult.Actions | 
                            Should -HaveCount $testActions.Count
                    }
                }
            }
        }
    }
}