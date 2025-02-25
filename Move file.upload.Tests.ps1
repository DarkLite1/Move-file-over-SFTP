#Requires -Modules Pester
#Requires -Modules Toolbox.EventLog, Toolbox.HTML
#Requires -Version 5.1

BeforeAll {
    $params = @{
        TypeName     = 'System.Management.Automation.PSCredential'
        ArgumentList = 'bob', ('pass' | ConvertTo-SecureString -AsPlainText -Force)
    }

    $testScript = $PSCommandPath.Replace('.upload.Tests.ps1', '.ps1')
    $testParams = @{
        SftpComputerName  = 'PC1'
        SftpCredential    = New-Object @params
        Paths             = @{
            Source      = (New-Item 'TestDrive:/f1' -ItemType 'Directory').FullName
            Destination = 'sftp:/data/'
        }
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
    Mock Test-SFTPPath
    Mock New-SFTPSession {
        [PSCustomObject]@{
            SessionID = 1
        }
    }
}

Describe 'When a file is in the source folder' {
    BeforeAll {
        Mock Get-SFTPChildItem 

        $testNewItemParams = @{
            Path     = $testParams.Paths.Source
            Name     = 'b.txt'
            ItemType = 'File'
        }
        $testFile = New-Item @testNewItemParams

        $testResult = .$testScript @testParams
    }

    it 'is uploaded to the sftp temp folder' {
        Should -Invoke Set-SFTPItem -Times 1 -Exactly -Scope Describe -ParameterFilter {
            ($Path -eq $testFile.FullName) -and
            ($Destination -eq 'sftp:/data/')
        }
    }
}
Describe 'When a file is found in the source folder' {
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
            $testNewParams.Paths.Source = 'c:\doesNotExist'

            $testResult = .$testScript @testNewParams

            $testResult.Error |
                Should -Be "Path '$($testNewParams.Paths.Source)' not found on the file system"
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
                New-Item "$($testNewParams.Paths.Source)\$_" -ItemType 'File'
            }

            $testResults = .$testScript @testNewParams
        }
        It 'call Set-SFTPItem to upload a temp file' {
            $testFiles | ForEach-Object {
                Should -Invoke Set-SFTPItem -Times 1 -Exactly -Scope Context -ParameterFilter {
                    ($Path -eq "$($_.FullName).UploadInProgress") -and
                    ($Destination -eq $testNewParams.Paths.Destination.TrimStart('sftp:')) -and
                    ($SessionId -eq 1)
                }
            }
        }
        It 'call Rename-SFTPFile to rename the temp file' {
            $testFiles | ForEach-Object {
                Should -Invoke Rename-SFTPFile -Times 1 -Exactly -Scope Context -ParameterFilter {
                    ($Path -eq ($testNewParams.Paths.Destination.TrimStart('sftp:') + $_.Name + '.UploadInProgress')) -and
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
                $actual.Source | Should -Be $testNewParams.Paths.Source
                $actual.Destination | Should -Be $testNewParams.Paths.Destination
                $actual.FileLength | Should -Not -BeNullOrEmpty
                $actual.Actions | Should -Be 'File moved'
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

            $testFile = New-Item "$($testNewParams.Paths.Source)\$($testSFtpFile.Name)" -ItemType 'File'

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

                $testResults.Actions[0] | Should -Be 'Removed duplicate file from SFTP server'
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
                New-Item -Path (Join-Path $testNewParams.Paths.Source $_) -ItemType 'File'
            }

            .$testScript @testNewParams

            $testFiles | ForEach-Object {
                Should -Invoke Set-SFTPItem -Times 1 -Exactly -Scope Context -ParameterFilter {
                    ($Path -eq "$($_.FullName).UploadInProgress") -and
                    ($Destination -eq $testNewParams.Paths.Destination.TrimStart('sftp:')) -and
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
                New-Item -Path (Join-Path $testNewParams.Paths.Source $_) -ItemType 'File'
            }

            .$testScript @testNewParams

            Should -Invoke Set-SFTPItem -Times 2 -Exactly

            foreach ($testFile in $testFiles) {
                if ($testFile.Extension -eq '.jpg') {
                    Should -Not -Invoke Set-SFTPItem -ParameterFilter {
                        ($Path -eq "$($testFile.FullName).UploadInProgress") -and
                        ($Destination -eq $testNewParams.Paths.Destination.TrimStart('sftp:')) -and
                        ($SessionId -eq 1)
                    }
                    Continue
                }

                Should -Invoke Set-SFTPItem -Times 1 -Exactly -ParameterFilter {
                    ($Path -eq "$($testFile.FullName).UploadInProgress") -and
                    ($Destination -eq $testNewParams.Paths.Destination.TrimStart('sftp:')) -and
                    ($SessionId -eq 1)
                }
            }
        }
    }
}
