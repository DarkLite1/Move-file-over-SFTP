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
        MaxConcurrentActions = 1
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
        'MaxConcurrentActions'
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
