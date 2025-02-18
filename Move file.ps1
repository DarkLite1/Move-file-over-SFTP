#Requires -Version 7
#Requires -Modules Posh-SSH

<#
.SYNOPSIS
    Move files to or from an SFTP server.

.DESCRIPTION
    Move files to or from an SFTP server.

    The move CmdLets (Move-Item and Move-SFTPItem) are used because they fail 
    when a file is in use. The download CmdLet 'Get-SFTPItem' does not fail when
    a file is in use. 

    tempFolder = 'sftpTransfer/download' 

    DOWNLOAD FILE FROM SFTP SERVER
    1. Test if tempFolder on SFTP server has files
        > yes: previous download failed
            - 
        

    - Download file from SFTP server
        tempFolder = 'sftpTransfer/download' 
        1. on SFTP server:
            - Create tempFolder on SFTP server
            - Try to move file to tempFolder on SFTP server
            > failure: 
                - file in use: retry
                - duplicate file: 
                    > overwrite true: overwrite
                    > overwrite false: leave file in tempFolder and throw error
            > success: continue
        2. on local file system
            - Create tempFolder on local file system
            - Download file from tempFolder on SFTP server to local tempFolder
                (connection issues, disk full, ..)
                > failure:
                    - file in use: not possible, we are the only consumer and we 
                      can lock down permissions on tempFolder if needed
                    - duplicate file: 
                        > overwrite true: overwrite
                        > overwrite false: leave file in tempFolder and throw error
                > success: 
                    - remove file in tempFolder on the SFTP server

.PARAMETER Paths
    Lost of source and destination folders.

.PARAMETER SftpComputerName
    The URL where the SFTP server can be reached.

.PARAMETER SftpPath
    Path to th folder on the SFTP server.

.PARAMETER SftpCredential
    The SFTP credential object used to authenticate to the SFTP server.

.PARAMETER SftpOpenSshKeyFile
    The password used to authenticate to the SFTP server. This is an
    SSH private key file in the OpenSSH format converted to an array of strings.

.PARAMETER FileExtensions
    Only the files with a matching file extension will be downloaded. If blank,
    all files will be downloaded.

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

Param (
    [Parameter(Mandatory)]
    [String]$SftpComputerName,
    [Parameter(Mandatory)]
    [PSCredential]$SftpCredential,
    [Parameter(Mandatory)]
    [PSCustomObject[]]$Paths,
    [Parameter(Mandatory)]
    [Int]$MaxConcurrentJobs,
    [String[]]$SftpOpenSshKeyFile,
    [String[]]$FileExtensions,
    [Boolean]$OverwriteFile,
    [Int]$AttemptCount = 5,
    [Int]$WaitSecondsBetweenAttempts = 3
)

try {
    # $VerbosePreference = 'Continue'

    $scriptBlock = {
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
            Param (
                [parameter(Mandatory)]
                [String]$Path,
                [parameter(Mandatory)]
                [String]$Destination
            )

            $WarningPreference = 'Continue'
            $getSftpItemWarningMessages = @()

            $params = @{
                Path            = $Path
                Destination     = $Destination
                WarningVariable = 'getSftpItemWarningMessages'
            }
            Get-SFTPItem @sessionParams @params

            if ($getSftpItemWarningMessages) {
                foreach ($warning in $getSftpItemWarningMessages) {
                    throw $warning
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
            Param (
                [Parameter(Mandatory)]
                [scriptblock]$ScriptBlock,
                [ValidateRange(1, 25)]
                [int]$RetryCount = $AttemptCount,
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
                        Write-Warning "Attempt $($attempt.count)/$AttemptCount failed"
                    }
                    $errorMessage = $_
                    $Error.RemoveAt(0)
                }
            }
        
            if (-not $attempt.success) {
                throw $errorMessage
            }
        }

        try {
            $path = $_

            Write-Verbose "Source '$($path.Source)' Destination '$($path.Destination)'"

            #region Set defaults
            # workaround for https://github.com/PowerShell/PowerShell/issues/16894
            $ProgressPreference = 'SilentlyContinue'
            $ErrorActionPreference = 'Stop'
            #endregion

            #region Declare variables for code running in parallel
            if (-not $MaxConcurrentJobs) {
                $VerbosePreference = $using:VerbosePreference

                $SftpComputerName = $using:SftpComputerName
                $SftpOpenSshKeyFile = $using:SftpOpenSshKeyFile
                $sftpCredential = $using:sftpCredential

                $FileExtensions = $using:FileExtensions
                $OverwriteFile = $using:OverwriteFile
                $AttemptCount = $using:AttemptCount
                $WaitSecondsBetweenAttempts = $using:WaitSecondsBetweenAttempts
            }
            #endregion

            $tempFolder = @{
                download = 'sftpTransfer/download' 
                upload   = 'sftpTransfer/upload' 
            }

            if ($path.Source -like 'sftp*' ) {
                Write-Verbose 'Download from SFTP server'

                #region Get all files and folders on local file system
                try {
                    $localFilesAndFoldersInDestination = Get-ChildItem -LiteralPath $path.Destination -Recurse

                    $localFilesInDestinationFolder = $localFilesAndFoldersInDestination | Where-Object {
                        (-not $_.PSIsContainer) -and
                        $_.Directory.FullName -eq $path.Destination
                    }
                }
                catch {
                    throw "Path '$($path.Destination)' not found on the file system"
                }
                #endregion

                #region Create temp folder on local file system
                $joinPath = @{
                    Path      = $path.Destination 
                    ChildPath = $tempFolder.download
                }
                $localTempDownloadFolder = Join-Path @joinPath
                
                $isLocalTempDownloadFolderCreated = $localFilesAndFoldersInDestination | Where-Object {
                    ($_.PSIsContainer) -and
                    ($_.FullName -eq $localTempDownloadFolder)
                }

                if (-not ($isLocalTempDownloadFolderCreated)) {
                    try {
                        Write-Verbose "Create folder '$localTempDownloadFolder '"

                        $null = New-Item -Path $localTempDownloadFolder -ItemType Directory
                    }
                    catch {
                        $M = "Failed creating local temporary download folder '$localTempDownloadFolder': $_"
                        $Error.RemoveAt(0)
                        throw $M        
                    }
                }
                #endregion

                #region Open SFTP session
                try {
                    Write-Verbose 'Open SFTP session'

                    $params = @{
                        ComputerName      = $SftpComputerName
                        Credential        = $sftpCredential
                        AcceptKey         = $true
                        Force             = $true
                        ConnectionTimeout = 60
                    }

                    if ($SftpOpenSshKeyFile) {
                        $params.KeyString = $SftpOpenSshKeyFile
                    }

                    $sftpSession = New-SFTPSession @params

                    $sessionParams = @{
                        SessionId = $sftpSession.SessionID
                    }

                    Write-Verbose "SFTP session ID '$($sessionParams.SessionId)'"
                }
                catch {
                    $M = "Failed creating an SFTP session to '$SftpComputerName': $_"
                    $Error.RemoveAt(0)
                    throw $M
                }
                #endregion

                $sftpPath = $path.Source.TrimStart('sftp:')

                #region Get folder content on SFTP server
                try {
                    # https://github.com/darkoperator/Posh-SSH/issues/607
                    # ErrorAction Stop not respected
                    $errorMessage = $null

                    $sftpServerFolderContent = Get-SFTPChildItem @sessionParams -Path $sftpPath -Recurse -ErrorVariable 'errorMessage'

                    if ($errorMessage) { throw $errorMessage }
                }
                catch {
                    $M = "Failed retrieving the content of SFTP folder '$sftpPath'. Most likely the path does not exist on the SFTP server: $_"
                    $Error.RemoveAt(0)
                    throw $M
                }
                #endregion

                #region Select files to download on SFTP server
                try {
                    # Only select files on root level
                    $sftpServerFilesToDownload = $sftpServerFolderContent | Where-Object {
                        (-not $_.isDirectory) -and
                        ($_.FullName -eq "$($sftpPath)$($_.Name)") 
                    }

                    if ($FileExtensions) {
                        Write-Verbose "Select files with extension '$FileExtensions'"

                        $fileExtensionFilter = (
                            $FileExtensions | ForEach-Object { "$_$" }
                        ) -join '|'

                        $sftpServerFilesToDownload = $sftpServerFilesToDownload | Where-Object {
                            $_.Name -match $fileExtensionFilter
                        }
                    }

                    Write-Verbose "Found $($sftpServerFilesToDownload.Count) file(s) on the SFTP server to download"
                }
                catch {
                    $M = "Failed to select SFTP root files to download in folder '$sftpPath': $_"
                    $Error.RemoveAt(0)
                    throw $M
                }
                #endregion

                #region Create temp folder on SFTP server
                try {
                    $tempDownloadFolderSftpServer = "$($sftpPath)$($tempFolder.download)"

                    $isTempDownloadFolderOnSftpServerCreated = $sftpServerFolderContent | Where-Object {
                        $_.IsDirectory -and
                        $_.Name -eq $tempDownloadFolderSftpServer
                    }

                    if (-not $isTempDownloadFolderOnSftpServerCreated) {
                        Write-Verbose "Create folder 'sftp:$tempDownloadFolderSftpServer'"

                        New-SFTPItem @sessionParams -Path $tempDownloadFolderSftpServer -ItemType Directory -Recurse
                    }
                }
                catch {
                    $M = "Failed creating folder 'sftp:$tempDownloadFolderSftpServer' $_"
                    $Error.RemoveAt(0)
                    throw $M
                }
                #endregion

                #region Remove incomplete downloaded files in local temp folder
                <# 
                $localIncompleteDownloadedFiles = $localFilesAndFoldersInDestination | Where-Object {
                    (-not $_.PSIsContainer) -and
                    ($_.Parent -eq $localTempDownloadFolder)
                }

                foreach (
                    $incompleteFile in $localIncompleteDownloadedFiles
                ) {
                    try {
                        Write-Verbose "Remove incomplete downloaded file '$incompleteFile'"

                        $result = [PSCustomObject]@{
                            DateTime    = Get-Date
                            Source      = $path.Source
                            Destination = $path.Destination
                            FileName    = $incompleteFile.Name
                            FileLength  = $incompleteFile.Length
                            Actions      = @()
                            Error       = $null
                        }
                            
                        Remove-Item -LiteralPath $incompleteFile.FullName -Force
                            
                        $result.Actions = "Removed incomplete downloaded file '$incompleteFile'"
                    }
                    catch {
                        $M = "Failed removing incomplete file '$incompleteFile': $_"
                        $Error.RemoveAt(0)
                    }
                    finally {
                        $result
                    }
                }
#>
                #endregion

                #region Exit when no files to download
                if (-not $sftpServerFilesToDownload) {
                    Write-Verbose 'No files to download'
                    Write-Verbose 'Exit script'
                    Return
                }
                #endregion

                foreach ($fileToDownload in $sftpServerFilesToDownload) {
                    try {
                        $result = [PSCustomObject]@{
                            DateTime    = Get-Date
                            Source      = $path.Source
                            Destination = $path.Destination
                            FileName    = $fileToDownload.Name
                            FileLength  = $fileToDownload.Length
                            Actions     = @()
                            Moved       = $false
                            Error       = $null
                        }

                        #region Test duplicate file
                        if (
                            (-not $OverwriteFile) -and 
                            ($localFile = $localFilesInDestinationFolder.where(
                                { $_.Name -eq $result.FileName }
                            ))
                        ) {
                            Write-Verbose 'Duplicate file on local file system'

                            $result.Error = 'Duplicate file in destination folder, use OverwriteFile if desired'
                            continue
                        }
                        #endregion

                        $result.DateTime = Get-Date

                        $sftpTempFilePath = '{0}/{1}' -f  
                        $tempDownloadFolderSftpServer, $result.FileName
                        
                        #region Move file to temp folder on SFTP server
                        try {
                            $params = @{
                                Path        = $fileToDownload.FullName
                                Destination = $sftpTempFilePath
                            }

                            Write-Verbose "Move file 'sftp:$($params.Path)' to 'sftp:$($params.Destination)'"

                            Start-RetryActionHC -ScriptBlock {
                                Move-SFTPItem @sessionParams @params
                            }

                            $result.Actions += 'File moved to SFTP temp folder'
                        }
                        catch {
                            throw "Failed moving file 'sftp:$($params.Path)' to 'sftp:$($params.Destination)', file most likely in use by another process: $_"
                        }
                        #endregion

                        $localTempFilePath = '{0}\{1}' -f 
                        $localTempDownloadFolder, $result.FileName

                        #region Download to temp folder on local file system
                        try {
                            $params = @{
                                Path        = $sftpTempFilePath
                                Destination = $localTempFilePath
                            }

                            Write-Verbose "Download file 'sftp:$($params.Path)' to '$($params.Destination)'"

                            Get-SFTPItemHC @params

                            $result.Actions += 'downloaded to local temp folder'
                        }
                        catch {
                            #region remove partially downloaded file
                            if (Test-Path -LiteralPath $params.Destination -PathType Leaf) {
                                try {
                                    $params.Destination | Remove-Item -Force
                                }
                                catch {
                                    $errorMessage = "Failed removing partially downloaded file '$($params.Destination)': $_"

                                    Write-Warning $errorMessage

                                    [PSCustomObject]@{
                                        DateTime    = $result.DateTime
                                        Source      = $result.Source
                                        Destination = $result.Destination
                                        FileName    = $result.FileName
                                        FileLength  = $result.FileLength
                                        Action      = $null
                                        Error       = $errorMessage
                                    }
                                }
                            }
                            #endregion

                            $M = "Failed to download file from SFTP server path '$($params.Path)' to '$($params.Destination)': $_"
                            $Error.RemoveAt(0)
                            throw $M
                        }
                        #endregion

                        #region Move file from local temp folder to destination folder
                        try {
                            $params = @{
                                LiteralPath = $localTempFilePath
                                Destination = '{0}\{1}' -f $path.destination, $result.FileName
                                Force       = $true
                            }

                            Write-Verbose "Move file '$($params.LiteralPath)' to '$($params.Destination)"

                            Start-RetryActionHC -ScriptBlock {
                                Move-Item @params
                            }                            

                            $result.Actions += 'moved to destination folder'
                        }
                        catch {
                            if ($_ -like '*Cannot create a file when that file already exists*') {
                                $M = "Failed to move file '$($params.LiteralPath)' to '$($params.Destination)': File '$($params.Destination)' in use by another process"
                            }
                            else {
                                $M = "Failed to move the file '$($params.LiteralPath)' to '$($params.Destination)': $_"
                            }

                            $Error.RemoveAt(0)
                            throw $M
                        }
                        #endregion

                        $result.Moved = $true
                    }
                    catch {
                        $result.Error = $_
                        Write-Warning $_
                        $Error.RemoveAt(0)
                    }
                    finally {
                        $result
                    }
                }
            }
            else {
                Write-Verbose 'Upload to SFTP server'

                #region Test source folder exists
                Write-Verbose 'Test if source folder exists'

                if (-not (
                        Test-Path -LiteralPath $path.Source -PathType 'Container')
                ) {
                    return [PSCustomObject]@{
                        Source      = $path.Source
                        Destination = $path.Destination
                        FileName    = $null
                        FileLength  = $null
                        DateTime    = Get-Date
                        Action      = $null
                        Error       = "Path '$($path.Source)' not found on the file system"
                    }
                }
                #endregion

                #region Get files to upload
                Write-Verbose 'Get files in source folder'

                $filesToUpload = Get-ChildItem -LiteralPath $path.Source -File

                if ($FileExtensions) {
                    $filesToUpload = $filesToUpload | Where-Object {
                        $FileExtensions -contains $_.Extension
                    }
                }

                if (-not $filesToUpload) {
                    Write-Verbose 'No files to upload'
                    Write-Verbose 'Exit script'
                    return
                }

                Write-Verbose "Found $($filesToUpload.Count) file(s) to upload"
                #endregion

                #region Open SFTP session
                try {
                    Write-Verbose 'Open SFTP session'

                    $params = @{
                        ComputerName      = $SftpComputerName
                        Credential        = $sftpCredential
                        AcceptKey         = $true
                        Force             = $true
                        ConnectionTimeout = 60
                    }

                    if ($SftpOpenSshKeyFile) {
                        $params.KeyString = $SftpOpenSshKeyFile
                    }

                    $sftpSession = New-SFTPSession @params

                    Write-Verbose "SFTP session ID '$($sessionParams.SessionId)'"

                    $sessionParams = @{
                        SessionId = $sftpSession.SessionID
                    }
                }
                catch {
                    $M = "Failed creating an SFTP session to '$SftpComputerName': $_"
                    $Error.RemoveAt(0)
                    throw $M
                }
                #endregion

                $sftpPath = $path.Destination.TrimStart('sftp:')

                #region Test SFTP path exists
                Write-Verbose "Test if SFTP path '$sftpPath' exists"

                if (-not (Test-SFTPPath @sessionParams -Path $sftpPath)) {
                    throw "Path '$sftpPath' not found on the SFTP server"
                }
                #endregion

                #region Get all SFTP files
                try {
                    $sftpFiles = Get-SFTPChildItem @sessionParams -Path $SftpPath -File
                }
                catch {
                    $errorMessage = "Failed retrieving SFTP files: $_"
                    $Error.RemoveAt(0)
                    throw $errorMessage
                }
                #endregion

                foreach ($file in $filesToUpload) {
                    try {
                        Write-Verbose "File '$($file.FullName)'"

                        $result = [PSCustomObject]@{
                            DateTime    = Get-Date
                            Source      = $path.Source
                            Destination = $path.Destination
                            FileName    = $file.Name
                            FileLength  = $file.Length
                            Actions     = @()
                            Moved       = $false
                            Error       = $null
                        }

                        $tempFile = @{
                            UploadFileName = $file.Name + $PartialFileExtension.Upload
                        }
                        $tempFile.UploadFilePath = Join-Path $result.Source $tempFile.UploadFileName

                        #region Duplicate file on SFTP server
                        if (
                            $sftpFile = $sftpFiles.where(
                                { $_.Name -eq $file.Name }, 'First'
                            )
                        ) {
                            Write-Verbose 'Duplicate file on SFTP server'
                            if ($OverwriteFile) {
                                try {
                                    Start-RetryActionHC -ScriptBlock {
                                        Write-Verbose 'Remove duplicate file on SFTP server'
    
                                        $removeParams = @{
                                            Path        = $sftpFile.FullName
                                            ErrorAction = 'Stop'
                                        }
                                        Remove-SFTPItem @sessionParams @removeParams
    
                                        [PSCustomObject]@{
                                            DateTime    = $result.DateTime
                                            Source      = $result.Source
                                            Destination = $result.Destination
                                            FileName    = $result.FileName
                                            FileLength  = $result.FileLength
                                            Action      = 'Removed duplicate file from SFTP server'
                                            Error       = $null
                                        }
                                    }          
                                }
                                catch {
                                    throw "Failed removing duplicate file from the SFTP server after multiple attempts within $($RetryCountOnLockedFiles * $RetryWaitSeconds) seconds (file in use): $errorMessage"
                                }
                            }
                            else {
                                throw 'Duplicate file on SFTP server, use Option.OverwriteFile if desired'
                            }
                        }
                        #endregion

                        $result.DateTime = Get-Date

                        #region Rename source file to temp file
                        try {
                            Start-RetryActionHC -ScriptBlock {
                                Write-Verbose "Rename source file to temp file '$($tempFile.UploadFileName)'"
                                $file |
                                    Rename-Item -NewName $tempFile.UploadFileName
                            }
                        }
                        catch {
                            throw "Failed renaming the source file: File in use: $_"
                        }
                        #endregion

                        #region Upload temp file to SFTP server
                        try {
                            $params = @{
                                Path        = $tempFile.UploadFilePath
                                Destination = $SftpPath
                            }

                            Write-Verbose 'Upload temp file'
                            Set-SFTPItem @sessionParams @params
                        }
                        catch {
                            $errorMessage = "Failed to upload file '$($tempFile.UploadFilePath)': $_"
                            $Error.RemoveAt(0)
                            throw $errorMessage
                        }
                        #endregion

                        #region Rename file on SFTP server
                        try {
                            Write-Verbose "Rename temp file on SFTP server to '$($result.FileName)'"

                            $params = @{
                                Path    = $SftpPath + $tempFile.UploadFileName
                                NewName = $result.FileName
                            }
                            Rename-SFTPFile @sessionParams @params
                        }
                        catch {
                            $errorMessage = "Failed to rename the file on the SFTP server from '$($tempFile.UploadFileName)' to '$($result.FileName)': $_"
                            $Error.RemoveAt(0)
                            throw $errorMessage
                        }
                        #endregion

                        #region Remove local temp file
                        try {
                            Write-Verbose 'Remove local temp file'

                            $tempFile.UploadFilePath | Remove-Item -Force
                        }
                        catch {
                            $errorMessage = "Failed to remove the local temp file '$($tempFile.UploadFilePath)': $_"
                            $Error.RemoveAt(0)
                            throw $errorMessage
                        }
                        #endregion

                        $result.Moved = $true
                    }
                    catch {
                        #region Rename temp file back to original file name
                        if (
                            Test-Path -LiteralPath $tempFile.UploadFilePath -PathType 'Leaf'
                        ) {
                            try {
                                Write-Warning 'Upload failed'
                                Write-Verbose "Rename temp file '$($tempFile.UploadFilePath)' back to its original name '$($file.Name)'"

                                $tempFile.UploadFilePath |
                                    Rename-Item -NewName $file.Name
                            }
                            catch {
                                [PSCustomObject]@{
                                    DateTime    = Get-Date
                                    Source      = $result.Source
                                    Destination = $result.Destination
                                    FileName    = $tempFile.Name
                                    FileLength  = $result.Length
                                    Action      = $null
                                    Error       = "Failed to rename temp file '$($tempFile.UploadFilePath)' back to its original name '$($file.Name)': $_"
                                }

                                $Error.RemoveAt(0)
                            }
                        }
                        #endregion

                        $result.Error = $_
                        Write-Warning $_
                        $Error.RemoveAt(0)
                    }
                    finally {
                        $result
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
                Action      = $null
                Error       = $_
            }
            $Error.RemoveAt(0)
        }
        finally {
            #region Close SFTP session
            if ($sessionParams.SessionID) {
                Write-Verbose 'Close SFTP session'

                $params = @{
                    SessionId   = $sessionParams.SessionID
                    ErrorAction = 'Ignore'
                }
                $null = Remove-SFTPSession @params
            }
            #endregion
        }
    }

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

    $Paths | ForEach-Object @foreachParams

    Write-Verbose 'All jobs finished'
    #endregion
}
catch {
    $M = $_
    Write-Warning $M
    $Error.RemoveAt(0)
    throw $M
}
