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

        function Get-StringValueHC {
            <#
        .SYNOPSIS
            Retrieve a string from the environment variables or a regular string.

        .DESCRIPTION
            This function checks the 'Name' property. If the value starts with
            'ENV:', it attempts to retrieve the string value from the specified
            environment variable. Otherwise, it returns the value directly.

        .PARAMETER Name
            Either a string starting with 'ENV:'; a plain text string or NULL.

        .EXAMPLE
            Get-StringValueHC -Name 'ENV:passwordVariable'

            # Output: the environment variable value of $ENV:passwordVariable
            # or an error when the variable does not exist

        .EXAMPLE
            Get-StringValueHC -Name 'mySecretPassword'

            # Output: mySecretPassword

        .EXAMPLE
            Get-StringValueHC -Name ''

            # Output: NULL
        #>
            param (
                [String]$Name
            )

            if (-not $Name) {
                return $null
            }
            elseif (
                $Name.StartsWith('ENV:', [System.StringComparison]::OrdinalIgnoreCase)
            ) {
                $envVariableName = $Name.Substring(4).Trim()
                $envStringValue = Get-Item -Path "Env:\$envVariableName" -EA Ignore
                if ($envStringValue) {
                    return $envStringValue.Value
                }
                else {
                    throw "Environment variable '$envVariableName' not found."
                }
            }
            else {
                return $Name
            }
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
                'MaxConcurrentActions', 'Tasks'
            ).where(
                { -not $jsonFileContent.$_ }
            ).foreach(
                { throw "Property '$_' not found" }
            )

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
                    @('Paths').where(
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
                Write-Verbose "Task '$($task.TaskName)'"

                #region Get SFTP UserName
                try {
                    if (-not (
                            $SftpUserName = Get-StringValueHC -Name $task.Sftp.Credential.UserName)
                    ) {
                        throw 'The value cannot be blank.'
                    }
                }
                catch {
                    throw "Failed retrieving 'Sftp.Credential.UserName': $_"
                }
                #endregion

                #region Get SFTP password
                $sftpPassword = if ($task.Sftp.Credential.PasswordKeyFile) {
                    try {
                        if (-not 
                            ($sftpPasswordKeyFileValue = Get-StringValueHC -Name $task.Sftp.Credential.PasswordKeyFile)
                        ) {
                            throw 'The value cannot be blank.'
                        }
                    }
                    catch {
                        throw "Failed retrieving 'Sftp.Credential.PasswordKeyFile': $_"
                    }   

                    try {
                        $PasswordKeyFileStrings = Get-Content -LiteralPath $sftpPasswordKeyFileValue

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
                    
                    try {
                        if (-not (
                                $params.String = Get-StringValueHC -Name $task.Sftp.Credential.Password)
                        ) {
                            throw 'The value cannot be blank.'
                        }    
                    }
                    catch {
                        throw "Failed retrieving 'Sftp.Credential.Password': $_"
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
                    Write-Verbose "No 'Tasks.Sftp.Port' found, set default value"

                    $task.Sftp | Add-Member -NotePropertyMembers @{
                        Port = 22
                    } -Force
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

                Write-Verbose "Sftp port '$($task.Sftp.Port)'"
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

                    Write-Verbose "Action ComputerName '$($action.ComputerName)'"
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
        $systemErrors.Add(
            [PSCustomObject]@{
                DateTime = Get-Date
                Message  = "Input file '$ConfigurationJsonFile': $_"
            }
        )

        Write-Warning $systemErrors[-1].Message

        return
    }
}

Process {
    if ($systemErrors) { return }

    Try {
        if ($ReportOnly) {
            Write-Verbose 'Only report results of the current day'  
        }
        else {
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
                        $eventLogData = $using:eventLogData
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
                        $task.Option.MatchFileNameRegex,
                        $task.Sftp.Credential.PasswordKeyFile,
                        $task.Option.OverwriteFile
                    }

                    $M = "Start task '{0}' on '{1}' with: Sftp.ComputerName '{2}' Paths {3} MaxConcurrentActions '{4}' Sftp.Port '{5}' MatchFileNameRegex '{6}'  OverwriteFile '{7}'" -f
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
                    $invokeParams.ArgumentList[5],
                    $invokeParams.ArgumentList[7]

                    Write-Verbose $M

                    $eventLogData.Add(
                        [PSCustomObject]@{
                            Message   = $M
                            DateTime  = Get-Date
                            EntryType = 'Information'
                            EventID   = '2'
                        }
                    )
                    #endregion

                    #region Start job
                    $computerName = $action.ComputerName

                    $action.Job.Results += if (
                        $computerName -eq $ENV:COMPUTERNAME
                    ) {
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
                        $MatchFileNameRegex = $null
                        $SftpOpenSshKeyFile = $null
                        $OverwriteFile = $null
                        $AttemptCount = $null
                        $WaitSecondsBetweenAttempts = $null

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

                    #region Verbose job results
                    $M = "Result task '{0}' on '{1}' with: Sftp.ComputerName '{2}' Paths {3} MaxConcurrentActions '{4}' MatchFileNameRegex '{5}' OverwriteFile '{6}': {7} object{8}" -f
                    $task.TaskName,
                    $action.ComputerName,
                    $invokeParams.ArgumentList[0],
                    $(
                        $invokeParams.ArgumentList[2].foreach(
                            { "Source '$($_.Source)' Destination '$($_.Destination)'" }
                        ) -join ', '
                    ),
                    $invokeParams.ArgumentList[3],
                    $invokeParams.ArgumentList[5],
                    $invokeParams.ArgumentList[7],
                    $action.Job.Results.Count,
                    $(if ($action.Job.Results.Count -ne 1) { 's' })

                    $eventLogData.Add(
                        [PSCustomObject]@{
                            Message   = $M
                            DateTime  = Get-Date
                            EntryType = 'Information'
                            EventID   = '2'
                        }
                    )

                    Write-Verbose $M
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
    }
    Catch {
        $systemErrors.Add(
            [PSCustomObject]@{
                DateTime = Get-Date
                Message  = $_
            }
        )

        Write-Warning $systemErrors[-1].Message
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
    function Out-LogFileHC {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory)]
            [PSCustomObject[]]$DataToExport,
            [Parameter(Mandatory)]
            [String]$PartialPath,
            [Parameter(Mandatory)]
            [String[]]$FileExtensions,
            [hashtable]$ExcelFile = @{
                SheetName = 'Overview'
                TableName = 'Overview'
                CellStyle = $null
            },
            [Switch]$Append
        )
    
        $allLogFilePaths = @()
    
        foreach (
            $fileExtension in
            $FileExtensions | Sort-Object -Unique
        ) {
            try {
                $logFilePath = "$PartialPath{0}" -f $fileExtension
    
                $M = "Export {0} object{1} to '$logFilePath'" -f
                $DataToExport.Count,
                $(if ($DataToExport.Count -ne 1) { 's' })
                Write-Verbose $M
    
                switch ($fileExtension) {
                    '.csv' {
                        $params = @{
                            LiteralPath       = $logFilePath
                            Append            = $Append
                            Delimiter         = ';'
                            NoTypeInformation = $true
                        }
                        $DataToExport | Export-Csv @params
    
                        break
                    }
                    '.json' {
                        #region Convert error object to error message string
                        $convertedDataToExport = foreach (
                            $exportObject in
                            $DataToExport
                        ) {
                            foreach ($property in $exportObject.PSObject.Properties) {
                                $name = $property.Name
                                $value = $property.Value
                                if (
                                    $value -is [System.Management.Automation.ErrorRecord]
                                ) {
                                    if (
                                        $value.Exception -and $value.Exception.Message
                                    ) {
                                        $exportObject.$name = $value.Exception.Message
                                    }
                                    else {
                                        $exportObject.$name = $value.ToString()
                                    }
                                }
                            }
                            $exportObject
                        }
                        #endregion
    
                        if (
                            $Append -and 
                            (Test-Path -LiteralPath $logFilePath -PathType Leaf)
                        ) {
                            $params = @{
                                LiteralPath = $logFilePath 
                                Raw         = $true
                                Encoding    = 'UTF8'
                            }
                            $jsonFileContent = Get-Content @params | ConvertFrom-Json
    
                            $convertedDataToExport = [array]$convertedDataToExport + [array]$jsonFileContent
                        }
    
                        $convertedDataToExport |
                        ConvertTo-Json -Depth 7 |
                        Out-File -LiteralPath $logFilePath
    
                        break
                    }
                    '.txt' {
                        $params = @{
                            LiteralPath = $logFilePath 
                            Append      = $Append
                        }
    
                        $DataToExport | Format-List -Property * -Force |
                        Out-File @params
    
                        break
                    }
                    '.xlsx' {
                        if (
                            (-not $Append) -and 
                            (Test-Path -LiteralPath $logFilePath -PathType Leaf)
                        ) {
                            $logFilePath | Remove-Item
                        }
    
                        $excelParams = @{
                            Path          = $logFilePath
                            Append        = $true
                            AutoNameRange = $true
                            AutoSize      = $true
                            FreezeTopRow  = $true
                            WorksheetName = $ExcelFile.SheetName
                            TableName     = $ExcelFile.TableName
                            Verbose       = $false
                        }
                        if ($ExcelFile.CellStyle) {
                            $excelParams.CellStyleSB = $ExcelFile.CellStyle
                        }
                        $DataToExport | Export-Excel @excelParams
    
                        break
                    }
                    default {
                        throw "Log file extension '$_' not supported. Supported values are '.csv', '.json', '.txt' or '.xlsx'."
                    }
                }
    
                $allLogFilePaths += $logFilePath
            }
            catch {
                Write-Warning "Failed creating log file '$logFilePath': $_"
            }
        }
    
        $allLogFilePaths
    }

    function Get-LogFolderHC {
        <#
        .SYNOPSIS
            Ensures that a specified path exists, creating it if it doesn't.
            Supports absolute paths and paths relative to $PSScriptRoot. Returns
            the full path of the folder.

            .DESCRIPTION
            This function takes a path as input and checks if it exists. if
            the path does not exist, it attempts to create the folder. It
            handles both absolute paths and paths relative to the location of
            the currently running script ($PSScriptRoot).

            .PARAMETER Path
            The path to ensure exists. This can be an absolute path (ex.
                C:\MyFolder\SubFolder) or a path relative to the script's
            directory (ex. Data\Logs).

        .EXAMPLE
            Get-LogFolderHC -Path 'C:\MyData\Output'
            # Ensures the directory 'C:\MyData\Output' exists.

        .EXAMPLE
            Get-LogFolderHC -Path 'Logs\Archive'
            # If the script is in 'C:\Scripts', this ensures 'C:\Scripts\Logs\Archive' exists.
        #>

        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$Path
        )

        if ($Path -match '^[a-zA-Z]:\\' -or $Path -match '^\\') {
            $fullPath = $Path
        }
        else {
            $fullPath = Join-Path -Path $PSScriptRoot -ChildPath $Path
        }

        if (-not (Test-Path -Path $fullPath -PathType Container)) {
            try {
                Write-Verbose "Create log folder '$fullPath'"
                $null = New-Item -Path $fullPath -ItemType Directory -Force
            }
            catch {
                throw "Failed creating log folder '$fullPath': $_"
            }
        }

        (Resolve-Path $fullPath).Path
        # $fullPath
    }

    function Get-LogFileDataHC {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory)]
            [String]$PartialPath,
            [Parameter(Mandatory)]
            [String[]]$FileExtensions,
            [String]$ExcelFileSheetName = 'Overview'
        )
    
        foreach (
            $fileExtension in
            $FileExtensions | Sort-Object -Unique
        ) {
            try {
                $logFilePath = "$PartialPath{0}" -f $fileExtension
    
                $M = "Log file path '$logFilePath'"
                Write-Verbose $M
    
                if (-not (Test-Path -LiteralPath $logFilePath -PathType Leaf)) {
                    Write-Verbose "Path '$logFilePath' not found"
                    Continue
                }
    
                switch ($fileExtension) {
                    '.csv' {
                        $params = @{
                            LiteralPath = $logFilePath
                            Delimiter   = ';'
                        }
                        return Import-Csv @params
                    }
                    '.json' {
                        $params = @{
                            LiteralPath = $logFilePath 
                            Raw         = $true
                            Encoding    = 'UTF8'
                        }
                        return Get-Content @params | ConvertFrom-Json
                    }
                    '.xlsx' {
                        $params = @{
                            Path          = $logFilePath 
                            WorksheetName = $ExcelFileSheetName
                        }
                        return Import-Excel @params
                    }
                    default {
                        Write-Warning "Log file extension '$_' not supported for reading log data. Supported values are '.csv', '.json' or '.xlsx'."
                    }
                }
            }
            catch {
                Write-Warning "Failed retrieving log file data in '$logFilePath': $_"
            }
        }
    }

    function Send-MailKitMessageHC {
        <#
            .SYNOPSIS
                Send an email using MailKit and MimeKit assemblies.

            .DESCRIPTION
                This function sends an email using the MailKit and MimeKit
                assemblies. It requires the assemblies to be installed before
                calling the function:

                $params = @{
                    Source           = 'https://www.nuget.org/api/v2'
                    SkipDependencies = $true
                    Scope            = 'AllUsers'
                }
                Install-Package @params -Name 'MailKit'
                Install-Package @params -Name 'MimeKit'

            .PARAMETER MailKitAssemblyPath
                The path to the MailKit assembly.

            .PARAMETER MimeKitAssemblyPath
                The path to the MimeKit assembly.

            .PARAMETER SmtpServerName
                The name of the SMTP server.

            .PARAMETER SmtpPort
                The port of the SMTP server.

            .PARAMETER SmtpConnectionType
                The connection type for the SMTP server.

                Valid values are:
                - 'None'
                - 'Auto'
                - 'SslOnConnect'
                - 'StartTlsWhenAvailable'
                - 'StartTls'

            .PARAMETER Credential
                The credential object containing the username and password.

            .PARAMETER From
                The sender's email address.

            .PARAMETER FromDisplayName
            The display name to show for the sender.

            Email clients may display this differently. It is most likely
            to be shown if the sender's email address is not recognized
                (e.g., not in the address book).

            .PARAMETER To
                The recipient's email address.

            .PARAMETER Body
            The body of the email, HTML is supported.

            .PARAMETER Subject
            The subject of the email.

            .PARAMETER Attachments
            An array of file paths to attach to the email.

            .PARAMETER Priority
            The email priority.

            Valid values are:
            - 'Low'
            - 'Normal'
            - 'High'

            .EXAMPLE
            # Send an email with StartTls and credential

            $SmtpUserName = 'smtpUser'
            $SmtpPassword = 'smtpPassword'

            $securePassword = ConvertTo-SecureString -String $SmtpPassword -AsPlainText -Force
            $credential = New-Object System.Management.Automation.PSCredential($SmtpUserName, $securePassword)

            $params = @{
                SmtpServerName = 'SMT_SERVER@example.com'
                SmtpPort = 587
                SmtpConnectionType = 'StartTls'
                Credential = $credential
                from = 'm@example.com'
                To = '007@example.com'
                Body = '<p>Mission details in attachment</p>'
                Subject = 'For your eyes only'
                Priority = 'High'
                Attachments = @('c:\Mission.ppt', 'c:\ID.pdf')
                MailKitAssemblyPath = 'C:\Program Files\PackageManagement\NuGet\Packages\MailKit.4.11.0\lib\net8.0\MailKit.dll'
                MimeKitAssemblyPath = 'C:\Program Files\PackageManagement\NuGet\Packages\MimeKit.4.11.0\lib\net8.0\MimeKit.dll'
            }

            Send-MailKitMessageHC @params

            .EXAMPLE
            # Send an email without authentication

            $params = @{
                SmtpServerName      = 'SMT_SERVER@example.com'
                SmtpPort            = 25
                From                = 'hacker@example.com'
                FromDisplayName     = 'White hat hacker'
                Bcc                 = @('james@example.com', 'mike@example.com')
                Body                = '<h1>You have been hacked</h1>'
                Subject             = 'Oops'
                MailKitAssemblyPath = 'C:\Program Files\PackageManagement\NuGet\Packages\MailKit.4.11.0\lib\net8.0\MailKit.dll'
                MimeKitAssemblyPath = 'C:\Program Files\PackageManagement\NuGet\Packages\MimeKit.4.11.0\lib\net8.0\MimeKit.dll'
            }

            Send-MailKitMessageHC @params
            #>

        [CmdletBinding()]
        param (
            [parameter(Mandatory)]
            [string]$MailKitAssemblyPath,
            [parameter(Mandatory)]
            [string]$MimeKitAssemblyPath,
            [parameter(Mandatory)]
            [string]$SmtpServerName,
            [parameter(Mandatory)]
            [ValidateSet(25, 465, 587, 2525)]
            [int]$SmtpPort,
            [parameter(Mandatory)]
            [string]$Body,
            [parameter(Mandatory)]
            [string]$Subject,
            [parameter(Mandatory)]
            [ValidatePattern('^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$')]
            [string]$From,
            [string]$FromDisplayName,
            [string[]]$To,
            [string[]]$Bcc,
            [int]$MaxAttachmentSize = 20MB,
            [ValidateSet(
                'None', 'Auto', 'SslOnConnect', 'StartTls', 'StartTlsWhenAvailable'
            )]
            [string]$SmtpConnectionType = 'None',
            [ValidateSet('Normal', 'Low', 'High')]
            [string]$Priority = 'Normal',
            [string[]]$Attachments,
            [PSCredential]$Credential
        )

        begin {
            function Test-IsAssemblyLoaded {
                param (
                    [String]$Name
                )
                foreach ($assembly in [AppDomain]::CurrentDomain.GetAssemblies()) {
                    if ($assembly.FullName -like "$Name, Version=*") {
                        return $true
                    }
                }
                return $false
            }

            function Add-Attachments {
                param (
                    [string[]]$Attachments,
                    [MimeKit.Multipart]$BodyMultiPart
                )

                $attachmentList = New-Object System.Collections.ArrayList($null)

                foreach (
                    $attachmentPath in
                    $Attachments | Sort-Object -Unique
                ) {
                    try {
                        #region Test if file exists
                        try {
                            $attachmentItem = Get-Item -LiteralPath $attachmentPath -ErrorAction Stop

                            if ($attachmentItem.PSIsContainer) {
                                Write-Warning "Attachment '$attachmentPath' is a folder, not a file"
                                continue
                            }
                        }
                        catch {
                            Write-Warning "Attachment '$attachmentPath' not found"
                            continue
                        }
                        #endregion

                        $totalSizeAttachments += $attachmentItem.Length
            
                        $null = $attachmentList.Add($attachmentItem)

                        #region Check size of attachments
                        if ($totalSizeAttachments -ge $MaxAttachmentSize) {
                            $M = "The maximum allowed attachment size of {0} MB has been exceeded ({1} MB). No attachments were added to the email. Check the log folder for details." -f
                            ([math]::Round(($MaxAttachmentSize / 1MB))),
                            ([math]::Round(($totalSizeAttachments / 1MB), 2))

                            Write-Warning $M

                            return [PSCustomObject]@{
                                AttachmentLimitExceededMessage = $M
                            }
                        }
                    }
                    catch {
                        Write-Warning "Failed to add attachment '$attachmentPath': $_"
                    }
                }
                #endregion

                foreach (
                    $attachmentItem in
                    $attachmentList
                ) {
                    try {
                        Write-Verbose "Add mail attachment '$($attachmentItem.Name)'"

                        $attachment = New-Object MimeKit.MimePart

                        #region Create a MemoryStream to hold the file content
                        $memoryStream = New-Object System.IO.MemoryStream

                        try {
                            $fileStream = [System.IO.File]::OpenRead($attachmentItem.FullName)
                            $fileStream.CopyTo($memoryStream)
                        }
                        finally {
                            if ($fileStream) {
                                $fileStream.Dispose()
                            }
                        }

                        $memoryStream.Position = 0
                        #endregion

                        $attachment.Content = New-Object MimeKit.MimeContent($memoryStream)

                        $attachment.ContentDisposition = New-Object MimeKit.ContentDisposition

                        $attachment.ContentTransferEncoding = [MimeKit.ContentEncoding]::Base64

                        $attachment.FileName = $attachmentItem.Name

                        $bodyMultiPart.Add($attachment)
                    }
                    catch {
                        Write-Warning "Failed to add attachment '$attachmentItem': $_"
                    }
                }
            }

            try {
                #region Test To or Bcc required
                if (-not ($To -or $Bcc)) {
                    throw "Either 'To' to 'Bcc' is required for sending emails"
                }
                #endregion

                #region Test To
                foreach ($email in $To) {
                    if ($email -notmatch '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$') {
                        throw "To email address '$email' not valid."
                    }
                }
                #endregion

                #region Test Bcc
                foreach ($email in $Bcc) {
                    if ($email -notmatch '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$') {
                        throw "Bcc email address '$email' not valid."
                    }
                }
                #endregion

                #region Load MimeKit assembly
                if (-not(Test-IsAssemblyLoaded -Name 'MimeKit')) {
                    try {
                        Write-Verbose "Load MimeKit assembly '$MimeKitAssemblyPath'"
                        Add-Type -Path $MimeKitAssemblyPath
                    }
                    catch {
                        throw "Failed to load MimeKit assembly '$MimeKitAssemblyPath': $_"
                    }
                }
                #endregion

                #region Load MailKit assembly
                if (-not(Test-IsAssemblyLoaded -Name 'MailKit')) {
                    try {
                        Write-Verbose "Load MailKit assembly '$MailKitAssemblyPath'"
                        Add-Type -Path $MailKitAssemblyPath
                    }
                    catch {
                        throw "Failed to load MailKit assembly '$MailKitAssemblyPath': $_"
                    }
                }
                #endregion
            }
            catch {
                throw "Failed to send email to '$To': $_"
            }
        }

        process {
            try {
                $message = New-Object -TypeName 'MimeKit.MimeMessage'

                #region Create body with attachments
                $bodyPart = New-Object MimeKit.TextPart('html')
                $bodyPart.Text = $Body

                $bodyMultiPart = New-Object MimeKit.Multipart('mixed')
                $bodyMultiPart.Add($bodyPart)

                if ($Attachments) {
                    $params = @{
                        Attachments   = $Attachments
                        BodyMultiPart = $bodyMultiPart
                    }
                    $addAttachments = Add-Attachments @params

                    if ($addAttachments.AttachmentLimitExceededMessage) {
                        $bodyPart.Text += '<p><i>{0}</i></p>' -f
                        $addAttachments.AttachmentLimitExceededMessage
                    }
                }

                $message.Body = $bodyMultiPart
                #endregion

                $fromAddress = New-Object MimeKit.MailboxAddress(
                    $FromDisplayName, $From
                )
                $message.From.Add($fromAddress)

                foreach ($email in $To) {
                    $message.To.Add($email)
                }

                foreach ($email in $Bcc) {
                    $message.Bcc.Add($email)
                }

                $message.Subject = $Subject

                #region Set priority
                switch ($Priority) {
                    'Low' {
                        $message.Headers.Add('X-Priority', '5 (Lowest)')
                        break
                    }
                    'Normal' {
                        $message.Headers.Add('X-Priority', '3 (Normal)')
                        break
                    }
                    'High' {
                        $message.Headers.Add('X-Priority', '1 (Highest)')
                        break
                    }
                    default {
                        throw "Priority type '$_' not supported"
                    }
                }
                #endregion

                $smtp = New-Object -TypeName 'MailKit.Net.Smtp.SmtpClient'

                try {
                    $smtp.Connect(
                        $SmtpServerName, $SmtpPort,
                        [MailKit.Security.SecureSocketOptions]::$SmtpConnectionType
                    )
                }
                catch {
                    throw "Failed to connect to SMTP server '$SmtpServerName' on port '$SmtpPort' with connection type '$SmtpConnectionType': $_"
                }

                if ($Credential) {
                    try {
                        $smtp.Authenticate(
                            $Credential.UserName,
                            $Credential.GetNetworkCredential().Password
                        )
                    }
                    catch {
                        throw "Failed to authenticate with user name '$($Credential.UserName)' to SMTP server '$SmtpServerName': $_"
                    }
                }

                Write-Verbose "Send mail to '$To' with subject '$Subject'"

                $null = $smtp.Send($message)
            }
            catch {
                throw "Failed to send email to '$To': $_"
            }
            finally {
                if ($smtp) {
                    $smtp.Disconnect($true)
                    $smtp.Dispose()
                }
                if ($message) {
                    $message.Dispose()
                }
            }
        }
    }

    function Write-EventsToEventLogHC {
        <#
        .SYNOPSIS
            Write events to the event log.

        .DESCRIPTION
            The use of this function will allow standardization in the Windows
            Event Log by using the same EventID's and other properties across
            different scripts.

            Custom Windows EventID's based on the PowerShell standard streams:

            PowerShell Stream     EventIcon    EventID   EventDescription
            -----------------     ---------    -------   ----------------
            [i] Info              [i] Info     100       Script started
            [4] Verbose           [i] Info     4         Verbose message
            [1] Output/Success    [i] Info     1         Output on success
            [3] Warning           [w] Warning  3         Warning message
            [2] Error             [e] Error    2         Fatal error message
            [i] Info              [i] Info     199       Script ended successfully

        .PARAMETER Source
            Specifies the script name under which the events will be logged.

        .PARAMETER LogName
            Specifies the name of the event log to which the events will be
            written. If the log does not exist, it will be created.

        .PARAMETER Events
            Specifies the events to be written to the event log. This should be
            an array of PSCustomObject with properties: Message, EntryType, and
            EventID.

        .PARAMETER Events.xxx
            All properties that are not 'EntryType' or 'EventID' will be used to
            create a formatted message.

        .PARAMETER Events.EntryType
            The type of the event.

            The following values are supported:
            - Information
            - Warning
            - Error
            - SuccessAudit
            - FailureAudit

            The default value is Information.

        .PARAMETER Events.EventID
            The ID of the event. This should be a number.
            The default value is 4.

        .EXAMPLE
            $eventLogData = [System.Collections.Generic.List[PSObject]]::new()

            $eventLogData.Add(
                [PSCustomObject]@{
                    Message   = 'Script started'
                    EntryType = 'Information'
                    EventID   = '100'
                }
            )
            $eventLogData.Add(
                [PSCustomObject]@{
                    Message  = 'Failed to read the file'
                    FileName = 'C:\Temp\test.txt'
                    DateTime = Get-Date
                    EntryType = 'Error'
                    EventID   = '2'
                }
            )
            $eventLogData.Add(
                [PSCustomObject]@{
                    Message  = 'Created file'
                    FileName = 'C:\Report.xlsx'
                    FileSize = 123456
                    DateTime = Get-Date
                    EntryType = 'Information'
                    EventID   = '1'
                }
            )
            $eventLogData.Add(
                [PSCustomObject]@{
                    Message   = 'Script finished'
                    EntryType = 'Information'
                    EventID   = '199'
                }
            )

            $params = @{
                Source  = 'Test (Brecht)'
                LogName = 'HCScripts'
                Events  = $eventLogData
            }
            Write-EventsToEventLogHC @params
        #>

        [CmdLetBinding()]
        param (
            [Parameter(Mandatory)]
            [String]$Source,
            [Parameter(Mandatory)]
            [String]$LogName,
            [PSCustomObject[]]$Events
        )

        try {
            if (
                -not(
                    ([System.Diagnostics.EventLog]::Exists($LogName)) -and
                    [System.Diagnostics.EventLog]::SourceExists($Source)
                )
            ) {
                Write-Verbose "Create event log '$LogName' and source '$Source'"
                New-EventLog -LogName $LogName -Source $Source -ErrorAction Stop
            }

            foreach ($eventItem in $Events) {
                $params = @{
                    LogName     = $LogName
                    Source      = $Source
                    EntryType   = $eventItem.EntryType
                    EventID     = $eventItem.EventID
                    Message     = ''
                    ErrorAction = 'Stop'
                }

                if (-not $params.EntryType) {
                    $params.EntryType = 'Information'
                }
                if (-not $params.EventID) {
                    $params.EventID = 4
                }

                foreach (
                    $property in
                    $eventItem.PSObject.Properties | Where-Object {
                        ($_.Name -ne 'EntryType') -and ($_.Name -ne 'EventID')
                    }
                ) {
                    $params.Message += "`n- $($property.Name) '$($property.Value)'"
                }

                Write-Verbose "Write event to log '$LogName' source '$Source' message '$($params.Message)'"

                Write-EventLog @params
            }
        }
        catch {
            throw "Failed to write to event log '$LogName' source '$Source': $_"
        }
    }

    try {
        $settings = $jsonFileContent.Settings

        $scriptName = $settings.ScriptName
        $saveInEventLog = $settings.SaveInEventLog
        $sendMail = $settings.SendMail
        $saveLogFiles = $settings.SaveLogFiles

        $allLogFilePaths = @()
        $baseLogName = $null
        $logFolderPath = $null

        #region Get script name
        if (-not $scriptName) {
            Write-Warning "No 'Settings.ScriptName' found in import file."
            $scriptName = 'Default script name'
        }
        #endregion

        #region Counter
        $counter = @{
            Total = @{
                MovedFiles = 0
                Errors     = $systemErrors.Count
            }
        }
        #endregion

        #region Create log file data
        $logFileData = foreach ($task in $Tasks) {
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
                    Name       = 'Error'
                    Expression = { ConvertTo-SentenceHC $_.Errors }
                }
            }
        }

        $logFileDataErrors = $logFileData | Where-Object { $_.Error }
        #endregion
    
        #region Create log files
        try {
            $logFolder = Get-StringValueHC $saveLogFiles.Where.Folder

            $logFileExtensions = $saveLogFiles.Where.FileExtensions
            $isLog = @{
                systemErrors     = $saveLogFiles.What.SystemErrors
                allActions       = $saveLogFiles.What.AllActions
                onlyActionErrors = $saveLogFiles.What.OnlyActionErrors
            }

            if ($logFolder -and $logFileExtensions) {
                #region Get log folder
                try {
                    $logFolderPath = Get-LogFolderHC -Path $logFolder

                    Write-Verbose "Log folder '$logFolderPath'"

                    $baseLogName = Join-Path -Path $logFolderPath -ChildPath (
                        '{0} - {1} ({2})' -f
                        $scriptStartTime.ToString('yyyy_MM_dd'),
                        $ScriptName,
                        $jsonFileItem.BaseName
                    )
                }
                catch {
                    throw "Failed creating log folder '$LogFolder': $_"
                }
                #endregion

                #region Create log file
                if ($logFileData) {
                    $params = @{
                        FileExtensions = $logFileExtensions
                        Append         = $true
                        ExcelFile      = @{
                            SheetName = 'Overview'
                            TableName = 'Overview'
                            CellStyle = {
                                Param (
                                    $WorkSheet,
                                    $TotalRows,
                                    $LastColumn
                                )
                
                                @($WorkSheet.Names['FileSize'].Style).ForEach(
                                    { $_.NumberFormat.Format = '0.00\ \K\B' }
                                )
                            }
                        }
                    }

                    if ($isLog.allActions) {
                        $params.DataToExport = $logFileData
                        $params.PartialPath = "$baseLogName - Actions"
                        $allLogFilePaths += Out-LogFileHC @params
                    }
                    elseif ($isLog.onlyActionErrors -and $logFileDataErrors) {
                        $params.DataToExport = $logFileDataErrors
                        $params.PartialPath = "$baseLogName - Action errors"
                        $allLogFilePaths += Out-LogFileHC @params
                    }
                }

                if ($isLog.SystemErrors -and $systemErrors) {
                    $params = @{
                        DataToExport   = $systemErrors
                        PartialPath    = "$baseLogName - Errors"
                        FileExtensions = $logFileExtensions
                        Append         = $true
                    }
                    $allLogFilePaths += Out-LogFileHC @params
                }
                #endregion
            }
        }
        catch {
            $systemErrors.Add(
                [PSCustomObject]@{
                    DateTime = Get-Date
                    Message  = "Failed creating log file in folder '$($saveLogFiles.Where.Folder)': $_"
                }
            )

            Write-Warning $systemErrors[-1].Message
        }
        #endregion

        #region Remove old log files
        if ($saveLogFiles.DeleteLogsAfterDays -gt 0 -and $logFolderPath) {
            $cutoffDate = (Get-Date).AddDays(-$saveLogFiles.DeleteLogsAfterDays)

            Write-Verbose "Removing log files older than $cutoffDate from '$logFolderPath'"

            Get-ChildItem -Path $logFolderPath -File |
            Where-Object { $_.LastWriteTime -lt $cutoffDate } |
            ForEach-Object {
                try {
                    $fileToRemove = $_
                    Write-Verbose "Deleting old log file '$_''"
                    Remove-Item -Path $_.FullName -Force
                }
                catch {
                    $systemErrors.Add(
                        [PSCustomObject]@{
                            DateTime = Get-Date
                            Message  = "Failed to remove file '$fileToRemove': $_"
                        }
                    )

                    Write-Warning $systemErrors[-1].Message

                    if ($baseLogName -and $isLog.systemErrors) {
                        $params = @{
                            DataToExport   = $systemErrors[-1]
                            PartialPath    = "$baseLogName - Errors"
                            FileExtensions = $logFileExtensions
                        }
                        $allLogFilePaths += Out-LogFileHC @params -EA Ignore
                    }
                }
            }
        }
        #endregion

        #region Write events to event log
        try {
            $saveInEventLog.LogName = Get-StringValueHC $saveInEventLog.LogName

            if ($saveInEventLog.Save -and $saveInEventLog.LogName) {
                $systemErrors | ForEach-Object {
                    $eventLogData.Add(
                        [PSCustomObject]@{
                            Message   = $_.Message
                            DateTime  = $_.DateTime
                            EntryType = 'Error'
                            EventID   = '2'
                        }
                    )
                }

                $eventLogData.Add(
                    [PSCustomObject]@{
                        Message   = 'Script ended'
                        DateTime  = Get-Date
                        EntryType = 'Information'
                        EventID   = '199'
                    }
                )

                $params = @{
                    Source  = $scriptName
                    LogName = $saveInEventLog.LogName
                    Events  = $eventLogData
                }
                Write-EventsToEventLogHC @params

            }
            elseif ($saveInEventLog.Save -and (-not $saveInEventLog.LogName)) {
                throw "Both 'Settings.SaveInEventLog.Save' and 'Settings.SaveInEventLog.LogName' are required to save events in the event log."
            }
        }
        catch {
            $systemErrors.Add(
                [PSCustomObject]@{
                    DateTime = Get-Date
                    Message  = "Failed writing events to event log: $_"
                }
            )

            Write-Warning $systemErrors[-1].Message

            if ($baseLogName -and $isLog.systemErrors) {
                $params = @{
                    DataToExport   = $systemErrors[-1]
                    PartialPath    = "$baseLogName - Errors"
                    FileExtensions = $logFileExtensions
                }
                $allLogFilePaths += Out-LogFileHC @params -EA Ignore
            }
        }
        #endregion

        #region Get previous log file data
        if ($ReportOnly) {
            $params = @{
                PartialPath    = "$baseLogName - Actions"
                FileExtensions = $logFileExtensions
            }
            
            if ($isLog.onlyActionErrors) {
                $params.PartialPath = "$baseLogName - Action errors"
            }

            $previousLogFileData = Get-LogFileDataHC @params

            if ($previousLogFileData) {
                Write-Verbose 'Add results from previous runs'

                foreach ($task in $Tasks) {
                    Write-Verbose "Task '$($task.TaskName)'"

                    foreach ($action in $task.Actions) {
                        Write-Verbose "Action ComputerName '$($action.ComputerName)'"

                        foreach ($path in $action.Paths) {
                            Write-Verbose "Path source '$($path.Source)' destination '$($path.Destination)'"

                            $filteredPreviousLogFileData = 
                            $previousLogFileData | Where-Object {
                                ($path.Source -eq $_.SourcePath) -and
                                ($path.Destination -eq $_.DestinationPath) -and (
                                    ($_.SourcePath.startsWith('sftp') -and $action.ComputerName -eq $_.DestinationComputer) -or
                                    ($_.DestinationPath.startsWith('sftp') -and $action.ComputerName -eq $_.SourceComputer)
                                )
                            }

                            if (-not $filteredPreviousLogFileData) {
                                continue
                            }

                            $action.Job.Results += 
                            $filteredPreviousLogFileData | 
                            Select-Object -Property *, @{
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
        }
        #endregion

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
                        { $_.Errors }
                    ).foreach(
                        {
                            $M = "Error for TaskName '$($task.TaskName)' Sftp.ComputerName '$($task.Sftp.ComputerName)' ComputerName '$($action.ComputerName)' Source '$($_.Source)' Destination '$($_.Destination)' FileName '$($_.FileName)': $($_.Errors -join ',')"
                            
                            Write-Warning $M
                            
                            $eventLogData.Add(
                                [PSCustomObject]@{
                                    Message   = $M
                                    DateTime  = Get-Date
                                    EntryType = 'Error'
                                    EventID   = '2'
                                }
                            )
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
                    
                    $eventLogData.Add(
                        [PSCustomObject]@{
                            Message   = $M
                            DateTime  = Get-Date
                            EntryType = 'Error'
                            EventID   = '2'
                        }
                    )
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

        #region Send email
        try {
            $isSendMail = $false

            if ($ReportOnly) {
                $isSendMail = $true
            }
            else {                
                switch ($sendMail.When) {
                    'Never' {
                        break
                    }
                    'Always' {
                        $isSendMail = $true
                        break
                    }
                    'OnError' {
                        if ($counter.Total.Errors) {
                            $isSendMail = $true
                        }
                        break
                    }
                    'OnErrorOrAction' {
                        if ($counter.Total.Errors -or $logFileData) {
                            $isSendMail = $true
                        }
                        break
                    }
                    default {
                        throw "SendMail.When '$($sendMail.When)' not supported. Supported values are 'Never', 'Always', 'OnError' or 'OnErrorOrAction'."
                    }
                }
            }

            if ($isSendMail) {
                #region Test mandatory fields
                @{
                    'From'                 = $sendMail.From
                    'Smtp.ServerName'      = $sendMail.Smtp.ServerName
                    'Smtp.Port'            = $sendMail.Smtp.Port
                    'AssemblyPath.MailKit' = $sendMail.AssemblyPath.MailKit
                    'AssemblyPath.MimeKit' = $sendMail.AssemblyPath.MimeKit
                }.GetEnumerator() |
                Where-Object { -not $_.Value } | ForEach-Object {
                    throw "Input file property 'Settings.SendMail.$($_.Key)' cannot be blank"
                }
                #endregion

                $mailParams = @{
                    From                = Get-StringValueHC $sendMail.From
                    Subject             = "$($counter.Total.MovedFiles) moved"
                    SmtpServerName      = Get-StringValueHC $sendMail.Smtp.ServerName
                    SmtpPort            = Get-StringValueHC $sendMail.Smtp.Port
                    MailKitAssemblyPath = Get-StringValueHC $sendMail.AssemblyPath.MailKit
                    MimeKitAssemblyPath = Get-StringValueHC $sendMail.AssemblyPath.MimeKit
                }

                $mailParams.Body = @"
<!DOCTYPE html>
<html>
<head>
<style type="text/css">
    body {
        font-family:verdana;
        font-size:14px;
        background-color:white;
    }
    h1 {
        margin-bottom: 0;
    }
    h2 {
        margin-bottom: 0;
    }
    h3 {
        margin-bottom: 0;
    }
    p.italic {
        font-style: italic;
        font-size: 12px;
    }
    table {
        border-collapse:collapse;
        border:0px none;
        padding:3px;
        text-align:left;
    }
    td, th {
        border-collapse:collapse;
        border:1px none;
        padding:3px;
        text-align:left;
    }
    #aboutTable th {
        color: rgb(143, 140, 140);
        font-weight: normal;
    }
    #aboutTable td {
        color: rgb(143, 140, 140);
        font-weight: normal;
    }
    base {
        target="_blank"
    }
</style>
</head>
<body>
<table>
    <h1>$scriptName</h1>
    <hr size="2" color="#06cc7a">

    $($sendMail.Body)

    $(
        if ($systemErrors.Count) {
            '<table>
                <tr style="background-color: #ffe5ec;">
                    <th>System errors</th>
                    <td>{0}</td>
                </tr>
            </table>' -f $($systemErrors.Count)
        }
    )

    $(
        if ($ReportOnly) {
            '<p>Summary of all SFTP actions <b>executed today</b>:</p>'
        }
        else {
            '<p>Summary of SFTP actions:</p>'
        }
    )

    $htmlTable

    $(
        if ($allLogFilePaths) {
            '<p><i>* Check the attachment(s) for details</i></p>'
        }
    )

    <hr size="2" color="#06cc7a">
    <table id="aboutTable">
        $(
            if ($scriptStartTime) {
                '<tr>
                    <th>Start time</th>
                    <td>{0:00}/{1:00}/{2:00} {3:00}:{4:00} ({5})</td>
                </tr>' -f
                $scriptStartTime.Day,
                $scriptStartTime.Month,
                $scriptStartTime.Year,
                $scriptStartTime.Hour,
                $scriptStartTime.Minute,
                $scriptStartTime.DayOfWeek
            }
        )
        $(
            if ($scriptStartTime) {
                $runTime = New-TimeSpan -Start $scriptStartTime -End (Get-Date)
                '<tr>
                    <th>Duration</th>
                    <td>{0:00}:{1:00}:{2:00}</td>
                </tr>' -f
                $runTime.Hours, $runTime.Minutes, $runTime.Seconds
            }
        )
        $(
            if ($logFolderPath) {
                '<tr>
                    <th>Log files</th>
                    <td><a href="{0}">Open log folder</a></td>
                </tr>' -f $logFolderPath
            }
        )
        <tr>
            <th>Host</th>
            <td>$($host.Name)</td>
        </tr>
        <tr>
            <th>PowerShell</th>
            <td>$($PSVersionTable.PSVersion.ToString())</td>
        </tr>
        <tr>
            <th>Computer</th>
            <td>$env:COMPUTERNAME</td>
        </tr>
        <tr>
            <th>Account</th>
            <td>$env:USERDNSDOMAIN\$env:USERNAME</td>
        </tr>
    </table>
</table>
</body>
</html>
"@

                if ($sendMail.FromDisplayName) {
                    $mailParams.FromDisplayName = Get-StringValueHC $sendMail.FromDisplayName
                }

                if ($sendMail.Subject) {
                    $mailParams.Subject = '{0}, {1}' -f
                    $mailParams.Subject, $sendMail.Subject
                }

                if ($sendMail.To) {
                    $mailParams.To = $sendMail.To
                }

                if ($sendMail.Bcc) {
                    $mailParams.Bcc = $sendMail.Bcc
                }

                if ($counter.Total.Errors) {
                    $mailParams.Priority = 'High'
                    $mailParams.Subject = '{0} error{1}, {2}' -f
                    $counter.Total.Errors,
                    $(if ($counter.Total.Errors -ne 1) { 's' }),
                    $mailParams.Subject
                }

                if ($allLogFilePaths) {
                    $mailParams.Attachments = $allLogFilePaths |
                    Sort-Object -Unique
                }

                if ($sendMail.Smtp.ConnectionType) {
                    $mailParams.SmtpConnectionType = Get-StringValueHC $sendMail.Smtp.ConnectionType
                }

                #region Create SMTP credential
                $smtpUserName = Get-StringValueHC $sendMail.Smtp.UserName
                $smtpPassword = Get-StringValueHC $sendMail.Smtp.Password

                if ( $smtpUserName -and $smtpPassword) {
                    try {
                        $securePassword = ConvertTo-SecureString -String $smtpPassword -AsPlainText -Force

                        $credential = New-Object System.Management.Automation.PSCredential($smtpUserName, $securePassword)

                        $mailParams.Credential = $credential
                    }
                    catch {
                        throw "Failed to create credential: $_"
                    }
                }
                elseif ($smtpUserName -or $smtpPassword) {
                    throw "Both 'Settings.SendMail.Smtp.Username' and 'Settings.SendMail.Smtp.Password' are required when authentication is needed."
                }
                #endregion

                Send-MailKitMessageHC @mailParams
            }
        }
        catch {
            $systemErrors.Add(
                [PSCustomObject]@{
                    DateTime = Get-Date
                    Message  = "Failed sending email: $_"
                }
            )

            Write-Warning $systemErrors[-1].Message

            if ($baseLogName -and $isLog.systemErrors) {
                $params = @{
                    DataToExport   = $systemErrors[-1]
                    PartialPath    = "$baseLogName - Errors"
                    FileExtensions = $logFileExtensions
                }
                $null = Out-LogFileHC @params -EA Ignore
            }
        }
        #endregion
    }
    catch {
        $systemErrors.Add(
            [PSCustomObject]@{
                DateTime = Get-Date
                Message  = $_
            }
        )

        Write-Warning $systemErrors[-1].Message
    }
    finally {
        if ($systemErrors) {
            $M = 'Found {0} system error{1}' -f
            $systemErrors.Count,
            $(if ($systemErrors.Count -ne 1) { 's' })
            Write-Warning $M

            $systemErrors | ForEach-Object {
                Write-Warning $_.Message
            }

            Write-Warning 'Exit script with error code 1'
            exit 1
        }
        else {
            Write-Verbose 'Script finished successfully'
        }
    }
}