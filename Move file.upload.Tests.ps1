#Requires -Modules Pester
#Requires -Modules Toolbox.EventLog, Toolbox.HTML
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
            ($Destination -eq '/report/b.txt') -and
            ($Force)
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
} -Tag test