#Requires -Version 7

<#
.SYNOPSIS
    Download files from an SFTP server or upload files to an SFTP server.

.DESCRIPTION
    Read an input file that contains all the parameters for this script.

    The computer that is running the SFTP code should have the module 'Posh-SSH'
    installed.

    Tasks will always run in sequential order, one after the other. Actions run
    in parallel when MaxConcurrentActions is more than 1.

.PARAMETER ConfigurationJsonFile
    Contains all the parameters used by the script.
    See 'Example.json' for a detailed explanation of parameters.

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
    [String]$ConfigurationJsonFile,
    [Switch]$ReportOnly,
    [HashTable]$ScriptPath = @{
        MoveFile = "$PSScriptRoot\Move file.ps1"
    }
)

Begin {
    $ErrorActionPreference = 'stop'

    $eventLogData = [System.Collections.Generic.List[PSObject]]::new()
    $logFileData = [System.Collections.Generic.List[PSObject]]::new()
    $systemErrors = [System.Collections.Generic.List[PSObject]]::new()
    $scriptStartTime = Get-Date

    Try {
        function ConvertTo-SentenceHC {
            <#
                .SYNOPSIS
                    Create a comma separated sentence from an
                    array of strings, with the first letter
                    in capitals.

                .EXAMPLE
                    ConvertTo-SentenceHC @('kiwi is great', 'bananas are not')
                    # returns: 'Kiwi is great, bananas are not'
            #>

            [OutputType([string])]
            Param (
                [string[]]$text
            )

            if (-not $text) {
                return
            }

            $sentence = $text -join ', '

            $firstLetter = $sentence.Substring(0, 1).ToUpper()
            $remainingSentence = $sentence.Substring(1)
            $capitalizedSentence = $firstLetter + $remainingSentence

            $capitalizedSentence
        }

        Function Get-EnvironmentVariableValueHC {
            Param(
                [String]$Name
            )

            [Environment]::GetEnvironmentVariable($Name)
        }
      
        function Test-IsValidRegexHC {
            param(
                [Parameter(Mandatory)]
                [string]$Regex
            )
            try {
                $null = [regex]::IsMatch('', $Regex)

                return $true
            }
            catch {
                return $false
            }
        }

        $eventLogData.Add(
            [PSCustomObject]@{
                Message   = 'Script started'
                DateTime  = $scriptStartTime
                EntryType = 'Information'
                EventID   = '100'
            }
        )

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

        #region Import .json file
        Write-Verbose "Import .json file '$ConfigurationJsonFile'"

        $jsonFileItem = Get-Item -LiteralPath $ConfigurationJsonFile -ErrorAction Stop

        $jsonFileContent = Get-Content $jsonFileItem -Raw -Encoding UTF8 |
        ConvertFrom-Json
        #endregion

        #region Test .json file properties
        Write-Verbose 'Test .json file properties'

        try {
            @(
                'MaxConcurrentActions', 'SendMail', 'ExportExcelFile', 'Tasks'
            ).where(
                { -not $jsonFileContent.$_ }
            ).foreach(
                { throw "Property '$_' not found" }
            )

            #region Test SendMail
            @('To', 'When').Where(
                { -not $jsonFileContent.SendMail.$_ }
            ).foreach(
                { throw "Property 'SendMail.$_' not found" }
            )

            if ($jsonFileContent.SendMail.When -notMatch '^Never$|^Always$|^OnlyOnError$|^OnlyOnErrorOrAction$') {
                throw "Property 'SendMail.When' with value '$($jsonFileContent.SendMail.When)' is not valid. Accepted values are 'Always', 'Never', 'OnlyOnError' or 'OnlyOnErrorOrAction'"
            }
            #endregion

            #region Test ExportExcelFile
            @('When').Where(
                { -not $jsonFileContent.ExportExcelFile.$_ }
            ).foreach(
                { throw "Property 'ExportExcelFile.$_' not found" }
            )

            if ($jsonFileContent.ExportExcelFile.When -notMatch '^Never$|^OnlyOnError$|^OnlyOnErrorOrAction$') {
                throw "Property 'ExportExcelFile.When' with value '$($jsonFileContent.ExportExcelFile.When)' is not valid. Accepted values are 'Never', 'OnlyOnError' or 'OnlyOnErrorOrAction'"
            }
            #endregion

            #region Test integer value
            try {
                [int]$MaxConcurrentActions = $jsonFileContent.MaxConcurrentActions
            }
            catch {
                throw "Property 'MaxConcurrentActions' needs to be a number, the value '$($jsonFileContent.MaxConcurrentActions)' is not supported."
            }
            #endregion

            $Tasks = $jsonFileContent.Tasks

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

                @('MatchFileNameRegex').where(
                    { -not $task.Option.$_ }
                ).foreach(
                    { throw "Property 'Tasks.Option.$_' not found" }
                )

                if (-not 
                    (Test-IsValidRegexHC $task.Option.MatchFileNameRegex)
                ) {
                    throw "Property 'Tasks.Option.MatchFileNameRegex' with value '$($task.Option.MatchFileNameRegex)' is not a valid regex pattern."
                }

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
            throw "Input file '$ConfigurationJsonFile': $_"
        }
        #endregion

        #region Convert .json file
        Write-Verbose 'Convert .json file'

        #region Set PSSessionConfiguration
        $PSSessionConfiguration = $jsonFileContent.PSSessionConfiguration

        if (-not $PSSessionConfiguration) {
            $PSSessionConfiguration = 'PowerShell.7'
        }
        #endregion

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

                #region Set SFTP port
                if (-not $task.Sftp.Port) {
                    $task.Sftp.Port = 22
                }
                else {
                    #region Test integer value
                    try {
                        [int]$task.Sftp.Port = $task.Sftp.Port

                        if (
                            $task.Sftp.Port -lt 0 -or 
                            $task.Sftp.Port -gt 65535
                        ) {
                            throw 'a negative number is not supported'
                        }
                    }
                    catch {
                        throw "Property 'Tasks.Sftp.Port' must be a valid TCP port number between 0 and 65535. The value '$($task.Sftp.Port)' is not supported."
                    }
                    #endregion
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
            throw "Input file '$ConfigurationJsonFile': $_"
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
                    if (-not $MaxConcurrentActions) {
                        $task = $using:task
                        $psSessions = $using:psSessions
                        $MaxConcurrentActions = $using:MaxConcurrentActions
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
                        $MaxConcurrentActions,
                        $task.Sftp.Port,
                        $task.Sftp.Credential.PasswordKeyFile,
                        $task.Option.FileExtensions,
                        $task.Option.OverwriteFile
                    }

                    $M = "Start task '{0}' on '{1}' with: Sftp.ComputerName '{2}' Paths {3} MaxConcurrentActions '{4}' Sftp.Port '{5}' FileExtensions '{6}' OverwriteFile '{7}'" -f
                    $task.TaskName,
                    $action.ComputerName,
                    $invokeParams.ArgumentList[0],
                    $(
                        $invokeParams.ArgumentList[2].foreach(
                            { "Source '$($_.Source)' Destination '$($_.Destination)'" }
                        ) -join ', '
                    ),
                    $invokeParams.ArgumentList[3],
                    $invokeParams.ArgumentList[4],
                    $($invokeParams.ArgumentList[6] -join ', '),
                    $invokeParams.ArgumentList[7]
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
                        $SftpPort = $null
                        $SftpOpenSshKeyFile = $null
                        $FileExtensions = $null
                        $OverwriteFile = $null
                        $AttemptCount = $null
                        $WaitSecondsBetweenAttempts = $null

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
                        $M = "Result task '{0}' on '{1}' with: Sftp.ComputerName '{2}' Paths {3} MaxConcurrentActions '{4}' FileExtensions '{5}' OverwriteFile '{6}': {7} object{8}" -f
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
            $foreachParams = if ($MaxConcurrentActions -eq 1) {
                @{
                    Process = $scriptBlock
                }
            }
            else {
                @{
                    Parallel      = $scriptBlock
                    ThrottleLimit = $MaxConcurrentActions
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
                    Name       = 'SourceComputer'
                    Expression = {
                        if ($_.Source.startsWith('sftp')) {
                            $task.Sftp.ComputerName
                        }
                        else {
                            $action.ComputerName
                        }
                    }
                },
                @{
                    Name       = 'DestinationComputer'
                    Expression = {
                        if ($_.Source.startsWith('sftp')) {
                            $action.ComputerName
                        }
                        else {
                            $task.Sftp.ComputerName
                        }
                    }
                },
                @{
                    Name       = 'SourcePath'
                    Expression = { $_.Source }
                },
                @{
                    Name       = 'DestinationPath'
                    Expression = { $_.Destination }
                },
                'FileName',
                @{
                    Name       = 'FileSize'
                    Expression = { $_.FileLength / 1KB }
                },
                'Moved',
                @{
                    Name       = 'Actions'
                    Expression = { ConvertTo-SentenceHC $_.Actions }
                },
                @{
                    Name       = 'Errors'
                    Expression = { ConvertTo-SentenceHC $_.Errors }
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
                Name         = "$ScriptName - $((Split-Path $ConfigurationJsonFile -Leaf).TrimEnd('.json')) - Log.xlsx"
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

                foreach ($task in $Tasks) {
                    Write-Verbose "Task '$($task.TaskName)'"

                    foreach ($action in $task.Actions) {
                        Write-Verbose "Action ComputerName '$($action.ComputerName)'"

                        foreach ($path in $action.Paths) {
                            Write-Verbose "Path source '$($path.Source)' destination '$($path.Destination)'"

                            $excelFileJobResults = $excelFile | Where-Object {
                                ($path.Source -eq $_.SourcePath) -and
                                ($path.Destination -eq $_.DestinationPath) -and (
                                    ($_.SourcePath.startsWith('sftp') -and $action.ComputerName -eq $_.DestinationComputer) -or
                                    ($_.DestinationPath.startsWith('sftp') -and $action.ComputerName -eq $_.SourceComputer)
                                )
                            }

                            if (-not $excelFileJobResults) {
                                continue
                            }

                            $action.Job.Results += $excelFileJobResults | Select-Object -Property *, @{
                                Name       = 'Source'
                                Expression = { $_.SourcePath }
                            },
                            @{
                                Name       = 'Destination'
                                Expression = { $_.DestinationPath }
                            },
                            @{
                                Name       = 'ComputerName'
                                Expression = {
                                    if ($_.SourcePath.startsWith('sftp')) {
                                        $_.DestinationComputer
                                    }
                                    else {
                                        $_.SourceComputer
                                    }
                                }
                            },
                            @{
                                Name       = 'SftpServer'
                                Expression = {
                                    if ($_.SourcePath.startsWith('sftp')) {
                                        $_.SourceComputer
                                    }
                                    else {
                                        $_.DestinationComputer
                                    }
                                }
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
                    { $_.Moved }
                ).Count

                $counter.Action.Errors = $action.Job.Results.Where(
                    { $_.Errors }
                ).Count

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

                $actionPaths = $action.Paths

                #region Get temp moved files too
                $jobResultPaths = $action.Job.Results.Where(
                    {
                        ($actionPaths.Source -notcontains $_.Source) -or
                        ($actionPaths.Destination -notcontains $_.Destination)
                    }
                )

                $allPaths = $jobResultPaths + $actionPaths |
                Sort-Object -Property {
                    '{0}-{1}' -f $_.Source, $_.Destination
                } -Unique
                #endregion

                foreach ($path in $allPaths) {
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
                    ($jsonFileContent.ExportExcelFile.When -eq 'OnlyOnError') -and
                    ($counter.Total.Errors)
                ) -or
                (
                    (
                        $jsonFileContent.ExportExcelFile.When -eq 'OnlyOnErrorOrAction'
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
                $jsonFileContent.SendMail.When -eq 'Always'
            ) -or
            (
                ($jsonFileContent.SendMail.When -eq 'OnlyOnError') -and
                ($counter.Total.Errors)
            ) -or
            (
                ($jsonFileContent.SendMail.When -eq 'OnlyOnErrorOrAction') -and
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
            To             = $jsonFileContent.SendMail.To
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

        $null = Get-ScriptRuntimeHC -Stop

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