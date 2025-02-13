#Requires -Modules Pester
#Requires -Modules Toolbox.EventLog, Toolbox.HTML
#Requires -Version 5.1

BeforeAll {
    $params = @{
        TypeName     = 'System.Management.Automation.PSCredential'
        ArgumentList = 'bob', ('pass' | ConvertTo-SecureString -AsPlainText -Force)
    }

    $testScript = $PSCommandPath.Replace('.Tests.ps1', '.ps1')
    $testParams = @{
        SftpComputerName  = 'PC1'
        SftpCredential    = New-Object @params
        Paths             = @(
            @{
                Source      = (New-Item 'TestDrive:/f1' -ItemType 'Directory').FullName
                Destination = 'sftp:/data/'
            }
            @{
                Source      = 'sftp:/report/'
                Destination = (New-Item 'TestDrive:/f2' -ItemType 'Directory').FullName
            }
        )
        MaxConcurrentJobs = 1
        FileExtensions    = @()
        OverwriteFile     = $false
    }

    Mock Get-SFTPChildItem
    Mock Set-SFTPItem
    Mock Get-SFTPItem
    Mock New-SFTPItem
    Mock Move-SFTPItem
    Mock Rename-SFTPFile
    Mock Remove-SFTPItem
    Mock Remove-SFTPSession
    Mock New-SFTPSession {
        [PSCustomObject]@{
            SessionID = 1
        }
    }
    Mock Test-SFTPPath {
        $true
    }
}
Describe 'the mandatory parameters are' {
    It '<_>' -ForEach @(
        'Paths',
        'SftpComputerName',
        'SftpCredential',
        'MaxConcurrentJobs'
    ) {
        (Get-Command $testScript).Parameters[$_].Attributes.Mandatory |
        Should -BeTrue
    }
}
Describe 'create an SFTP session with' {
    It 'UserName and Password' {
        $testNewParams = Copy-ObjectHC $testParams
        $testNewParams.Paths = @(
            @{
                Source      = (New-Item 'TestDrive:\po' -ItemType 'Directory').FullName
                Destination = 'sftp:/data/'
            }
        )

        $null = New-Item -Path (Join-Path $testNewParams.Paths[0].Source 'k.txt') -ItemType 'File'

        .$testScript @testNewParams

        Should -Invoke New-SFTPSession -Times 1 -Exactly -ParameterFilter {
            ($ComputerName -eq $testNewParams.SftpComputerName) -and
            ($Credential -is 'System.Management.Automation.PSCredential') -and
            ($AcceptKey) -and
            ($Force) -and
            (-not $KeyString)
        }
    }
    It 'SftpOpenSshKeyFile' {
        $testNewParams = Copy-ObjectHC $testParams
        $testNewParams.Paths = @(
            @{
                Source      = (New-Item 'TestDrive:\p' -ItemType 'Directory').FullName
                Destination = 'sftp:/data/'
            }
        )

        $null = New-Item -Path (Join-Path $testNewParams.Paths[0].Source 'k.txt') -ItemType 'File'

        $testNewParams.SftpOpenSshKeyFile = @('a')

        .$testScript @testNewParams

        Should -Invoke New-SFTPSession -Times 1 -Exactly -ParameterFilter {
            ($ComputerName -eq $testNewParams.SftpComputerName) -and
            ($Credential -is 'System.Management.Automation.PSCredential') -and
            ($AcceptKey) -and
            ($Force) -and
            ($KeyString -eq 'a')
        }
    }
}
Describe 'Upload to SFTP server' {
    BeforeAll {
        $testSource = @{
            Folder   = (New-Item 'TestDrive:/f3' -ItemType 'Directory').FullName
            FileName = 'a.txt'
        }

        $testSource.FileFullName = (New-Item -Path $testSource.Folder -Name $testSource.FileName -ItemType File).FullName
    }
    Context 'create an object with Error property when' {
        It 'Paths.Source does not exist' {
            $testNewParams = Copy-ObjectHC $testParams
            $testNewParams.Paths[0].Source = 'c:\doesNotExist'

            $testResult = .$testScript @testNewParams

            $testResult.Error |
            Should -Be "Path '$($testNewParams.Paths[0].Source)' not found on the file system"
        }
        It 'the SFTP path does not exist' {
            $testNewParams = Copy-ObjectHC $testParams
            $testNewParams.Paths = @(
                @{
                    Source      = $testSource.Folder
                    Destination = 'sftp:/notExisting/'
                }
            )

            Mock Test-SFTPPath {
                $false
            }

            $testResult = .$testScript @testNewParams

            $testResult.Error |
            Should -Be "Path '/notExisting/' not found on the SFTP server"
        }
        It 'the upload fails' {
            $testNewParams = Copy-ObjectHC $testParams
            $testNewParams.Paths = @(
                @{
                    Source      = $testSource.Folder
                    Destination = 'sftp:/data/'
                }
            )

            Mock Set-SFTPItem {
                throw 'Oops'
            }

            $error.Clear()

            $testResult = .$testScript @testNewParams

            $testResult.Error | Should -BeLike "*$($testSource.FileName)*Oops"
            $testSource.FileFullName | Should -Exist

            $error | Should -HaveCount 0
        }
        It 'authentication to the SFTP server fails' {
            $testNewParams = Copy-ObjectHC $testParams
            $testNewParams.Paths = @(
                @{
                    Source      = $testSource.Folder
                    Destination = 'sftp:/data/'
                }
            )

            Mock New-SFTPSession {
                throw 'Failed authenticating'
            }

            $error.Clear()

            $testResult = .$testScript @testNewParams

            $testResult.Error | Should -Be "Failed creating an SFTP session to '$($testNewParams.SftpComputerName)': Failed authenticating"
            $testSource.FileFullName | Should -Exist

            $error | Should -HaveCount 0
        }
    }
    Context 'do not start an SFTP sessions when' {
        It 'there is nothing to upload' {
            $testNewParams = Copy-ObjectHC $testParams
            $testNewParams.Paths = @{
                Source      = (New-Item 'TestDrive:/emptyFolder' -ItemType 'Directory').FullName
                Destination = 'sftp:/data/'
            }

            .$testScript @testNewParams

            Should -Not -Invoke Set-SFTPItem
            Should -Not -Invoke New-SFTPSession
            Should -Not -Invoke Test-SFTPPath
            Should -Not -Invoke Remove-SFTPSession
        }
    }
    Context 'when files are found in the source folder' {
        BeforeAll {
            $testNewParams = Copy-ObjectHC $testParams
            $testNewParams.Paths = @(
                @{
                    Source      = (New-Item 'TestDrive:/z' -ItemType 'Directory').FullName
                    Destination = 'sftp:/data/'
                }
            )

            $testFiles = @('file1.txt', 'file2.txt', 'file3.txt') | ForEach-Object {
                New-Item "$($testNewParams.Paths[0].Source)\$_" -ItemType 'File'
            }

            $testResults = .$testScript @testNewParams
        }
        It 'call Set-SFTPItem to upload a temp file' {
            $testFiles | ForEach-Object {
                Should -Invoke Set-SFTPItem -Times 1 -Exactly -Scope Context -ParameterFilter {
                    ($Path -eq "$($_.FullName).UploadInProgress") -and
                    ($Destination -eq $testNewParams.Paths[0].Destination.TrimStart('sftp:')) -and
                    ($SessionId -eq 1)
                }
            }
        }
        It 'call Rename-SFTPFile to rename the temp file' {
            $testFiles | ForEach-Object {
                Should -Invoke Rename-SFTPFile -Times 1 -Exactly -Scope Context -ParameterFilter {
                    ($Path -eq ($testNewParams.Paths[0].Destination.TrimStart('sftp:') + $_.Name + ".UploadInProgress")) -and
                    ($NewName -eq $_.Name) -and
                    ($SessionId -eq 1)
                }
            }
        } -Skip
        It 'remove the local temp file' {
            $testFiles | ForEach-Object {
                $_.FullName | Should -Not -Exist
            }
        }
        It 'return an object with results' {
            $testResults | Should -HaveCount $testFiles.Count

            foreach ($testFile in $testFiles) {
                $actual = $testResults.where(
                    { $_.FileName -eq $testFile.Name }
                )

                $actual.DateTime | Should -Not -BeNullOrEmpty
                $actual.Source | Should -Be $testNewParams.Paths[0].Source
                $actual.Destination | Should -Be $testNewParams.Paths[0].Destination
                $actual.FileLength | Should -Not -BeNullOrEmpty
                $actual.Action | Should -Be 'File moved'
                $actual.Error | Should -BeNullOrEmpty
            }
        }
    }
    Context 'OverwriteFile' {
        BeforeAll {
            $testSFtpFile = @{
                Name     = 'a.txt'
                FullName = 'sftpPath\a.txt'
            }

            $testNewParams = Copy-ObjectHC $testParams
            $testNewParams.Paths = @(
                @{
                    Source      = (New-Item 'TestDrive:/y' -ItemType 'Directory').FullName
                    Destination = 'sftp:/data/'
                }
            )

            $testFile = New-Item "$($testNewParams.Paths[0].Source)\$($testSFtpFile.Name)" -ItemType 'File'

            Mock Get-SFTPChildItem {
                $testSFtpFile
            }
        }
        Context 'true' {
            BeforeAll {
                $testNewParams.OverwriteFile = $true

                $testResults = .$testScript @testNewParams
            }
            It 'the duplicate file on the SFTP server is removed' {
                Should -Invoke Remove-SFTPItem -Times 1 -Exactly -Scope Context -ParameterFilter {
                    ($Path -eq $testSFtpFile.FullName) -and
                    ($SessionId -eq 1)
                }
            }
            It 'the file is uploaded' {
                Should -Invoke Set-SFTPItem -Times 1 -Exactly -Scope Context
            }
            It 'return an object with results' {
                $testResults | Should -HaveCount 2

                $testResults[0].Action | Should -Be 'Removed duplicate file from SFTP server'
            }
        }
        Context 'false' {
            BeforeAll {
                if (-not (Test-Path $testFile)) {
                    $null = New-Item $testFile -ItemType File
                }

                $testNewParams.OverwriteFile = $false

                $testResults = .$testScript @testNewParams
            }
            It 'the duplicate file on the SFTP server is not overwritten' {
                Should -Not -Invoke Remove-SFTPItem -Scope Context
            }
            It 'return an object with results' {
                $testResults | Should -HaveCount 1

                $testResults.Error | Should -Be 'Duplicate file on SFTP server, use Option.OverwriteFile if desired'
            }
        }
    }
    Context 'when FileExtensions is' {
        BeforeAll {
            $testNewParams = Copy-ObjectHC $testParams
            $testNewParams.Paths = @(
                @{
                    Source      = (New-Item 'TestDrive:\Upload' -ItemType 'Directory').FullName
                    Destination = 'sftp:/data/'
                }
            )
        }
        It 'empty, all files are uploaded' {
            $testNewParams.FileExtensions = @()

            $testFiles = @(
                'file.txt'
                'file.xml'
                'file.jpg'
            ) | ForEach-Object {
                New-Item -Path (Join-Path $testNewParams.Paths[0].Source $_) -ItemType 'File'
            }

            .$testScript @testNewParams

            $testFiles | ForEach-Object {
                Should -Invoke Set-SFTPItem -Times 1 -Exactly -Scope Context -ParameterFilter {
                    ($Path -eq "$($_.FullName).UploadInProgress") -and
                    ($Destination -eq $testNewParams.Paths[0].Destination.TrimStart('sftp:')) -and
                    ($SessionId -eq 1)
                }
            }
        }
        It 'not empty, only specific files are uploaded' {
            $testNewParams.FileExtensions = @('.txt', '.xml')

            $testFiles = @(
                'file.txt'
                'file.xml'
                'file.jpg'
            ) | ForEach-Object {
                New-Item -Path (Join-Path $testNewParams.Paths[0].Source $_) -ItemType 'File'
            }

            .$testScript @testNewParams

            Should -Invoke Set-SFTPItem -Times 2 -Exactly

            foreach ($testFile in $testFiles) {
                if ($testFile.Extension -eq '.jpg') {
                    Should -Not -Invoke Set-SFTPItem -ParameterFilter {
                        ($Path -eq "$($testFile.FullName).UploadInProgress") -and
                        ($Destination -eq $testNewParams.Paths[0].Destination.TrimStart('sftp:')) -and
                        ($SessionId -eq 1)
                    }
                    Continue
                }

                Should -Invoke Set-SFTPItem -Times 1 -Exactly -ParameterFilter {
                    ($Path -eq "$($testFile.FullName).UploadInProgress") -and
                    ($Destination -eq $testNewParams.Paths[0].Destination.TrimStart('sftp:')) -and
                    ($SessionId -eq 1)
                }
            }
        }
    }
}
Describe 'Download from the SFTP server' {
    BeforeAll {
        $testFiles = @(
            @{
                Name        = 'b.txt'
                FullName    = '/data/b.txt'
                isDirectory = $false
            }
            @{
                Name        = 'c.txt'
                FullName    = '/data/c.txt'
                isDirectory = $false
            }
            @{
                Name        = 'd.txt'
                FullName    = '/data/d.txt'
                isDirectory = $false
            }
        )
        Mock Get-SFTPChildItem {
            $testFiles
        }
    }
    Context 'create an object with Error property when' {
        It 'the SFTP path does not exist' {
            $testNewParams = Copy-ObjectHC $testParams
            $testNewParams.Paths[1].Source = 'sftp:/notExisting/'

            Mock Test-SFTPPath {
                $false
            }

            $testResult = .$testScript @testNewParams

            $testResult.Error |
            Should -BeLike "*Path '/notExisting/' not found on the SFTP server"

            Should -Not -Invoke Get-SFTPItem
            Should -Not -Invoke Rename-SFTPFile
        }
        It 'the SFTP file list cannot be retrieved' {
            Mock Get-SFTPChildItem {
                throw 'Nope'
            }

            $testResult = .$testScript @testParams

            $testResult.Error |
            Should -BeLike "*Failed retrieving the content of SFTP folder '/report/': Nope"

            Should -Not -Invoke Get-SFTPItem
            Should -Not -Invoke Rename-SFTPFile
        }
        It 'the download folder does not exist' {
            $testNewParams = Copy-ObjectHC $testParams
            $testNewParams.Paths[1].Destination = 'TestDrive:/notExisting/'

            $testResult = .$testScript @testNewParams

            $testResult.Error |
            Should -BeLike "*Path 'TestDrive:/notExisting/' not found on the file system"

            Should -Not -Invoke Get-SFTPItem
            Should -Not -Invoke Rename-SFTPFile
        }
        It 'create temp folder on local file system' {
            $testNewParams = Copy-ObjectHC $testParams
            $testJoinParams = @{
                Path      = $testNewParams.Paths[1].Destination 
                ChildPath = 'sftpTransfer/download' 
            }
            $testLocalDownloadPath = Join-Path @testJoinParams

            $testResult = .$testScript @testNewParams

            $testLocalDownloadPath | Should -Exist
        }
        It 'create temp folder on SFTP server' {
            $testResult = .$testScript @testParams

            should -Invoke New-SFTPItem -Times 1 -Exactly -ParameterFilter {
                ($Path -eq '/report/sftpTransfer/download' ) -and
                ($ItemType -eq 'Directory') -and
                ($Recurse)
            }
        }
        It 'the download fails' {
            Mock Get-SFTPItem {
                # bug in CmdLet, dos not throw bu creates warning
                # throw 'Oops' 
                Write-Warning 'Oops'
            }

            $error.Clear()

            $testResult = .$testScript @testParams

            $testResult.Error | Should -BeLike "*Oops"

            $error | Should -HaveCount 0
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
    }
    Context 'when files are found on the SFTP server' {
        BeforeAll {
            $testNewParams = Copy-ObjectHC $testParams
            $testNewParams.Paths = @(
                @{
                    Source      = 'sftp:/data/'
                    Destination = (New-Item 'TestDrive:/ll' -ItemType 'Directory').FullName
                }
            )

            Mock Get-SFTPItem {
                $null = New-Item -Path $testNewParams.Paths[0].Destination -Name 'b.txt' -ItemType 'File'
            } -ParameterFilter {
                ($Path -eq '/data/b.txt') -and
                ($Destination -eq $testNewParams.Paths[0].Destination)
            }

            Mock Get-SFTPItem {
                $null = New-Item -Path $testNewParams.Paths[0].Destination -Name 'c.txt' -ItemType 'File'
            } -ParameterFilter {
                ($Path -eq '/data/c.txt') -and
                ($Destination -eq $testNewParams.Paths[0].Destination)
            }

            Mock Get-SFTPItem {
                $null = New-Item -Path $testNewParams.Paths[0].Destination -Name 'd.txt' -ItemType 'File'
            } -ParameterFilter {
                ($Path -eq '/data/d.txt') -and
                ($Destination -eq $testNewParams.Paths[0].Destination)
            }

            $testIncompleteFile = New-Item -Path $testNewParams.Paths[0].Destination -Name 'k.txt' -ItemType 'File'

            $testCompleteFile = New-Item -Path $testNewParams.Paths[0].Destination -Name 'y.txt' -ItemType 'File'

            $testResults = .$testScript @testNewParams
        }
        It 'call Get-SFTPChildItem to retrieve the SFTP list' {
            Should -Invoke Get-SFTPChildItem -Times 1 -Exactly -Scope Context
        }
        It 'incomplete downloaded files are removed from the download folder' {
            $testIncompleteFile | Should -Not -Exist
        }
        It 'fully downloaded files in the download folder are left untouched' {
            $testCompleteFile | Should -Exist
        }
        It 'call Get-SFTPItem to download all temp file' {
            $testFiles[0..1] | ForEach-Object {
                Should -Invoke Get-SFTPItem -Times 1 -Exactly -Scope Context -ParameterFilter {
                    ($Path -eq $_.FullName) -and
                    ($Destination -eq $testNewParams.Paths[0].Destination) -and
                    ($SessionId -eq 1)
                }
            }
            $testFiles[2] | ForEach-Object {
                Should -Invoke Get-SFTPItem -Times 1 -Exactly -Scope Context -ParameterFilter {
                    ($Path -eq $_.FullName) -and
                    ($Destination -eq $testNewParams.Paths[0].Destination) -and
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
                    $actual.Source | Should -Be $testNewParams.Paths[0].Source
                    $actual.Destination | Should -Be $testNewParams.Paths[0].Destination
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
                    $actual.Source | Should -Be $testNewParams.Paths[0].Source
                    $actual.Destination | Should -Be $testNewParams.Paths[0].Destination
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
                    $actual.Source | Should -Be $testNewParams.Paths[0].Source
                    $actual.Destination | Should -Be $testNewParams.Paths[0].Destination
                    $actual.FileLength | Should -Not -BeNullOrEmpty
                    $actual.Action | Should -Be "Removed incomplete downloaded file '$($actual.FullName)'"
                    $actual.Error | Should -BeNullOrEmpty
                }
            }
        }
    }
    Context 'OverwriteFile' {
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

            $testFile = New-Item "$($testNewParams.Paths[0].Destination)\$($testSFtpFile.Name)" -ItemType 'File'

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
                $testResults.Error | Should -Be "Duplicate file '$($testFile.Name)' in folder '$($testNewParams.Paths[0].Destination)', use Option.OverwriteFile if desired"
            }
            It 'errors are handled within the script' {
                $error | Should -HaveCount 0
            }
        }
    }
    Context 'when FileExtensions is' {
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
                    ($Destination -eq $testNewParams.Paths[0].Destination.TrimStart('sftp:')) -and
                    ($SessionId -eq 1)
                }
            }
            Should -Invoke Get-SFTPItem -Times $testFiles.Count -Exactly 
        }  -Tag test
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
                    ($Destination -eq $testNewParams.Paths[0].Destination.TrimStart('sftp:')) -and
                    ($SessionId -eq 1)
                }
            }
        }
    }
}
