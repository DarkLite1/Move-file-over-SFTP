#Requires -Version 7
#Requires -Modules ImportExcel
#Requires -Modules Toolbox.EventLog, Toolbox.HTML

<#
.SYNOPSIS
    Download files from an SFTP server or upload files to an SFTP server.

.DESCRIPTION
    Read an input file that contains all the parameters for this script.

    The computer that is running the SFTP code should have the module 'Posh-SSH'
    installed.

    Tasks will always run in sequential order, one after the other. Actions run
    in parallel when MaxConcurrentJobs is more than 1.

.PARAMETER ImportFile
    A .JSON file that contains all the parameters used by the script.

.PARAMETER Tasks
    Each task is a collection of upload and/or download actions. Tasks will
    always run in sequential order, one after the other.

    A single task can only talk to one SFTP server. Keep this in mind when
    creating your input file.

.PARAMETER Tasks.TaskName
    Name of the task. This name is used identify the task in the Excel log file
    and in the e-mail sent to the user.

.PARAMETER Tasks.Sftp.ComputerName
    The SFTP server or endpoint. This can be a hostname, IP address or URL.

.PARAMETER Tasks.Sftp.Credential.UserName
    The user name used to authenticate to the SFTP server.

    This is an environment variable on the computer that is running this script.

.PARAMETER Tasks.Sftp.Credential.Password
    The password used to authenticate to the SFTP server.

    This is an environment variable on the computer that is running this script.

.PARAMETER Tasks.Sftp.Credential.PasswordKeyFile
    The password used to authenticate to the SFTP server.

    This is an SSH private key file in the OpenSSH format.

.PARAMETER Tasks.Actions
    Each action represents a connection to a remote computer, when
    ComputerName is used. When ComputerName is not used, the SFTP code is
    executed on the localhost.

    All the Actions of a Task run in parallel when MaxConcurrentJobs is more
    than 1.

.PARAMETER Tasks.Actions.ComputerName
    The client where the SFTP code will be executed. This computer needs to
    have the module 'Posh-SSH' installed.

.PARAMETER Tasks.Actions.Paths
    Combination of 'Source' and 'Destination' folder where one is an
    SFTP path ('sftp:\xxx\') and the other a file system path
    ('c:\xxx' or '\\SERVER\xxx').

.PARAMETER Tasks.Option.OverwriteFile
    Overwrite a file in the 'Destination' folder when it already exists.

.PARAMETER Tasks.Option.FileExtensions
    Only move files with the extensions defined in 'FileExtensions'
    ('.txt', 'csv', ...). If 'FileExtensions' is left blank, all files in the
    'Source' folder are moved to the 'Destination' folder.

.PARAMETER SendMail
    Contains all the information for sending e-mails.

.PARAMETER SendMail.To
    Destination e-mail addresses.

.PARAMETER SendMail.When
    When does the script need to send an e-mail.

    Valid values:
    - Always              : Always sent an e-mail
    - Never               : Never sent an e-mail
    - OnlyOnError         : Only sent an e-mail when errors where detected
    - OnlyOnErrorOrAction : Only sent an e-mail when errors where detected or
                            when items were uploaded

.PARAMETER ExportExcelFile.When
    When does the script create an Excel log file.

    Valid values:
    - Never               : Never create an Excel log file
    - OnlyOnError         : Only create an Excel log file when
                            errors where detected
    - OnlyOnErrorOrAction : Only create an Excel log file when
                            errors where detected or when items were uploaded

.PARAMETER PSSessionConfiguration
    The version of PowerShell on the remote endpoint as returned by
    Get-PSSessionConfiguration.

.PARAMETER ReportOnly
    This switch is not in the input file but meant as an argument to the script.

    When this switch is used the SFTP code is not executed. This option will
    read the previously exported Excel file and creates a summary email of all
    the actions in that Excel sheet.

    This can be useful when the script ran every 5 minutes with a Task
    Scheduler and 'SendMail.When' was 'OnlyOnError'.
#>

[CmdLetBinding()]
Param (
    [Parameter(Mandatory)]
    [String]$ScriptName,
    [Parameter(Mandatory)]
    [String]$ImportFile,
    [HashTable]$ScriptPath = @{
        MoveFile = "$PSScriptRoot\Move file.ps1"
    },
    [Switch]$ReportOnly,
    [String]$PSSessionConfiguration = 'PowerShell.7',
    [String]$LogFolder = "$env:POWERSHELL_LOG_FOLDER\File or folder\Move file over SFTP\$ScriptName",
    [String[]]$ScriptAdmin = @(
        $env:POWERSHELL_SCRIPT_ADMIN,
        $env:POWERSHELL_SCRIPT_ADMIN_BACKUP
    )
)

Begin {
    Try {
        Function Get-EnvironmentVariableValueHC {
            Param(
                [String]$Name
            )

            [Environment]::GetEnvironmentVariable($Name)
        }

        Get-ScriptRuntimeHC -Start
        Import-EventLogParamsHC -Source $ScriptName
        Write-EventLog @EventStartParams
        $Error.Clear()

        #region Test path exists
        $scriptPathItem = @{}

        $ScriptPath.GetEnumerator().ForEach(
            {
                try {
                    $key = $_.Key
                    $value = $_.Value

                    $params = @{
                        Path        = $value
                        ErrorAction = 'Stop'
                    }
                    $scriptPathItem[$key] = (Get-Item @params).FullName
                }
                catch {
                    throw "ScriptPath.$key '$value' not found"
                }
            }
        )
        #endregion

        #region Create log folder
        try {
            $logParams = @{
                LogFolder    = New-Item -Path $LogFolder -ItemType 'Directory' -Force -ErrorAction 'Stop'
                Name         = $ScriptName
                Date         = 'ScriptStartTime'
                NoFormatting = $true
            }
            $logFile = New-LogFileNameHC @LogParams
        }
        Catch {
            throw "Failed creating the log folder '$LogFolder': $_"
        }
        #endregion

        #region Import .json file
        Write-Verbose "Import .json file '$ImportFile'"
        # Write-EventLog @EventVerboseParams -Message $M

        $file = Get-Content $ImportFile -Raw -EA Stop -Encoding UTF8 |
            ConvertFrom-Json
        #endregion

        #region Test .json file properties
        Write-Verbose 'Test .json file properties'

        try {
            @(
                'MaxConcurrentJobs', 'SendMail', 'ExportExcelFile', 'Tasks'
            ).where(
                { -not $file.$_ }
            ).foreach(
                { throw "Property '$_' not found" }
            )

            #region Test SendMail
            @('To', 'When').Where(
                { -not $file.SendMail.$_ }
            ).foreach(
                { throw "Property 'SendMail.$_' not found" }
            )

            if ($file.SendMail.When -notMatch '^Never$|^Always$|^OnlyOnError$|^OnlyOnErrorOrAction$') {
                throw "Property 'SendMail.When' with value '$($file.SendMail.When)' is not valid. Accepted values are 'Always', 'Never', 'OnlyOnError' or 'OnlyOnErrorOrAction'"
            }
            #endregion

            #region Test ExportExcelFile
            @('When').Where(
                { -not $file.ExportExcelFile.$_ }
            ).foreach(
                { throw "Property 'ExportExcelFile.$_' not found" }
            )

            if ($file.ExportExcelFile.When -notMatch '^Never$|^OnlyOnError$|^OnlyOnErrorOrAction$') {
                throw "Property 'ExportExcelFile.When' with value '$($file.ExportExcelFile.When)' is not valid. Accepted values are 'Never', 'OnlyOnError' or 'OnlyOnErrorOrAction'"
            }
            #endregion

            #region Test integer value
            try {
                [int]$MaxConcurrentJobs = $file.MaxConcurrentJobs
            }
            catch {
                throw "Property 'MaxConcurrentJobs' needs to be a number, the value '$($file.MaxConcurrentJobs)' is not supported."
            }
            #endregion

            $Tasks = $file.Tasks

            foreach ($task in $Tasks) {
                @(
                    'TaskName', 'Sftp', 'Actions', 'Option'
                ).where(
                    { -not $task.$_ }
                ).foreach(
                    { throw "Property 'Tasks.$_' not found" }
                )

                if (-not $task.TaskName) {
                    throw "Property 'Tasks.TaskName' not found"
                }

                @('ComputerName', 'Credential').where(
                    { -not $task.Sftp.$_ }
                ).foreach(
                    { throw "Property 'Tasks.Sftp.$_' not found" }
                )

                @('UserName').Where(
                    { -not $task.Sftp.Credential.$_ }
                ).foreach(
                    { throw "Property 'Tasks.Sftp.Credential.$_' not found" }
                )

                if (
                    $task.Sftp.Credential.Password -and
                    $task.Sftp.Credential.PasswordKeyFile
                ) {
                    throw "Property 'Tasks.Sftp.Credential.Password' and 'Tasks.Sftp.Credential.PasswordKeyFile' cannot be used at the same time"
                }

                if (
                    (-not $task.Sftp.Credential.Password) -and
                    (-not $task.Sftp.Credential.PasswordKeyFile)
                ) {
                    throw "Property 'Tasks.Sftp.Credential.Password' or 'Tasks.Sftp.Credential.PasswordKeyFile' not found"
                }

                #region Test boolean values
                foreach (
                    $boolean in
                    @(
                        'OverwriteFile'
                    )
                ) {
                    try {
                        $null = [Boolean]::Parse($task.Option.$boolean)
                    }
                    catch {
                        throw "Property 'Tasks.Option.$boolean' is not a boolean value"
                    }
                }
                #endregion

                #region Test file extensions
                $task.Option.FileExtensions.Where(
                    { $_ -and ($_ -notLike '.*') }
                ).foreach(
                    { throw "Property 'Tasks.Option.FileExtensions' needs to start with a dot. For example: '.txt', '.xml', ..." }
                )
                #endregion

                if (-not $task.Actions) {
                    throw 'Tasks.Actions is missing'
                }

                #region Test unique ComputerName
                $task.Actions | Group-Object -Property {
                    $_.ComputerName
                } |
                    Where-Object { $_.Count -ge 2 } | ForEach-Object {
                        throw "Duplicate 'Tasks.Actions.ComputerName' found: $($_.Name)"
                    }
                #endregion

                foreach ($action in $task.Actions) {
                    if ($action.PSObject.Properties.Name -notContains 'ComputerName') {
                        throw "Property 'Tasks.Actions.ComputerName' not found"
                    }

                    @('Paths').Where(
                        { -not $action.$_ }
                    ).foreach(
                        { throw "Property 'Tasks.Actions.$_' not found" }
                    )

                    foreach ($path in $action.Paths) {
                        @(
                            'Source', 'Destination'
                        ).Where(
                            { -not $path.$_ }
                        ).foreach(
                            {
                                throw "Property 'Tasks.Actions.Paths.$_' not found"
                            }
                        )

                        if (
                            (
                                ($path.Source -like '*/*') -and
                                ($path.Destination -like '*/*')
                            ) -or
                            (
                                ($path.Source -like '*\*') -and
                                ($path.Destination -like '*\*')
                            ) -or
                            (
                                ($path.Source -like 'sftp*') -and
                                ($path.Destination -like 'sftp*')
                            ) -or
                            (
                                -not (
                                    ($path.Source -like 'sftp:/*') -or
                                    ($path.Destination -like 'sftp:/*')
                                )
                            )
                        ) {
                            throw "Property 'Tasks.Actions.Paths.Source' and 'Tasks.Actions.Paths.Destination' needs to have one SFTP path ('sftp:/....') and one folder path (c:\... or \\server$\...). Incorrect values: Source '$($path.Source)' Destination '$($path.Destination)'"
                        }
                    }

                    #region Test unique Source Destination
                    $action.Paths | Group-Object -Property 'Source' |
                        Where-Object { $_.Count -ge 2 } | ForEach-Object {
                            throw "Duplicate 'Tasks.Actions.Paths.Source' found: '$($_.Name)'. Use separate Tasks to run them sequentially instead of in Actions, which is ran in parallel"
                        }
                    #endregion

                    #region Test unique Source Destination
                    $action.Paths | Group-Object -Property 'Destination' |
                        Where-Object { $_.Count -ge 2 } | ForEach-Object {
                            throw "Duplicate 'Tasks.Actions.Paths.Destination' found: '$($_.Name)'. Use separate Tasks to run them sequentially instead of in Actions, which is ran in parallel"
                        }
                    #endregion
                }
            }

            #region Test unique TaskName
            $Tasks.TaskName | Group-Object | Where-Object {
                $_.Count -gt 1
            } | ForEach-Object {
                throw "Property 'Tasks.TaskName' with value '$($_.Name)' is not unique. Each task name needs to be unique."
            }
            #endregion
        }
        catch {
            throw "Input file '$ImportFile': $_"
        }
        #endregion

        #region Convert .json file
        Write-Verbose 'Convert .json file'

        try {
            foreach ($task in $Tasks) {
                #region Get SFTP UserName
                if (-not (
                        $SftpUserName = Get-EnvironmentVariableValueHC -Name $task.Sftp.Credential.UserName)
                ) {
                    throw "Environment variable '`$ENV:$($task.Sftp.Credential.UserName)' in 'Sftp.Credential.UserName' not found on computer $ENV:COMPUTERNAME"
                }
                #endregion

                #region Get SFTP password
                $sftpPassword = if ($task.Sftp.Credential.PasswordKeyFile) {
                    try {
                        $PasswordKeyFileStrings = Get-Content -LiteralPath $task.Sftp.Credential.PasswordKeyFile -ErrorAction Stop

                        if (-not $PasswordKeyFileStrings) {
                            throw 'File empty'
                        }

                        $task.Sftp.Credential.PasswordKeyFile = $PasswordKeyFileStrings
                    }
                    catch {
                        throw "Failed converting the task.Sftp.Credential.PasswordKeyFile '$($task.Sftp.Credential.PasswordKeyFile)' to an array: $_"
                    }

                    # Avoid password popup
                    New-Object 'System.Security.SecureString'
                }
                else {
                    #region Add environment variable SFTP Password
                    $params = @{
                        String      = $null
                        AsPlainText = $true
                        Force       = $true
                        ErrorAction = 'Stop'
                    }

                    if (-not (
                            $params.String = Get-EnvironmentVariableValueHC -Name $task.Sftp.Credential.Password)
                    ) {
                        throw "Environment variable '`$ENV:$($task.Sftp.Credential.Password)' in 'Sftp.Credential.Password' not found on computer $ENV:COMPUTERNAME"
                    }

                    ConvertTo-SecureString @params
                    #endregion
                }
                #endregion

                #region Create SFTP credential
                Write-Verbose 'Create SFTP credential'

                $params = @{
                    TypeName     = 'System.Management.Automation.PSCredential'
                    ArgumentList = $sftpUserName, $sftpPassword
                }

                $task.Sftp.Credential | Add-Member -NotePropertyMembers @{
                    Object = New-Object @params
                }
                #endregion

                foreach ($action in $task.Actions) {
                    #region Set ComputerName
                    if ($action.ComputerName) {
                        $action.ComputerName = $action.ComputerName.Trim().ToUpper()
                    }

                    if (
                        (-not $action.ComputerName) -or
                        ($action.ComputerName -eq 'localhost') -or
                        ($action.ComputerName -eq "$ENV:COMPUTERNAME.$env:USERDNSDOMAIN")
                    ) {
                        $action.ComputerName = $env:COMPUTERNAME
                    }
                    #endregion

                    #region Convert Paths
                    foreach ($path in $action.Paths) {
                        if ($path.Source -like 'sftp*') {
                            $path.Source = $path.Source.TrimEnd('/') + '/'
                        }
                        if ($path.Destination -like 'sftp*') {
                            $path.Destination = $path.Destination.TrimEnd('/') + '/'
                        }
                    }
                    #endregion

                    #region Add properties
                    $action | Add-Member -NotePropertyMembers @{
                        Job = @{
                            Results = @()
                            Error   = $null
                        }
                    }
                    #endregion
                }
            }
        }
        catch {
            throw "Input file '$ImportFile': $_"
        }
        #endregion
    }
    catch {
        Write-Warning $_
        Send-MailHC -To $ScriptAdmin -Subject 'FAILURE' -Priority 'High' -Message $_ -Header $ScriptName
        Write-EventLog @EventErrorParams -Message "FAILURE:`n`n- $_"
        Write-EventLog @EventEndParams; Exit 1
    }
}

Process {
    Try {
        if (-not $ReportOnly) {
            $scriptBlock = {
                try {
                    $action = $_

                    #region Declare variables for code running in parallel
                    if (-not $MaxConcurrentJobs) {
                        $task = $using:task
                        $psSessions = $using:psSessions
                        $MaxConcurrentJobs = $using:MaxConcurrentJobs
                        $scriptPathItem = $using:scriptPathItem
                        $PSSessionConfiguration = $using:PSSessionConfiguration
                        $EventVerboseParams = $using:EventVerboseParams
                    }
                    #endregion

                    #region Create job parameters
                    $invokeParams = @{
                        FilePath     = $scriptPathItem.MoveFile
                        ArgumentList = $task.Sftp.ComputerName,
                        $task.Sftp.Credential.Object,
                        $action.Paths,
                        $MaxConcurrentJobs,
                        $task.Sftp.Credential.PasswordKeyFile,
                        $task.Option.FileExtensions,
                        $task.Option.OverwriteFile
                    }

                    $M = "Start task '{0}' on '{1}' with: Sftp.ComputerName '{2}' Paths {3} MaxConcurrentJobs '{4}' FileExtensions '{5}' OverwriteFile '{6}'" -f
                    $task.TaskName,
                    $action.ComputerName,
                    $invokeParams.ArgumentList[0],
                    $(
                        $invokeParams.ArgumentList[2].foreach(
                            { "Source '$($_.Source)' Destination '$($_.Destination)'" }
                        ) -join ', '
                    ),
                    $invokeParams.ArgumentList[3],
                    $($invokeParams.ArgumentList[5] -join ', '),
                    $invokeParams.ArgumentList[6]
                    #endregion

                    #region Start job
                    $computerName = $action.ComputerName

                    $action.Job.Results += if (
                        $computerName -eq $ENV:COMPUTERNAME
                    ) {
                        Write-Verbose $M
                        # Write-EventLog @EventVerboseParams -Message $M

                        $params = $invokeParams.ArgumentList
                        & $invokeParams.FilePath @params
                    }
                    else {
                        #region Code with workaround
                        # create 'Move file' script parameters in script scope
                        # bug: https://github.com/PowerShell/PowerShell/issues/21332

                        if (
                            -not ($psSession = $psSessions[$computerName].Session)
                        ) {
                            # For Pester mocking with a local session object
                            if (-not (
                                    $psSession = $psSessions['localhost'].Session)
                            ) {
                                throw $psSessions[$computerName].Error
                            }
                        }

                        $SftpComputerName = $null
                        $Paths = $null
                        $SftpCredential = $null
                        $SftpOpenSshKeyFile = $null
                        $FileExtensions = $null
                        $OverwriteFile = $null
                        $RetryCountOnLockedFiles = $null
                        $RetryWaitSeconds = $null
                        $PartialFileExtension = $null

                        Write-Verbose $M
                        # Write-EventLog @EventVerboseParams -Message $M

                        $invokeParams += @{
                            Session     = $psSession
                            ErrorAction = 'Stop'
                        }
                        Invoke-Command @invokeParams
                        #endregion

                        <#region Code without workaround
                            $invokeParams += @{
                                ConfigurationName = $PSSessionConfiguration
                                ComputerName      = $computerName
                                ErrorAction       = 'Stop'
                            }
                            Invoke-Command @invokeParams
                        #>
                    }
                    #endregion

                    #region Get job results
                    if ($action.Job.Results.Count -ne 0) {
                        $M = "Result task '{0}' on '{1}' with: Sftp.ComputerName '{2}' Paths {3} MaxConcurrentJobs '{4}' FileExtensions '{5}' OverwriteFile '{6}': {7} object{8}" -f
                        $task.TaskName,
                        $action.ComputerName,
                        $invokeParams.ArgumentList[0],
                        $(
                            $invokeParams.ArgumentList[2].foreach(
                                { "Source '$($_.Source)' Destination '$($_.Destination)'" }
                            ) -join ', '
                        ),
                        $invokeParams.ArgumentList[3],
                        $($invokeParams.ArgumentList[5] -join ', '),
                        $invokeParams.ArgumentList[6],
                        $action.Job.Results.Count,
                        $(if ($action.Job.Results.Count -ne 1) { 's' })

                        Write-Verbose $M
                        Write-EventLog @EventVerboseParams -Message $M
                    }
                    #endregion
                }
                catch {
                    $action.Job.Error = $_
                    $Error.RemoveAt(0)
                }
            }

            #region Create PS sessions
            $psSessions = @{}

            $psSessionParams = @{
                ComputerName      = $null
                ConfigurationName = $PSSessionConfiguration
                ErrorAction       = 'SilentlyContinue'
            }

            if (
                $psSessionParams.ComputerName = $Tasks.Actions.ComputerName |
                    Sort-Object -Unique |
                    Where-Object { $_ -ne $env:COMPUTERNAME }
            ) {
                #region Open PS remoting sessions
                Write-Verbose "Connect to $($psSessionParams.ComputerName.Count) remote computers"

                foreach ($session in New-PSSession @psSessionParams) {
                    $psSessions[$session.ComputerName] = @{
                        Session = $session
                        Error   = $null
                    }
                }

                Write-Verbose "Created $($session.Count) sessions"
                #endregion

                #region Get connection errors
                $Error.where(
                    { $_.InvocationInfo.InvocationName -eq 'New-PSSession' }
                ).foreach(
                    {
                        $computerName = $_.TargetObject.OriginalConnectionInfo.ComputerName
                        $errorMessage = $_.Exception.Message

                        Write-Warning "Failed connecting to '$computerName': $errorMessage"

                        $psSessions[$computerName] = @{
                            Session = $null
                            Error   = $errorMessage
                        }

                        $Error.Remove($_)
                    }
                )
                #endregion
            }
            #endregion

            #region Run code serial or parallel
            $foreachParams = if ($MaxConcurrentJobs -eq 1) {
                @{
                    Process = $scriptBlock
                }
            }
            else {
                @{
                    Parallel      = $scriptBlock
                    ThrottleLimit = $MaxConcurrentJobs
                }
            }

            foreach ($task in $Tasks) {
                Write-Verbose "Execute task '$($task.TaskName)' with $($task.Actions.Count) actions"

                $task.Actions | ForEach-Object @foreachParams
            }

            Write-Verbose 'All tasks finished'
            #endregion
        }
        else {
            Write-Verbose 'Only report results of the current day'
        }
    }
    Catch {
        Write-Warning $_
        Send-MailHC -To $ScriptAdmin -Subject 'FAILURE' -Priority 'High' -Message $_ -Header $ScriptName
        Write-EventLog @EventErrorParams -Message "FAILURE:`n`n- $_"
        Write-EventLog @EventEndParams; Exit 1
    }
    Finally {
        if ($psSessions.Values.Session) {
            # Only close PS Sessions and not the WinPSCompatSession
            # used by Write-EventLog
            # https://github.com/PowerShell/PowerShell/issues/24227
            $psSessions.Values.Session | Remove-PSSession -EA Ignore
        }
    }
}

End {
    try {
        #region Counter
        $counter = @{
            Total = @{
                MovedFiles = 0
                Errors     = 0
            }
        }
        #endregion

        #region Create system error html lists
        $countSystemErrors = (
            $Error.Exception.Message | Measure-Object
        ).Count

        $systemErrorsHtmlList = if ($countSystemErrors) {
            '<p>Detected <b>{0} system error{1}</b>:{2}</p>' -f $countSystemErrors,
            $(
                if ($countSystemErrors -ne 1) { 's' }
            ),
            $(
                $errorList = $Error.Exception.Message | Where-Object { $_ }
                $errorList | ConvertTo-HtmlListHC

                $errorList.foreach(
                    {
                        $M = "System error: $_"
                        Write-Warning $M
                        Write-EventLog @EventErrorParams -Message $M
                    }
                )
            )
        }

        $counter.Total.Errors += $countSystemErrors
        #endregion

        #region Create Excel objects
        $exportToExcel = foreach ($task in $Tasks) {
            Write-Verbose "Task '$($task.TaskName)'"

            foreach ($action in $task.Actions) {
                $action.Job.Results | Select-Object 'DateTime',
                @{
                    Name       = 'TaskName'
                    Expression = { $task.TaskName }
                },
                @{
                    Name       = 'SftpServer'
                    Expression = { $task.Sftp.ComputerName }
                },
                @{
                    Name       = 'ComputerName'
                    Expression = { $action.ComputerName }
                },
                'Source',
                'Destination',
                'FileName',
                @{
                    Name       = 'FileSize'
                    Expression = { $_.FileLength / 1KB }
                },
                @{
                    Name       = 'Actions'
                    Expression = { $_.Actions -join ', ' }
                },
                @{
                    Name       = 'Errors'
                    Expression = { $_.Errors -join ', ' }
                }
            }
        }
        #endregion

        $mailParams = @{}

        if ($ReportOnly -or $exportToExcel) {
            #region Get Excel file path
            $excelFileLogParams = @{
                LogFolder    = $logParams.LogFolder
                Format       = 'yyyy-MM-dd'
                Name         = "$ScriptName - $((Split-Path $ImportFile -Leaf).TrimEnd('.json')) - Log.xlsx"
                Date         = 'ScriptStartTime'
                NoFormatting = $true
            }

            $excelParams = @{
                Path          = New-LogFileNameHC @excelFileLogParams
                AutoNameRange = $true
                Append        = $true
                AutoSize      = $true
                FreezeTopRow  = $true
                WorksheetName = 'Overview'
                TableName     = 'Overview'
                Verbose       = $false
            }

            Write-Verbose "Excel file path '$($excelParams.Path)'"
            #endregion

            #region Add results from Excel file
            if (
                ($ReportOnly) -and
                (Test-Path -LiteralPath $excelParams.Path -PathType 'Leaf')
            ) {
                Write-Verbose 'Import Excel file'

                $importExcelParams = @{
                    Path          = $excelParams.Path
                    WorksheetName = $excelParams.WorksheetName
                }
                $excelFile = Import-Excel @importExcelParams

                $mailParams.Attachments = $excelParams.Path

                Write-Verbose 'Add results from Excel file'

                foreach ($row in $excelFile) {
                    foreach (
                        $task in
                        $Tasks.where({ $_.TaskName -eq $row.TaskName }, 'First')
                    ) {
                        Write-Verbose "Task '$($task.TaskName)'"

                        foreach (
                            $action in
                            $task.Actions.where(
                                { $_.ComputerName -eq $row.ComputerName }, 'First'
                            )
                        ) {
                            foreach (
                                $path in
                                $action.Paths.where(
                                    {
                                        ($_.Source -eq $row.Source) -and
                                        ($_.Destination -eq $row.Destination)
                                    }, 'First'
                                )
                            ) {
                                $action.Job.Results += $row
                            }
                        }
                    }
                }
            }
            #endregion
        }

        #region Create HTML table
        Write-Verbose 'Create HTML table'

        $htmlTable = @('<table>')

        foreach ($task in $Tasks) {
            Write-Verbose "Task '$($task.TaskName)'"

            #region Create HTML table header
            $htmlTable += "
                <tr style=`"background-color: lightgrey;`">
                    <th style=`"text-align: center;`" colspan=`"2`">$($task.TaskName)</th>
                    <th>sftp:/$($task.SFTP.ComputerName)</th>
                </tr>
                <tr>
                    <th>Source</th>
                    <th>Destination</th>
                    <th>Result</th>
                </tr>"
            #endregion

            foreach ($action in $task.Actions) {
                #region Counter
                $counter.Action = @{
                    MovedFiles = 0
                    Errors     = 0
                }

                $counter.Action.MovedFiles = $action.Job.Results.Where(
                    {
                        (-not $_.Errors) -and 
                        ($_.Moved) 
                    }
                ).Count

                $counter.Action.Errors = $action.Job.Results.Where(
                    { $_.Errors }).Count

                $counter.Total.Errors += $counter.Action.Errors
                $counter.Total.Errors += $action.Job.Error.Count

                $counter.Total.MovedFiles += $counter.Action.MovedFiles
                #endregion

                #region Log errors
                if ($counter.Action.Errors) {
                    $action.Job.Results.Where(
                        { $_.Error }
                    ).foreach(
                        {
                            $M = "Error for TaskName '$($task.TaskName)' Sftp.ComputerName '$($task.Sftp.ComputerName)' ComputerName '$($action.ComputerName)' Source '$($_.Source)' Destination '$($_.Destination)' FileName '$($_.FileName)': $($_.Error)"
                            Write-Warning $M
                            Write-EventLog @EventErrorParams -Message $M
                        }
                    )
                }
                #endregion

                #region Create HTML Error row
                if ($action.Job.Error) {
                    $htmlTable += "
                    <tr style=`"background-color: #f78474;`">
                        <td colspan=`"3`">ERROR: $($action.Job.Error)</td>
                    </tr>"

                    $M = "Error for TaskName '$($task.TaskName)' Sftp.ComputerName '$($task.Sftp.ComputerName)' ComputerName '$($action.ComputerName)' {0}: $($action.Job.Error)" -f
                    $(
                        $action.Paths.ForEach(
                            {
                                "Source '$($_.Source)' Destination '$($_.Destination)'"
                            }
                        )
                    )
                    Write-Warning $M
                    Write-EventLog @EventErrorParams -Message $M
                }
                #endregion

                foreach ($path in $action.Paths) {
                    #region Counter
                    $counter.Path = @{
                        MovedFiles = 0
                        Errors     = 0
                    }

                    $counter.Path.Errors += $action.Job.Results.Where(
                        {
                        ($_.Errors) -and
                        ($_.Source -eq $path.Source) -and
                        ($_.Destination -eq $path.Destination)
                        }).Count

                    $counter.Path.MovedFiles += $action.Job.Results.Where(
                        {
                        (-not $_.Errors) -and
                        ($_.Source -eq $path.Source) -and
                        ($_.Destination -eq $path.Destination) -and
                        ($_.Moved)
                        }).Count
                    #endregion

                    #region Create HTML table row
                    $htmlTable += "
                        $(
                            if (
                                $action.Job.Error.Count -or
                                $counter.Path.Errors
                            ) {
                                '<tr style="background-color: #f78474">'
                            }
                            else {
                                '<tr>'
                            }
                        )
                        <td>
                            $($path.Source)
                        </td>
                        <td>
                            $($path.Destination)
                        </td>
                        <td>
                            $(
                                $result = "$($counter.Path.MovedFiles) moved"

                                if ($counter.Path.Errors) {
                                    $result += ', {0} error{1}' -f
                                    $(
                                        $counter.Path.Errors
                                    ),
                                    $(
                                        if($counter.Path.Errors -ne 1) {'s'}
                                    )
                                }

                                $result
                            )
                        </td>
                    </tr>"
                    #endregion
                }

                #region Create HTML Action summary row
                $htmlTable += "
                <tr>
                    <th colspan=`"2`"></th>
                    <th>$($counter.Action.MovedFiles) moved on $($action.ComputerName)</th>
                </tr>"
                #endregion
            }
        }

        $htmlTable += '</table>'
        #endregion

        #region Create Excel worksheet Overview
        $createExcelFile = $false

        if (
            ($exportToExcel) -and
            (
                (
                    ($file.ExportExcelFile.When -eq 'OnlyOnError') -and
                    ($counter.Total.Errors)
                ) -or
                (
                    (
                        $file.ExportExcelFile.When -eq 'OnlyOnErrorOrAction'
                    ) -and
                    (
                        ($counter.Total.Errors) -or
                        ($counter.Total.MovedFiles)
                    )
                )
            )
        ) {
            $createExcelFile = $true
        }

        if ($createExcelFile) {
            $M = "Export {0} rows to Excel sheet '{1}'" -f
            $exportToExcel.Count, $excelParams.WorksheetName
            Write-Verbose $M; Write-EventLog @EventOutParams -Message $M

            $exportToExcel | Export-Excel @excelParams -CellStyleSB {
                Param (
                    $WorkSheet,
                    $TotalRows,
                    $LastColumn
                )

                @($WorkSheet.Names['FileSize'].Style).ForEach(
                    { $_.NumberFormat.Format = '0.00\ \K\B' }
                )
            }

            $mailParams.Attachments = $excelParams.Path
        }
        #endregion

        #region Mail subject and priority
        $mailParams += @{
            Priority = 'Normal'
            Subject  = @("$($counter.Total.MovedFiles) moved")
        }

        if ($counter.Total.Errors) {
            $mailParams.Priority = 'High'
            $mailParams.Subject += '{0} error{1}' -f
            $counter.Total.Errors,
            $(if ($counter.Total.Errors -ne 1) { 's' })
        }

        $mailParams.Subject = $mailParams.Subject -join ', '
        #endregion

        #region Check to send mail to user
        $sendMailToUser = $false

        if (
            (
                $ReportOnly
            ) -or
            (
                $file.SendMail.When -eq 'Always'
            ) -or
            (
                ($file.SendMail.When -eq 'OnlyOnError') -and
                ($counter.Total.Errors)
            ) -or
            (
                ($file.SendMail.When -eq 'OnlyOnErrorOrAction') -and
                (
                    ($counter.Total.Errors) -or
                    ($counter.Total.MovedFiles)
                )
            )
        ) {
            $sendMailToUser = $true
        }
        #endregion

        #region Send mail
        $mailParams += @{
            To             = $file.SendMail.To
            Message        = "
                            $systemErrorsHtmlList
                            $(
                                if ($ReportOnly) {
                                    '<p>Summary of all SFTP actions <b>executed today</b>:</p>'
                                }
                                else {
                                    '<p>Summary of SFTP actions:</p>'
                                }
                            )
                            $htmlTable"
            LogFolder      = $LogParams.LogFolder
            Header         = $ScriptName
            EventLogSource = $ScriptName
            Save           = $LogFile + ' - Mail.html'
            ErrorAction    = 'Stop'
        }

        if ($mailParams.Attachments) {
            $mailParams.Message +=
            '<p><i>* Check the attachment for details</i></p>'
        }

        Get-ScriptRuntimeHC -Stop

        if ($sendMailToUser) {
            Write-Verbose 'Send e-mail to the user'

            if ($counter.Total.Errors) {
                $mailParams.Bcc = $ScriptAdmin
            }
            Send-MailHC @mailParams
        }
        else {
            Write-Verbose 'Send no e-mail to the user'

            if ($counter.Total.Errors) {
                Write-Verbose 'Send e-mail to admin only with errors'

                $mailParams.To = $ScriptAdmin
                Send-MailHC @mailParams
            }
        }
        #endregion
    }
    catch {
        Write-Warning $_
        Send-MailHC -To $ScriptAdmin -Subject 'FAILURE' -Priority 'High' -Message $_ -Header $ScriptName
        Write-EventLog @EventErrorParams -Message "FAILURE:`n`n- $_"
        Exit 1
    }
    Finally {
        Write-EventLog @EventEndParams
    }
}