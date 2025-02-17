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
        $testFiles = @(
            @{
                Name        = 'b.txt'
                FullName    = '/report/b.txt'
                isDirectory = $false
            }
        )
        Mock Get-SFTPChildItem {
            $testFiles
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

            $testResult.Error | Should -BeLike '*Oops'

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

            $testResult.Error | Should -BeLike '*Oops'

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
            @{
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
        $testTempFileInDestinationFolder = '{0}\sftpTransfer\download\b.txt' -f $testParams.Paths.Destination

        Should -Invoke Get-SFTPItem -Times 1 -Exactly -Scope Describe -ParameterFilter {
            ($SessionId -eq 1) -and
            ($Path -eq '/report/sftpTransfer/download/b.txt') -and
            ($Destination -eq $testTempFileInDestinationFolder )
        }
        
        $testTempFileInDestinationFolder | Should -Exist   
    }
} -Tag test
Describe 'When files are found on the SFTP server' {
    BeforeAll {
        $testNewParams = Copy-ObjectHC $testParams
        $testNewParams.Paths = @(
            @{
                Source      = 'sftp:/data/'
                Destination = (New-Item 'TestDrive:/ll' -ItemType 'Directory').FullName
            }
        )

        $destinationFolder = $testNewParams.Destination.FullName

        $testDataOnSftpServer = @(
            @{
                Name        = 'z.txt' 
                FullName    = '/sftpTransfer/download/z.txt' 
                IsDirectory = $false
            }
            @{
                Name        = 'a.txt' 
                FullName    = '/data/a.txt' 
                IsDirectory = $false
            }
        )

        $testDataLocal = @(
            @{
                Name        = 'a.txt' 
                Directory   = $destinationFolder
                IsDirectory = $false
            }
        )

        Mock Get-SFTPItem {
            $null = New-Item -Path $testNewParams.Paths.Destination -Name 'a.txt' -ItemType 'File'
        } -ParameterFilter {
                ($Path -eq '/data/a.txt') -and
                ($Destination -eq $testNewParams.Paths.Destination)
        }

        Mock Get-SFTPItem {
            $null = New-Item -Path $testNewParams.Paths.Destination -Name 'b.txt' -ItemType 'File'
        } -ParameterFilter {
                ($Path -eq '/data/b.txt') -and
                ($Destination -eq $testNewParams.Paths.Destination)
        }

        Mock Get-SFTPItem {
            $null = New-Item -Path $testNewParams.Paths.Destination -Name 'c.txt' -ItemType 'File'
        } -ParameterFilter {
                ($Path -eq '/data/d.txt') -and
                ($Destination -eq $testNewParams.Paths.Destination)
        }

        $testIncompleteFile = New-Item -Path $testNewParams.Paths.Destination -Name 'k.txt' -ItemType 'File'

        $testCompleteFile = New-Item -Path $testNewParams.Paths.Destination -Name 'y.txt' -ItemType 'File'

        $testResults = .$testScript @testNewParams
    }
    It 'incomplete downloaded files are removed from the download folder' {
        $testIncompleteFile | Should -Not -Exist
    }
    It 'fully downloaded files in the download folder are left untouched' {
        $testCompleteFile | Should -Exist
    }
    It 'call Get-SFTPItem to download all temp file' {
        $testFiles[0..1] | ForEach-Object {
            Should -Invoke Get-SFTPItem -Times 1 -Exactly -Scope Describe -ParameterFilter {
                    ($Path -eq $_.FullName) -and
                    ($Destination -eq $testNewParams.Paths.Destination) -and
                    ($SessionId -eq 1)
            }
        }
        $testFiles[2] | ForEach-Object {
            Should -Invoke Get-SFTPItem -Times 1 -Exactly -Scope Context -ParameterFilter {
                    ($Path -eq $_.FullName) -and
                    ($Destination -eq $testNewParams.Paths.Destination) -and
                    ($SessionId -eq 1)
            }
        }
    }
    It 'remove temp file on the SFTP server' {
        Should -Invoke Remove-SFTPItem -Times 3 -Exactly -Scope Context

        $testFiles[0.1].FullName | ForEach-Object {
            Should -Invoke Remove-SFTPItem -Times 1 -Exactly -Scope Context -ParameterFilter {
                $Path -eq "$_"
            }
        }
        $testFiles[2].FullName | ForEach-Object {
            Should -Invoke Remove-SFTPItem -Times 1 -Exactly -Scope Context -ParameterFilter {
                $Path -eq $_
            }
        }
    }
    Context 'return an object with results for' {
        It 'normally downloaded files' {
            foreach ($testFile in $testFiles[0..1]) {
                $actual = $testResults.where(
                    { $_.FileName -eq $testFile.Name }
                )

                $actual.DateTime | Should -Not -BeNullOrEmpty
                $actual.Source | Should -Be $testNewParams.Paths.Source
                $actual.Destination | Should -Be $testNewParams.Paths.Destination
                $actual.FileLength | Should -Not -BeNullOrEmpty
                $actual.Action | Should -Be 'File moved'
                $actual.Error | Should -BeNullOrEmpty
            }
        }
        It 'downloaded files that failed in the previous run' {
            foreach ($testFile in $testFiles[2]) {
                $actual = $testResults.where(
                    { $_.FileName -eq $testFile.Name }
                )

                $actual.DateTime | Should -Not -BeNullOrEmpty
                $actual.Source | Should -Be $testNewParams.Paths.Source
                $actual.Destination | Should -Be $testNewParams.Paths.Destination
                $actual.FileLength | Should -Not -BeNullOrEmpty
                $actual.Action | Should -Be 'File moved after previous unsuccessful move'
                $actual.Error | Should -BeNullOrEmpty
            }
        }
        It 'removed incomplete files from the destination folder' {
            foreach ($testFile in $testIncompleteFile) {
                $actual = $testResults.where(
                    { $_.FileName -eq $testFile.Name }
                )

                $actual.DateTime | Should -Not -BeNullOrEmpty
                $actual.Source | Should -Be $testNewParams.Paths.Source
                $actual.Destination | Should -Be $testNewParams.Paths.Destination
                $actual.FileLength | Should -Not -BeNullOrEmpty
                $actual.Action | Should -Be "Removed incomplete downloaded file '$($actual.FullName)'"
                $actual.Error | Should -BeNullOrEmpty
            }
        }
    }
}
Describe 'OverwriteFile' {
    BeforeAll {
        $testSFtpFile = @{
            Name     = 'a.txt'
            FullName = '\data\a.txt'
        }

        $testNewParams = Copy-ObjectHC $testParams
        $testNewParams.Paths = @(
            @{
                Source      = 'sftp:/data/'
                Destination = (New-Item 'TestDrive:/y' -ItemType 'Directory').FullName
            }
        )

        $testFile = New-Item "$($testNewParams.Paths.Destination)\$($testSFtpFile.Name)" -ItemType 'File'

        Mock Get-SFTPChildItem {
            $testSFtpFile
        }
        Mock Get-SFTPItem {
            $null = New-Item -Path $testFile.FullName -ItemType 'File'
        }
    }
    Context 'true' {
        BeforeAll {
            $testNewParams.OverwriteFile = $true

            $testResults = .$testScript @testNewParams
        }
        It '2 objects are returned' {
            $testResults | Should -HaveCount 2
        }
        It 'one object for the removed duplicate file' {
            $testResults[0].FileName | Should -Be $testFile.Name
            $testResults[0].Action | Should -Be 'Removed duplicate file from the file system'
        }
        It 'one object for the downloaded file' {
            $testResults[1].FileName | Should -Be $testFile.Name
            $testResults[1].Action | Should -Be 'File moved'
        }
        It 'call Get-SFTPItem to download the file' {
            Should -Invoke Get-SFTPItem -Times 1 -Exactly -Scope Context
        }
    }
    Context 'false' {
        BeforeAll {
            if (-not (Test-Path $testFile)) {
                $null = New-Item $testFile -ItemType File
            }

            $testNewParams.OverwriteFile = $false

            $Error.Clear()

            $testResults = .$testScript @testNewParams
        }
        It 'do not call Get-SFTPItem to download the file' {
            Should -Not -Invoke Get-SFTPItem -Times 1 -Exactly -Scope Context
        }
        It '1 object is returned' {
            $testResults | Should -HaveCount 1

            $testResults.FileName | Should -Be $testFile.Name
            $testResults.Error | Should -Be "Duplicate file '$($testFile.Name)' in folder '$($testNewParams.Paths.Destination)', use Option.OverwriteFile if desired"
        }
        It 'errors are handled within the script' {
            $error | Should -HaveCount 0
        }
    }
}
Describe 'when FileExtensions is' {
    BeforeAll {
        $testNewParams = Copy-ObjectHC $testParams
        $testNewParams.Paths = @(
            @{
                Source      = 'sftp:/data/'
                Destination = (New-Item 'TestDrive:\pl' -ItemType 'Directory').FullName
            }
        )

        $testData = @(
            @{
                Name        = 'a.txt'
                FullName    = '/data/a.txt'
                isDirectory = $false
            }
            @{
                Name        = 'b.jpg'
                FullName    = '/data/b.jpg'
                isDirectory = $false
            }
            @{
                Name        = 'c.docx'
                FullName    = '/data/c.docx'
                isDirectory = $false
            }
            @{
                Name        = 'folder'
                FullName    = '/data/folder'
                isDirectory = $true
            }
        )

        $testFiles = $testData.where(
            { -not $_.isDirectory }
        )

        Mock Get-SFTPChildItem {
            $testData
        }
    }
    It 'empty, all files are downloaded' {
        $testNewParams.FileExtensions = @()

        .$testScript @testNewParams

        $testFiles | ForEach-Object {
            Should -Invoke Get-SFTPItem -Times 1 -Exactly -ParameterFilter {
                    ($Path -eq $_.FullName) -and
                    ($Destination -eq $testNewParams.Paths.Destination.TrimStart('sftp:')) -and
                    ($SessionId -eq 1)
            }
        }
        Should -Invoke Get-SFTPItem -Times $testFiles.Count -Exactly 
    }
    It 'not empty, only specific files are downloaded' {
        $testNewParams.FileExtensions = @('.txt', '.jpg')

        .$testScript @testNewParams

        Should -Invoke Get-SFTPItem -Times 2 -Exactly

        $testFiles.Where(
            {
                    ($_.Name -like '*.txt') -or
                    ($_.Name -like '*.jpg')
            }
        ) | ForEach-Object {
            Should -Invoke Get-SFTPItem -Times 1 -Exactly -ParameterFilter {
                    ($Path -eq "$($_.FullName)") -and
                    ($Destination -eq $testNewParams.Paths.Destination.TrimStart('sftp:')) -and
                    ($SessionId -eq 1)
            }
        }
    }
}
