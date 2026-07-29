#Requires -Version 7
# the module Posh-SSH is imported by Import-ModuleWithLockHC and not
# with '#Requires -Modules Posh-SSH', because that import cannot be
# synchronized between runspaces

<#
.SYNOPSIS
    Move files to or from an SFTP server.

.DESCRIPTION
    Move files to or from an SFTP server.

    The move CmdLets (Move-Item and Move-SFTPItem) are used because they fail
    when a file is in use. The download CmdLet 'Get-SFTPItem' does not fail when
    a file is in use.

    # Download

    ## Steps
    1. Move the file to the SFTP temp folder
    2. Download file from SFTP temp folder to local temp folder
    3. Move local temp file to destination folder

    ## Special cases

    ### Interrupted download

    When a file starts downloading and the connection is cut, we have 2 files,
    one in the SFTP temp folder and one in the local temp folder.

    The file in the SFTP temp folder remains untouched and the incomplete
    downloaded local temp file is removed. On the next run of the script, the
    SFTP temp file will be downloaded again.

    Any new file in the SFTP source folder with the same name will be ignored and only processed during the next run.

    ### Cannot overwrite destination file

    When a file is downloaded to the local temp folder, it can happen
    that the destination file is in use by another process and the file cannot
    be overwritten.

    The script will leave the file in the local temp folder an tries to move
    it to the destination folder on the next run.

    Any new file in the SFTP source folder with the same name will be ignored and only processed during the next run.

.PARAMETER Paths
    Lost of source and destination folders.

.PARAMETER MaxConcurrentPaths
    How many paths are handled at the same time. Each path opens its own SFTP
    session, so this is also the maximum number of SFTP sessions opened by
    this script.

.PARAMETER SftpComputerName
    The URL where the SFTP server can be reached.

.PARAMETER SftpPath
    Path to th folder on the SFTP server.

.PARAMETER SftpCredential
    The SFTP credential object used to authenticate to the SFTP server.

.PARAMETER SftpOpenSshKeyFile
    The password used to authenticate to the SFTP server. This is an
    SSH private key file in the OpenSSH format converted to an array of strings.

.PARAMETER MatchFileNameRegex
    Regex to select specific file names to download.

.PARAMETER OverwriteFile
    When a file that is being downloaded is already present with the same name
    it will be overwritten when OverwriteFile is TRUE.

.PARAMETER AttemptCount
    How many times will we attempt to execute CmdLets that might fail on first
    attempt. A file that is locked cannot be moved, with this counter, multiple
    attempts can be made.

.PARAMETER WaitSecondsBetweenAttempts
    When a CmdLet fails, the script will wait x amount of seconds before trying
    to execute the CmdLet again.
#>

param (
    [Parameter(Mandatory)]
    [String]$SftpComputerName,
    [Parameter(Mandatory)]
    [PSCredential]$SftpCredential,
    [Parameter(Mandatory)]
    [PSCustomObject[]]$Paths,
    [Parameter(Mandatory)]
    [Int]$MaxConcurrentPaths,
    [Parameter(Mandatory)]
    [Int]$SftpPort,
    [Parameter(Mandatory)]
    [String]$MatchFileNameRegex,
    [String[]]$SftpOpenSshKeyFile,
    [Boolean]$OverwriteFile,
    [Boolean]$ExcludeZeroSizeFile,
    [Int]$AttemptCount = 5,
    [Int]$WaitSecondsBetweenAttempts = 3
)

try {
    # $VerbosePreference = 'Continue'

    function Invoke-WithOptionalParallelismHC {
        <#
        .SYNOPSIS
            Executes a scriptblock against an array of input objects, seamlessly
            switching between sequential and parallel execution.

        .DESCRIPTION
            A dynamic execution wrapper that allows the pipeline to scale
            concurrency based on the provided configuration.

            If the `ThrottleLimit` is greater than 1, the function utilizes
            PowerShell 7's `ForEach-Object -Parallel` to spin up concurrent
            runspaces. If the limit is 1 or less, it gracefully falls back to a
            standard sequential `foreach` loop running on the main thread, making
            it highly versatile for debugging or resource-constrained environments.

        .PARAMETER InputObject
            An array of items to process. Inside the scriptblock, the current item
            is passed as the first positional parameter.

        .PARAMETER ScriptBlock
            The code to execute against each item. Must define a `param()` block to
            receive the input item and any additional arguments.

        .PARAMETER ThrottleLimit
            The maximum number of concurrent threads/runspaces. A value of 1 or 0
            forces standard sequential execution.

        .PARAMETER ArgumentList
            An optional array of extra arguments to pass positionally to the
            scriptblock after the main input item.

        .EXAMPLE
            $items = @('ServerA', 'ServerB')
            $myList = [System.Collections.Generic.List[string]]::new()

            Invoke-WithOptionalParallelismHC `
                -InputObject $items `
                -ThrottleLimit 5 `
                -ArgumentList (,$myList), $true `
                -ScriptBlock {
                    param($ComputerName, $ListRef, $LogEnabled)

                    if ($LogEnabled) {
                        $ListRef.Add("Processed $ComputerName")
                    }
                }

        .NOTES
            ArgumentList follows the standard PowerShell convention (cf. Start-Job,
            Invoke-Command): supplied values are passed as positional arguments
            after the input item.

            CRITICAL: When passing an enumerable object (e.g., a ConcurrentBag,
            Generic List, hashtable), wrap it with the unary comma to prevent the
            binder from unrolling/enumerating it:
                -ArgumentList (,$bag) # CORRECT: passes the bag as a single argument
                -ArgumentList @($bag) # WRONG: bag gets enumerated and split

            SCOPE LIMITATION: The scriptblock is dynamically rehydrated via
            [scriptblock]::Create() inside each parallel runspace. Because of this,
            the `$using:` scope modifier from the caller's scope does NOT work
            natively inside the scriptblock. You must pass all external variables
            explicitly via the -ArgumentList parameter or store them in the input
            object.
        #>

        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [AllowEmptyCollection()]
            [array]$InputObject,

            [Parameter(Mandatory)]
            [scriptblock]$ScriptBlock,

            [Parameter(Mandatory)]
            [int]$ThrottleLimit,

            [Parameter()]
            [object[]]$ArgumentList = @()
        )

        if ($ThrottleLimit -le 1) {
            Write-Verbose 'Running sequentially (ThrottleLimit <= 1)'

            foreach ($item in $InputObject) {
                & $ScriptBlock $item @ArgumentList
            }
        }
        else {
            Write-Verbose "Running in parallel (ThrottleLimit = $ThrottleLimit)"

            $scriptBlockString = $ScriptBlock.ToString()

            $InputObject | ForEach-Object -Parallel {
                $rehydratedBlock = [scriptblock]::Create($using:scriptBlockString)
                $splatArgs = $using:ArgumentList
                & $rehydratedBlock $_ @splatArgs
            } -ThrottleLimit $ThrottleLimit
        }
    }

    $scriptBlock = {
        param($job)

        function Get-FolderContentSftpServerHC {
            try {
                Write-Verbose "Get folder content 'SFTP:$sftpPath'"

                $allFilesAndFolders = @(
                    Get-SFTPChildItemHC -Path $sftpPath
                )

                $tempFiles = $allFilesAndFolders.Where(
                    {
                        (-not $_.isDirectory ) -and
                        ($_.FullName -eq "$($tempFolder.sftp)/$($_.Name)")
                    }
                )

                $rootFiles = $allFilesAndFolders.Where(
                    {
                        (-not $_.isDirectory ) -and
                        ($_.FullName -eq "$sftpPath$($_.Name)")
                    }
                )

                @{
                    allFilesAndFolders = $allFilesAndFolders
                    tempFiles          = $tempFiles
                    rootFiles          = $rootFiles
                }
            }
            catch {
                $M = "Failed retrieving the content of SFTP folder '$sftpPath'. Most likely the path does not exist on the SFTP server: $_"
                $Error.RemoveAt(0)
                throw $M
            }
        }
        function Get-FolderContentLocalFileSystemHC {
            param (
                [parameter(Mandatory)]
                [string]$Path
            )
            try {
                $allFilesAndFolders = @(
                    Get-ChildItem -LiteralPath $Path -Recurse
                )

                $rootFiles =
                $allFilesAndFolders.Where(
                    {
                        (-not $_.PSIsContainer) -and
                        ($_.Directory.FullName -eq $Path)
                    }
                )

                $tempFiles =
                $allFilesAndFolders.Where(
                    {
                        (-not $_.PSIsContainer) -and
                        ($_.Directory.FullName -eq $tempFolder.local)
                    }
                )

                @{
                    allFilesAndFolders = $allFilesAndFolders
                    tempFiles          = $tempFiles
                    rootFiles          = $rootFiles
                }
            }
            catch {
                throw "Path '$Path' not found on the file system"
            }
        }
        function Get-SFTPItemHC {
            <#
                .SYNOPSIS
                    Download a file

                .DESCRIPTION
                    Get-SFTPItem does not throw an error, only a warning

                .LINK
                    https://github.com/darkoperator/Posh-SSH/issues/606
            #>

            [CmdletBinding()]
            param (
                [parameter(Mandatory)]
                [String]$Path,
                [parameter(Mandatory)]
                [String]$Destination
            )

            $WarningPreference = 'Continue'
            $warningMessages = @()

            $params = @{
                Path            = $Path
                Destination     = $Destination
                ErrorVariable   = 'errorMessages'
                WarningVariable = 'warningMessages'
                Force           = $true
            }
            Get-SFTPItem @sessionParams @params

            foreach ($warningMessage in $warningMessages) {
                throw $warningMessage
            }

            foreach ($errorMessage in $errorMessages) {
                throw $errorMessage
            }
        }
        function Get-SFTPChildItemHC {
            <#
                .SYNOPSIS
                    List folder content on SFTP server

                .DESCRIPTION
                    Get-SFTPChildItem does not throw an error, only a non
                    terminating error

                .LINK
                    https://github.com/darkoperator/Posh-SSH/issues/607
            #>

            [CmdletBinding()]
            param (
                [parameter(Mandatory)]
                [String]$Path
            )

            $WarningPreference = 'Continue'

            $warningMessages = @()
            $errorMessages = @()

            $params = @{
                Path            = $Path
                Recurse         = $true
                ErrorVariable   = 'errorMessages'
                WarningVariable = 'warningMessages'
            }
            Get-SFTPChildItem @sessionParams @params

            foreach ($warningMessage in $warningMessages) {
                throw $warningMessage
            }

            foreach ($errorMessage in $errorMessages) {
                throw $errorMessage
            }
        }
        function Move-SFTPItemHC {
            param (
                [parameter(Mandatory)]
                [string]$Source,
                [parameter(Mandatory)]
                [string]$Destination,
                [boolean]$isDuplicateFile = $false
            )

            try {
                $moveParams = @{
                    Path        = $Source
                    Destination = $Destination
                }

                Write-Verbose "Move file 'SFTP:$Source' to 'SFTP:$Destination'"

                Start-RetryActionHC -ScriptBlock {
                    if ($isDuplicateFile) {
                        Remove-SFTPItem @sessionParams -Path $Destination

                        Save-ActionMessageHC "removed duplicate file 'SFTP:$Destination'"
                    }

                    Move-SFTPItem @sessionParams @moveParams
                }
            }
            catch {
                $customErrorMessage = "$_"

                if ($customErrorMessage -eq 'Exception calling "Delete" with "1" argument(s): "Permission denied"') {
                    $customErrorMessage = "file 'SFTP:$Destination' in use by another process: $_"
                }

                if ($customErrorMessage -eq 'Exception calling "MoveTo" with "1" argument(s): "Permission denied"') {
                    $customErrorMessage = "file 'SFTP:$Source' in use by another process: $_"
                }

                $Error.RemoveAt(0)

                throw $customErrorMessage
            }
        }
        function New-SFTPTempFolderHC {
            try {
                $isSftpTempFolderCreated = $sftpServerContent.allFilesAndFolders.where(
                    {
                        $_.IsDirectory -and
                        $_.FullName -eq $tempFolder.sftp
                    }
                )

                if (-not $isSftpTempFolderCreated) {
                    Write-Verbose "Create folder 'SFTP:$($tempFolder.sftp)'"

                    $null = New-SFTPItem @sessionParams -Path $tempFolder.sftp -ItemType Directory -Recurse
                }
            }
            catch {
                $M = "Failed creating folder 'SFTP:$($tempFolder.sftp)' $_"
                $Error.RemoveAt(0)
                throw $M
            }
        }
        function New-LocalTempFolderHC {
            $isLocalTempFolderCreated = $localFolderContent.allFilesAndFolders.Where(
                {
                    ($_.PSIsContainer) -and
                    ($_.FullName -eq $tempFolder.local)
                }
            )

            if (-not ($isLocalTempFolderCreated)) {
                try {
                    Write-Verbose "Create folder '$($tempFolder.local)'"

                    $null = New-Item -Path $tempFolder.local -ItemType Directory
                }
                catch {
                    throw "Failed creating local temporary folder '$($tempFolder.local)': $_"
                }
            }
        }
        function Open-SFTPSessionHC {
            try {
                Write-Verbose 'Open SFTP session'

                $params = @{
                    ComputerName      = $SftpComputerName
                    Credential        = $sftpCredential
                    Port              = $SftpPort
                    ConnectionTimeout = 60
                    AcceptKey         = $true
                    Force             = $true
                    Verbose           = $false
                }

                if ($SftpOpenSshKeyFile) {
                    $params.KeyString = $SftpOpenSshKeyFile
                }

                $sftpSession = New-SFTPSession @params

                Write-Verbose "SFTP session ID '$($sftpSession.SessionId)'"

                @{
                    SessionId = $sftpSession.SessionID
                    Verbose   = $false
                }
            }
            catch {
                $M = "Failed creating an SFTP session from '$ENV:COMPUTERNAME' to '$SftpComputerName' over port '$SftpPort': $_"
                $Error.RemoveAt(0)
                throw $M
            }
        }
        function Remove-LocalFileHC {
            param (
                [parameter(Mandatory)]
                [string]$Path
            )

            Start-RetryActionHC -ScriptBlock {
                $testPathParams = @{
                    LiteralPath = $Path
                    PathType    = 'Leaf'
                }
                if (Test-Path @testPathParams) {
                    try {
                        Write-Verbose "Remove file '$Path'"

                        $Path | Remove-Item -Force
                    }
                    catch {
                        Save-ErrorMessageHC "Failed to remove file '$Path': $_"

                        $Error.RemoveAt(0)
                    }
                }
            }
        }
        function Start-RetryActionHC {
            <#
                .SYNOPSIS
                    Run a CmdLet multiple times.

                .DESCRIPTION
                    This is useful for cases where a file is locked.
            #>
            [CmdletBinding()]
            param (
                [Parameter(Mandatory)]
                [scriptblock]$ScriptBlock,
                [ValidateRange(1, 25)]
                [int]$AttemptCount = $AttemptCount,
                [ValidateRange(1, 30)]
                [int]$WaitSecondsBetweenAttempts = $WaitSecondsBetweenAttempts
            )

            $attempt = @{
                count   = 0
                success = $false
            }

            while (
                (-not $attempt.success) -and
                ($attempt.count -lt $AttemptCount)
            ) {
                try {
                    $attempt.count++
                    Write-Verbose "Attempt $($attempt.count)/$AttemptCount"

                    & $ScriptBlock -ErrorAction 'Stop'

                    $attempt.success = $true
                }
                catch {
                    if ($attempt.count -lt $AttemptCount) {
                        Write-Warning "Attempt $($attempt.count)/$AttemptCount failed, wait $WaitSecondsBetweenAttempts seconds"
                        Start-Sleep -Seconds $WaitSecondsBetweenAttempts
                    }
                    else {
                        Write-Warning "Attempt $($attempt.count)/$AttemptCount failed: $_"
                    }
                    $errorMessage = $_
                    $Error.RemoveAt(0)
                }
            }

            if (-not $attempt.success) {
                throw $errorMessage
            }
        }
        function Save-ErrorMessageHC {
            <#
                .SYNOPSIS
                    Add an error message to the result object and log
                    a warning message.
            #>
            param (
                [parameter(Mandatory)]
                [string]$ErrorMessage
            )

            Write-Warning "Add error: $ErrorMessage"

            $result.Errors += $ErrorMessage
        }
        function Save-ActionMessageHC {
            <#
                .SYNOPSIS
                    Add an action message to the result object and log
                    a verbose message.
            #>
            param (
                [parameter(Mandatory)]
                [string]$ActionMessage
            )

            Write-Verbose "Add action: $ActionMessage"

            $result.Actions += $ActionMessage
        }

        function Import-ModuleWithLockHC {
            <#
                .SYNOPSIS
                    Import a PowerShell module while holding a lock.

                .DESCRIPTION
                    Importing the same module at the same time in multiple
                    runspaces is not thread safe. It fails intermittently with
                    errors like "An item with the same key has already been
                    added. Key: Alias", because a module registers its
                    aliases, formats and nested modules in tables that are
                    shared within the process.

                    A named mutex guarantees that only one runspace at a time
                    is importing the module. When the module is already loaded
                    in the runspace nothing is done.

                .PARAMETER Name
                    Name of the module to import.

                .PARAMETER TimeoutSeconds
                    Maximum time to wait for another runspace to finish
                    importing the module.
            #>
            param (
                [Parameter(Mandatory)]
                [String]$Name,
                [Int]$TimeoutSeconds = 120
            )

            if (Get-Module -Name $Name) {
                Write-Verbose "Module '$Name' is already loaded"
                return
            }

            $mutex = [System.Threading.Mutex]::new(
                $false, "Local\ImportModule-$Name"
            )

            $isMutexOwner = $false

            try {
                try {
                    $isMutexOwner = $mutex.WaitOne(
                        [TimeSpan]::FromSeconds($TimeoutSeconds)
                    )
                }
                catch [System.Threading.AbandonedMutexException] {
                    # a runspace was terminated before releasing the mutex,
                    # we are the owner now
                    $isMutexOwner = $true
                }

                if (-not $isMutexOwner) {
                    throw "waited more than $TimeoutSeconds seconds for another runspace to finish the import"
                }

                Import-Module -Name $Name -ErrorAction 'Stop'

                Write-Verbose "Imported module '$Name'"
            }
            catch {
                $M = "Failed importing module '$Name': $_"
                $Error.RemoveAt(0)
                throw $M
            }
            finally {
                if ($isMutexOwner) {
                    $mutex.ReleaseMutex()
                }

                $mutex.Dispose()
            }
        }

        try {
            #region Read the job object
            # A job object contains all data required to handle one path.
            # This avoids the use of '$using:', which does not work in a
            # scriptblock that is rehydrated by
            # Invoke-WithOptionalParallelismHC.
            $path = $job.Path

            $SftpComputerName = $job.SftpComputerName
            $SftpCredential = $job.SftpCredential
            $SftpPort = $job.SftpPort
            $SftpOpenSshKeyFile = $job.SftpOpenSshKeyFile

            $MatchFileNameRegex = $job.MatchFileNameRegex
            $OverwriteFile = $job.OverwriteFile
            $ExcludeZeroSizeFile = $job.ExcludeZeroSizeFile
            $AttemptCount = $job.AttemptCount
            $WaitSecondsBetweenAttempts = $job.WaitSecondsBetweenAttempts
            #endregion

            #region Set defaults
            # workaround for https://github.com/PowerShell/PowerShell/issues/16894
            $ProgressPreference = 'SilentlyContinue'
            $ErrorActionPreference = 'Stop'
            $VerbosePreference = $job.VerbosePreference
            #endregion

            Write-Verbose "Path source '$($path.Source)' destination '$($path.Destination)'"

            #region Import the SFTP module
            # a new runspace does not inherit the modules loaded by its parent
            Import-ModuleWithLockHC -Name 'Posh-SSH'
            #endregion

            $tempFolderName = @{
                download = 'sftpTransfer/download'
                upload   = 'sftpTransfer/upload'
            }

            if ($path.Source -like 'sftp*' ) {
                Write-Verbose 'Download from SFTP server'

                $processedFiles = @{}

                $tempFolder = @{}

                $joinPath = @{
                    Path      = $path.Destination
                    ChildPath = $tempFolderName.download
                }
                $tempFolder.local = Join-Path @joinPath

                #region Get local folder content
                $params = @{
                    Path = $path.Destination
                }
                $localFolderContent = Get-FolderContentLocalFileSystemHC @params
                #endregion

                New-LocalTempFolderHC

                #region Move previously downloaded files from local temp folder to local destination folder
                foreach (
                    $localTempFile in
                    $localFolderContent.tempFiles
                ) {
                    try {
                        Write-Verbose "Found previous completely downloaded file '$localTempFile'"

                        $processedFiles[$localTempFile.Name] = $localTempFile

                        $result = [PSCustomObject]@{
                            DateTime    = Get-Date
                            Source      = $path.Source
                            Destination = $path.Destination
                            FileName    = $localTempFile.Name
                            FileLength  = $localTempFile.Length
                            Actions     = @()
                            Moved       = $false
                            Errors      = @()
                        }

                        Save-ActionMessageHC 'this file is a complete downloaded file from the previous run'

                        if (
                            (-not $OverwriteFile) -and
                            ($localFolderContent.rootFiles.Name -contains $localTempFile.Name)
                        ) {
                            Save-ErrorMessageHC "Duplicate file name '$($result.FileName)' in the destination folder, use OverwriteFile if needed"

                            continue
                        }

                        $params = @{
                            LiteralPath = $localTempFile
                            Destination = Join-Path $result.Destination $result.FileName
                            Force       = $true
                        }

                        Write-Verbose "Move previously downloaded file '$($params.LiteralPath)' to '$($params.Destination)"

                        Start-RetryActionHC -ScriptBlock {
                            $testPathParams = @{
                                LiteralPath = $params.Destination
                                PathType    = 'Leaf'
                            }
                            if (Test-Path @testPathParams) {
                                # remove-item throws the error file in use
                                Remove-Item -LiteralPath $params.Destination

                                Save-ActionMessageHC 'removed duplicate file in destination folder'
                            }
                            # move-item has an error 'Cannot create file'
                            Move-Item @params
                        }

                        Save-ActionMessageHC 'moved file from local temp folder to local destination folder'

                        Write-Verbose 'file moved successfully'
                        $result.Moved = $true
                    }
                    catch {
                        Save-ErrorMessageHC "Failed to move the previously downloaded file '$localTempFile' to the destination folder: $_"

                        $Error.RemoveAt(0)
                    }
                    finally {
                        Write-Verbose 'Return result object'
                        $result
                    }
                }
                #endregion

                $sessionParams = Open-SFTPSessionHC

                $sftpPath = $path.Source.Substring(5)

                $tempFolder.sftp = "$($sftpPath)$($tempFolderName.download)"

                $sftpServerContent = Get-FolderContentSftpServerHC

                #region Select files to download
                try {
                    $filesToDownload = $sftpServerContent.tempFiles + $sftpServerContent.rootFiles

                    Write-Verbose "Select files matching regex '$MatchFileNameRegex'"

                    $filesToDownload = $filesToDownload.where(
                        { $_.Name -match $MatchFileNameRegex }
                    )

                    Write-Verbose "Found $($filesToDownload.Count) file(s) on the SFTP server to download"
                }
                catch {
                    $M = "Failed to select SFTP root files to download in folder '$sftpPath': $_"
                    $Error.RemoveAt(0)
                    throw $M
                }
                #endregion

                New-SFTPTempFolderHC

                #region Exit when no files to download
                if (-not $filesToDownload) {
                    Write-Verbose 'No files to download'
                    Write-Verbose 'Exit script'
                    return
                }
                #endregion

                foreach ($fileToDownload in $filesToDownload) {
                    try {
                        Write-Verbose "File to download '$($fileToDownload.FullName)'"

                        $returnResultObject = $true

                        #region Only process unique file names
                        if ($processedFiles[$fileToDownload.Name]) {
                            Write-Verbose "File name '$($fileToDownload.Name)' already processed"

                            $returnResultObject = $false

                            continue
                        }

                        $processedFiles[$fileToDownload.Name] = $fileToDownload
                        #endregion

                        $result = [PSCustomObject]@{
                            DateTime    = Get-Date
                            Source      = $path.Source
                            Destination = $path.Destination
                            FileName    = $fileToDownload.Name
                            FileLength  = $fileToDownload.Length
                            Actions     = @()
                            Moved       = $false
                            Errors      = @()
                        }

                        $tempFile = @{
                            sftp  = '{0}/{1}' -f
                            $tempFolder.sftp, $result.FileName
                            local = '{0}\{1}' -f
                            $tempFolder.local, $result.FileName
                        }

                        $isTempFile = $fileToDownload.FullName -eq $tempFile.sftp

                        #region Zero size file
                        if (-not $isTempFile) {
                            if (
                                $ExcludeZeroSizeFile -and 
                                ($fileToDownload.Length -eq 0)
                            ) {
                                Save-ActionMessageHC "file size 0 bytes, file not moved, option 'ExcludeZeroSizeFile' enabled"

                                continue
                            }
                        }
                        #endregion

                        #region Test duplicate file in destination folder
                        $isDuplicateFileInDestinationFolder = $localFolderContent.rootFiles.where(
                            {
                                $fileToDownload.Name -eq $_.Name
                            }
                        )

                        if (
                            $isDuplicateFileInDestinationFolder -and
                            (-not $OverwriteFile)
                        ) {
                            Save-ErrorMessageHC 'Duplicate file in destination folder, use OverwriteFile if needed'

                            continue
                        }
                        #endregion

                        #region Move file from SFTP source folder to SFTP temp folder
                        if (-not $isTempFile) {
                            $isDuplicateInSftpTempFolder = $sftpServerContent.tempFiles.where(
                                {
                                    $fileToDownload.Name -eq $_.Name
                                }
                            )

                            try {
                                $params = @{
                                    Source          = $fileToDownload.FullName
                                    Destination     = $tempFile.sftp
                                    isDuplicateFile = [boolean]$isDuplicateInSftpTempFolder
                                }

                                Move-SFTPItemHC @params

                                Save-ActionMessageHC 'moved file to SFTP temp folder'
                            }
                            catch {
                                Save-ErrorMessageHC "Failed to move file from SFTP source folder to SFTP temp folder: $_"

                                $Error.RemoveAt(0)

                                continue
                            }
                        }
                        #endregion

                        #region Download file from SFTP temp folder to local temp folder
                        try {
                            Write-Verbose "Download file 'SFTP:$($tempFile.sftp)' to '$($tempFile.local)'"

                            Start-RetryActionHC -ScriptBlock {
                                $params = @{
                                    Path        = $tempFile.sftp
                                    Destination = $tempFolder.local
                                }
                                Get-SFTPItemHC @params
                            }

                            if ($isTempFile) {
                                Save-ActionMessageHC 'this file is a previously moved file in the SFTP temp folder'
                            }

                            Save-ActionMessageHC 'downloaded file from SFTP temp folder to local temp folder'
                        }
                        catch {
                            Save-ErrorMessageHC "Failed to download file 'SFTP:$($tempFile.sftp)' to '$($tempFile.local)': $_"

                            $Error.RemoveAt(0)

                            Remove-LocalFileHC -Path $tempFile.local

                            Save-ActionMessageHC 'removed file in local temp folder'

                            continue
                        }
                        #endregion

                        #region Remove file in SFTP temp folder
                        try {
                            Write-Verbose "Remove file 'SFTP:$($tempFile.sftp)'"

                            Start-RetryActionHC -ScriptBlock {
                                $params = @{
                                    Path = $tempFile.sftp
                                }
                                Remove-SFTPItem @sessionParams @params
                            }

                            Save-ActionMessageHC 'removed file in SFTP temp folder'
                        }
                        catch {
                            Save-ErrorMessageHC "Failed to remove file 'SFTP:$($tempFile.sftp)', most likely the file is in use: $_"

                            $Error.RemoveAt(0)

                            Remove-LocalFileHC -Path $tempFile.local

                            Save-ActionMessageHC 'removed file in local temp folder'

                            continue
                        }
                        #endregion

                        #region Move file in local temp folder to destination folder
                        try {
                            $params = @{
                                LiteralPath = $tempFile.local
                                Destination = '{0}\{1}' -f $path.destination, $result.FileName
                                Force       = $true
                            }

                            Write-Verbose "Move file '$($params.LiteralPath)' to '$($params.Destination)"

                            Start-RetryActionHC -ScriptBlock {
                                $testPathParams = @{
                                    LiteralPath = $params.Destination
                                    PathType    = 'Leaf'
                                }
                                if (Test-Path @testPathParams) {
                                    # remove-item throws the error file in use
                                    Remove-Item -LiteralPath $params.Destination

                                    Save-ActionMessageHC 'removed duplicate file in destination folder'
                                }
                                # move-item has an error 'Cannot create file'
                                Move-Item @params

                                Save-ActionMessageHC 'moved file in local temp folder to destination folder'
                            }
                        }
                        catch {
                            Save-ErrorMessageHC "Failed to move temp file to destination folder: $_"

                            $Error.RemoveAt(0)

                            continue
                        }
                        #endregion

                        Write-Verbose 'file moved successfully'
                        $result.Moved = $true
                    }
                    catch {
                        Save-ErrorMessageHC $_
                        $Error.RemoveAt(0)
                    }
                    finally {
                        if ($returnResultObject) {
                            Write-Verbose 'Return result object'

                            $result
                        }
                        else {
                            Write-Verbose 'No result object to return'
                        }
                    }
                }
            }
            else {
                Write-Verbose 'Upload to SFTP server'

                $processedFiles = @{}

                $tempFolder = @{}

                $joinPath = @{
                    Path      = $path.Source
                    ChildPath = $tempFolderName.upload
                }
                $tempFolder.local = Join-Path @joinPath

                $sftpPath = $path.Destination.Substring(5)

                $tempFolder.sftp = "$($sftpPath)$($tempFolderName.upload)"

                #region Get local folder content
                $params = @{
                    Path = $path.Source
                }
                $localFolderContent = Get-FolderContentLocalFileSystemHC @params
                #endregion

                New-LocalTempFolderHC

                #region Select files to upload
                try {
                    $filesToUpload = $localFolderContent.tempFiles + $localFolderContent.rootFiles

                    Write-Verbose "Select files matching regex '$MatchFileNameRegex'"

                    $filesToUpload = $filesToUpload.where(
                        { $_.Name -match $MatchFileNameRegex }
                    )

                    Write-Verbose "Found $($filesToUpload.Count) file(s) to upload"
                }
                catch {
                    $M = "Failed to select files to to upload: $_"
                    $Error.RemoveAt(0)
                    throw $M
                }
                #endregion

                #region Exit when there are no files to upload
                if (-not $filesToUpload) {
                    Write-Verbose 'No files to upload'
                    Write-Verbose 'Exit script'
                    return
                }
                #endregion

                $sessionParams = Open-SFTPSessionHC

                $sftpServerContent = Get-FolderContentSftpServerHC

                New-SFTPTempFolderHC

                #region Remove failed files in SFTP temp folder
                $sftpFailedTempFiles = $sftpServerContent.allFilesAndFolders.Where(
                    {
                        (-not $_.isDirectory ) -and
                        ($_.FullName -eq "$($tempFolder.sftp)/$($_.Name)")
                    }
                )

                foreach ($failedFile in $sftpFailedTempFiles) {
                    try {
                        Write-Verbose "Remove failed temp file 'SFTP:$($failedFile.FullName)'"

                        $result = [PSCustomObject]@{
                            DateTime    = Get-Date
                            Source      = $path.Source
                            Destination = $path.Destination
                            FileName    = $failedFile.Name
                            FileLength  = $failedFile.Length
                            Actions     = @()
                            Moved       = $null
                            Errors      = @()
                        }

                        $params = @{
                            Path = $failedFile.FullName
                        }
                        Start-RetryActionHC -ScriptBlock {
                            Remove-SFTPItem @sessionParams @params
                        }

                        Save-ActionMessageHC 'this is a temp file that failed during the last run'

                        Save-ActionMessageHC "removed file 'SFTP:$($failedFile.FullName)'"
                    }
                    catch {
                        $processedFiles[$failedFile.Name] = $failedFile

                        Save-ErrorMessageHC 'this is a temp file that failed during the last run'

                        Save-ErrorMessageHC "Failed to remove file 'SFTP:$($failedFile.FullName)': $_"

                        $Error.RemoveAt(0)
                    }
                    finally {
                        $result
                    }
                }
                #endregion

                foreach ($fileToUpload in $filesToUpload) {
                    try {
                        Write-Verbose "File to upload '$($fileToUpload.FullName)'"

                        $returnResultObject = $true

                        #region WORKAROUND rename file: remove '[' and ']'
                        # https://github.com/darkoperator/Posh-SSH/issues/381
                        $fileRenamed = $false

                        if ($fileToUpload.Name -match '\[|\]') {
                            try {
                                $newFileName = $fileToUpload.Name.replace('[', '(').replace(']', ')')

                                Write-Verbose "rename file to '$newFileName'"

                                $newPath = Join-Path -Path $fileToUpload.DirectoryName -ChildPath $newFileName

                                if (Test-Path -Path $newPath -PathType Leaf) {
                                    throw "A file with the same name already exists at path '$($fileToUpload.DirectoryName)'"
                                }

                                $params = @{
                                    Path    = $fileToUpload.FullName 
                                    NewName = $newFileName
                                    Force   = $true
                                }
                                Rename-Item @params

                                $fileToUpload = Get-Item -Path $newPath

                                $fileRenamed = $true
                            }
                            catch {
                                $errorMessage = "Failed to rename file '$($fileToUpload.FullName)' to '$newFileName': $_"

                                $Error.RemoveAt(0)

                                $result = [PSCustomObject]@{
                                    DateTime    = Get-Date
                                    Source      = $path.Source
                                    Destination = $path.Destination
                                    FileName    = $fileToUpload.Name
                                    FileLength  = $fileToUpload.Length
                                    Actions     = @()
                                    Moved       = $false
                                    Errors      = @($errorMessage)
                                }

                                Write-Warning $errorMessage

                                continue
                            }
                        }
                        #endregion

                        #region Only process unique file names
                        if ($processedFiles[$fileToUpload.Name]) {
                            Write-Verbose "File name '$($fileToUpload.Name)' already processed"

                            $returnResultObject = $false

                            continue
                        }

                        $processedFiles[$fileToUpload.Name] = $fileToUpload
                        #endregion

                        $result = [PSCustomObject]@{
                            DateTime    = Get-Date
                            Source      = $path.Source
                            Destination = $path.Destination
                            FileName    = $fileToUpload.Name
                            FileLength  = $fileToUpload.Length
                            Actions     = @()
                            Moved       = $false
                            Errors      = @()
                        }

                        if ($fileRenamed) {
                            $result.Actions += 'renamed file by removing square brackets in file name'
                        }

                        $tempFile = @{
                            sftp  = '{0}/{1}' -f
                            $tempFolder.sftp, $result.FileName
                            local = '{0}\{1}' -f
                            $tempFolder.local, $result.FileName
                        }

                        $isLocalTempFile = $fileToUpload.FullName -eq $tempFile.local
                        
                        #region Zero size file
                        if (-not $isLocalTempFile) {
                            if (
                                $ExcludeZeroSizeFile -and 
                                ($fileToUpload.Length -eq 0)
                            ) {
                                Save-ActionMessageHC "file size 0 bytes, file not moved, option 'ExcludeZeroSizeFile' enabled"

                                continue
                            }
                        }
                        #endregion

                        #region Test duplicate file in destination folder
                        if (-not $OverwriteFile) {
                            $isDuplicateFileInDestinationFolder = $sftpServerContent.rootFiles.where(
                                {
                                    $fileToUpload.Name -eq $_.Name
                                }
                            )

                            if ($isDuplicateFileInDestinationFolder) {
                                Save-ErrorMessageHC 'Duplicate file in destination folder, use OverwriteFile if needed'

                                continue
                            }
                        }
                        #endregion

                        #region Move file from local source folder to local temp folder
                        if (-not $isLocalTempFile) {
                            try {
                                $params = @{
                                    Path        = $fileToUpload.FullName
                                    Destination = $tempFile.local
                                    Force       = $true
                                }

                                Write-Verbose "Move file '$($params.Path)' to '$($params.Destination)'"

                                Start-RetryActionHC -ScriptBlock {
                                    Move-Item @params
                                }

                                Save-ActionMessageHC 'moved file from local source folder to local temp folder'
                            }
                            catch {
                                Save-ErrorMessageHC "Failed moving file from local source folder to local temp folder: $_"

                                $Error.RemoveAt(0)

                                continue
                            }
                        }
                        #endregion

                        #region Upload file from local temp folder to SFTP temp folder
                        try {
                            $params = @{
                                Path        = $tempFile.local
                                Destination = $tempFolder.sftp
                                Force       = $true
                            }

                            Write-Verbose "Upload file '$($params.Path)' to 'SFTP:$($params.Destination)'"

                            if ($isLocalTempFile) {
                                Save-ActionMessageHC 'this file failed during the last run'
                            }

                            Start-RetryActionHC -ScriptBlock {
                                Set-SFTPItem @sessionParams @params
                            }

                            Save-ActionMessageHC 'uploaded file from local temp folder to SFTP temp folder'
                        }
                        catch {
                            Save-ErrorMessageHC "failed to upload file in local temp folder to SFTP temp folder: $_"

                            $Error.RemoveAt(0)

                            continue
                        }
                        #endregion

                        #region Move file from SFTP temp folder to SFTP destination folder
                        try {
                            $isDuplicateInSftpDestinationFolder = $sftpServerContent.rootFiles.where(
                                {
                                    $fileToUpload.Name -eq $_.Name
                                }
                            )

                            $params = @{
                                Source          = $tempFile.sftp
                                Destination     = "$sftpPath$($result.FileName)"
                                isDuplicateFile = [boolean]$isDuplicateInSftpDestinationFolder
                            }

                            Move-SFTPItemHC @params

                            Save-ActionMessageHC 'moved file from SFTP temp folder to SFTP destination folder'
                        }
                        catch {
                            Save-ErrorMessageHC "Failed to move file from SFTP temp folder to SFTP destination folder: $_"

                            $Error.RemoveAt(0)

                            continue
                        }
                        #endregion

                        #region Remove local temp file
                        try {
                            Write-Verbose "Remove file '$($tempFile.local)'"

                            Start-RetryActionHC -ScriptBlock {
                                $tempFile.local | Remove-Item -Force
                            }

                            Save-ActionMessageHC 'removed file in local temp folder'
                        }
                        catch {
                            Save-ErrorMessageHC "Failed to remove file '$($tempFile.local)' in the local temp folder: $_"

                            $Error.RemoveAt(0)

                            continue
                        }
                        #endregion

                        Write-Verbose 'file moved successfully'
                        $result.Moved = $true
                    }
                    catch {
                        Save-ErrorMessageHC $_
                        $Error.RemoveAt(0)
                    }
                    finally {
                        if ($returnResultObject) {
                            Write-Verbose 'Return result object'

                            $result
                        }
                        else {
                            Write-Verbose 'No result object to return'
                        }
                    }
                }
            }
        }
        catch {
            Write-Warning $_

            [PSCustomObject]@{
                DateTime    = Get-Date
                Source      = $path.Source
                Destination = $path.Destination
                FileName    = $null
                FileLength  = $null
                Actions     = @()
                Errors      = @($_)
            }
            $Error.RemoveAt(0)
        }
        finally {
            #region Close SFTP session
            if ($sessionParams.SessionID) {
                Write-Verbose 'Close SFTP session'

                $params = @{
                    ErrorAction = 'Ignore'
                }
                $null = Remove-SFTPSession @sessionParams @params
            }
            #endregion
        }
    }

    #region Run code serial or parallel
    #region Create job objects
    # A job object contains all data required to handle one path. This avoids
    # the use of '$using:', which is only available when the code runs in
    # parallel, and makes the code in $scriptBlock identical for serial and
    # parallel execution.
    $jobs = foreach ($pathItem in $Paths) {
        [PSCustomObject]@{
            Path                       = $pathItem
            SftpComputerName           = $SftpComputerName
            SftpCredential             = $SftpCredential
            SftpPort                   = $SftpPort
            SftpOpenSshKeyFile         = $SftpOpenSshKeyFile
            MatchFileNameRegex         = $MatchFileNameRegex
            OverwriteFile              = $OverwriteFile
            ExcludeZeroSizeFile        = $ExcludeZeroSizeFile
            AttemptCount               = $AttemptCount
            WaitSecondsBetweenAttempts = $WaitSecondsBetweenAttempts
            VerbosePreference          = $VerbosePreference
        }
    }
    #endregion

    # 'UseNewRunspace' is no longer needed: a new runspace per path was a
    # workaround for the module 'Posh-SSH' that failed to load correctly in a
    # reused runspace. Import-ModuleWithLockHC now makes the import thread
    # safe, so runspaces can be reused, which is faster and results in fewer
    # concurrent module imports.
    $parallelParams = @{
        InputObject   = @($jobs)
        ScriptBlock   = $scriptBlock
        ThrottleLimit = $MaxConcurrentPaths
    }
    Invoke-WithOptionalParallelismHC @parallelParams

    Write-Verbose 'All jobs finished'
    #endregion
}
catch {
    $M = $_
    Write-Warning $M
    $Error.RemoveAt(0)
    throw $M
}
