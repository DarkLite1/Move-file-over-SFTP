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
    [Int]$RetryCountOnLockedFiles = 3,
    [Int]$RetryWaitSeconds = 3,
    [hashtable]$PartialFileExtension = @{
        Upload   = '.UploadInProgress'
        Download = '.DownloadInProgress'
    }
)

try {
    # $VerbosePreference = 'Continue'

    $scriptBlock = {
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
                $PartialFileExtension = $using:PartialFileExtension
                $RetryCountOnLockedFiles = $using:RetryCountOnLockedFiles
                $RetryWaitSeconds = $using:RetryWaitSeconds
                $OverwriteFile = $using:OverwriteFile
            }
            #endregion

            $tempFolder = @{
                download = 'sftpTransfer/download' 
                upload   = 'sftpTransfer/upload' 
            }

            if ($path.Source -like 'sftp*' ) {
                Write-Verbose 'Download from SFTP server'

                #region Get all local files and folders
                try {
                    $localFilesAndFoldersInDestination = Get-ChildItem -LiteralPath $path.Destination -Recurse

                    $localFilesInDestinationFolder = $localFilesAndFoldersInDestination | Where-Object {
                        (-not $_.IsDirectory) -and
                        $_.Parent -eq $path.Destination
                    }
                }
                catch {
                    throw "Path '$($path.Destination)' not found on the file system"
                }
                #endregion

                #region Create temp local download folder
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

                $sftpPath = $path.Source.TrimStart('sftp:')

                #region Get SFTP root folder content
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

                #region Select SFTP root files to download
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

                    Write-Verbose "Found $($sftpServerFilesToDownload.Count) root folder file(s) to download"
                }
                catch {
                    $M = "Failed to select SFTP root files to download in folder '$sftpPath': $_"
                    $Error.RemoveAt(0)
                    throw $M
                }
                #endregion

                #region Create SFTP temp download folder
                try {
                    $tempDownloadFolderSftpServer = "$($sftpPath)$($tempFolder.download)"

                    Write-Verbose "Temp download folder on SFTP server '$tempDownloadFolderSftpServer'"

                    $isTempDownloadFolderOnSftpServerCreated = $sftpServerFolderContent | Where-Object {
                        $_.IsDirectory -and
                        $_.Name -eq $tempDownloadFolderSftpServer
                    }

                    if (-not $isTempDownloadFolderOnSftpServerCreated) {
                        Write-Verbose 'Create temp download folder'
                        New-SFTPItem @sessionParams -Path $tempDownloadFolderSftpServer -ItemType Directory -Recurse
                    }
                }
                catch {
                    $M = "Failed creating temp folder '$tempDownloadFolderSftpServer' on the SFTP server: $_"
                    $Error.RemoveAt(0)
                    throw $M
                }
                #endregion

                #region Remove incomplete downloaded files in local temp folder
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
                            Action      = $null
                            Error       = $null
                        }
                            
                        Remove-Item -LiteralPath $incompleteFile.FullName -Force
                            
                        $result.Action = "Removed incomplete downloaded file '$incompleteFile'"
                    }
                    catch {
                        $M = "Failed removing incomplete file '$incompleteFile': $_"
                        $Error.RemoveAt(0)
                    }
                    finally {
                        $result
                    }
                }
                #endregion

                #region Exit when no root files to download
                if (-not $sftpServerFilesToDownload) {
                    Write-Verbose 'No root folder files to download'
                    Write-Verbose 'Exit script'
                    Return
                }
                #endregion

                foreach ($fileToDownload in $sftpServerFilesToDownload) {
                    try {
                        Write-Verbose "File '$($fileToDownload.FullName)'"

                        $result = [PSCustomObject]@{
                            DateTime    = Get-Date
                            Source      = $path.Source
                            Destination = $path.Destination
                            FileName    = $fileToDownload.Name
                            FileLength  = $fileToDownload.Length
                            Action      = $null
                            Error       = $null
                        }

                        #region Test if the file was completely downloaded
                        $failedFile = $false

                        if (
                            $fileToDownload.Name -like "*$($PartialFileExtension.Download)"
                        ) {
                            Write-Verbose 'Files was not completely downloaded'

                            $failedFile = $true
                        }
                        #endregion

                        #region Create temp name
                        $tempFile = @{
                            DownloadFileName = $fileToDownload.Name + $PartialFileExtension.Download
                            DownloadFilePath = $fileToDownload.FullName +
                            $PartialFileExtension.Download
                        }

                        if ($failedFile) {
                            $tempFile.DownloadFileName = $fileToDownload.Name
                            $tempFile.DownloadFilePath = $fileToDownload.FullName

                            $result.FileName = $fileToDownload.Name.TrimEnd(
                                $PartialFileExtension.Download
                            )
                        }
                        #endregion

                        #region Test file already present
                        if (
                            $localFile = $localFilesInDestinationFolder.where(
                                { $_.Name -eq $result.FileName }
                            )
                        ) {
                            Write-Verbose 'Duplicate file on local file system'

                            if ($OverwriteFile) {
                                $retryCount = 0
                                $fileLocked = $true

                                while (
                                    ($fileLocked) -and
                                    ($retryCount -lt $RetryCountOnLockedFiles)
                                ) {
                                    try {
                                        Write-Verbose 'Remove duplicate file'

                                        $removeParams = @{
                                            LiteralPath = $localFile.FullName
                                            ErrorAction = 'Stop'
                                        }
                                        Remove-Item @removeParams

                                        [PSCustomObject]@{
                                            DateTime    = $result.DateTime
                                            Source      = $result.Source
                                            Destination = $result.Destination
                                            FileName    = $result.FileName
                                            FileLength  = $result.FileLength
                                            Action      = 'Removed duplicate file from the file system'
                                            Error       = $null
                                        }

                                        $fileLocked = $false
                                    }
                                    catch {
                                        $errorMessage = $_
                                        $Error.RemoveAt(0)
                                        $retryCount++
                                        Write-Warning "File locked, wait $RetryWaitSeconds seconds, attempt $retryCount/$RetryCountOnLockedFiles"
                                        Start-Sleep -Seconds $RetryWaitSeconds
                                    }
                                }

                                if ($fileLocked) {
                                    throw "Failed removing duplicate file from the local file system after multiple attempts within $($RetryCountOnLockedFiles * $RetryWaitSeconds) seconds (file in use): $errorMessage"
                                }
                            }
                            else {
                                throw "Duplicate file '$($result.FileName)' in folder '$($path.Destination)', use Option.OverwriteFile if desired"
                            }
                        }
                        #endregion

                        $result.DateTime = Get-Date

                        #region Rename source file to temp file on SFTP server
                        if (-not $failedFile) {
                            $retryCount = 0
                            $fileLocked = $true

                            while (
                                ($fileLocked) -and
                                ($retryCount -lt $RetryCountOnLockedFiles)
                            ) {
                                try {
                                    $params = @{
                                        Path    = $fileToDownload.FullName
                                        NewName = $tempFile.DownloadFileName
                                    }

                                    Write-Verbose "Rename source file on SFTP server to temp file '$($params.NewName)'"

                                    Rename-SFTPFile @sessionParams @params

                                    $fileLocked = $false
                                }
                                catch {
                                    $errorMessage = $_
                                    $Error.RemoveAt(0)
                                    $retryCount++
                                    Write-Warning "File locked, wait $RetryWaitSeconds seconds, attempt $retryCount/$RetryCountOnLockedFiles"
                                    Start-Sleep -Seconds $RetryWaitSeconds
                                }
                            }

                            if ($fileLocked) {
                                throw "Failed renaming file on the SFTP server after multiple attempts within $($RetryCountOnLockedFiles * $RetryWaitSeconds) seconds (file in use): $errorMessage"
                            }
                        }
                        #endregion

                        #region Download temp file from the SFTP server
                        try {
                            Write-Verbose 'Download temp file'

                            # Get-SFTPItem does not throw an error, only a warning
                            # https://github.com/darkoperator/Posh-SSH/issues/606

                            $WarningPreference = 'Continue'
                            $getSftpItemWarningMessages = @()

                            $params = @{
                                Path            = $tempFile.DownloadFilePath
                                Destination     = $path.Destination
                                WarningVariable = 'getSftpItemWarningMessages'
                            }
                            Get-SFTPItem @sessionParams @params

                            if ($getSftpItemWarningMessages) {
                                foreach ($warning in $getSftpItemWarningMessages) {
                                    throw $warning
                                }
                            }
                        }
                        catch {
                            $M = "Failed to download file '$($tempFile.DownloadFilePath)': $_"
                            $Error.RemoveAt(0)
                            throw $M
                        }
                        #endregion

                        #region Move temp file to destination folder
                        try {
                            Write-Verbose 'Rename temp file'

                            $params = @{
                                LiteralPath = Join-Path $path.Destination $tempFile.DownloadFileName
                                NewName     = $result.FileName
                            }
                            # Rename-Item @params
                        }
                        catch {
                            $M = "Failed to rename the file '$($params.LiteralPath)' to '$($result.FileName)': $_"
                            $Error.RemoveAt(0)
                            throw $M
                        }
                        #endregion

                        #region Remove file from the SFTP server
                        try {
                            Write-Verbose 'Remove temp file'

                            Remove-SFTPItem @sessionParams -Path $tempFile.DownloadFilePath
                        }
                        catch {
                            $M = "Failed to remove file '$($tempFile.DownloadFilePath)': $_"
                            $Error.RemoveAt(0)
                            throw $M
                        }
                        #endregion

                        if ($failedFile) {
                            $result.Action = 'File moved after previous unsuccessful move'
                        }
                        else {
                            $result.Action = 'File moved'
                        }
                    }
                    catch {
                        #region Rename temp file back to original file name
                        $testPathParams = @{
                            LiteralPath = Join-Path $path.Destination ($result.FileName + $PartialFileExtension.Download)
                            PathType    = 'Leaf'
                        }

                        if (Test-Path @testPathParams) {
                            try {
                                Write-Warning 'Download failed'
                                Write-Verbose "Remove incomplete downloaded file '$($testPathParams.LiteralPath)'"

                                $testPathParams.LiteralPath | Remove-Item
                            }
                            catch {
                                [PSCustomObject]@{
                                    DateTime    = Get-Date
                                    Source      = $result.Source
                                    Destination = $result.Destination
                                    FileName    = ($result.FileName + $PartialFileExtension.Download)
                                    FileLength  = $result.FileLength
                                    Action      = $null
                                    Error       = "Failed to remove incomplete downloaded file '$($testPathParams.LiteralPath)': $_"
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

                #region Remove incomplete uploaded files from the SFTP server
                foreach (
                    $partialFile in
                    $sftpFiles.where(
                        { $_.Name -like "*$($PartialFileExtension.Upload)" }
                    )
                ) {
                    try {
                        $result = [PSCustomObject]@{
                            DateTime    = Get-Date
                            Source      = $path.Source
                            Destination = $path.Destination
                            FileName    = $partialFile.Name
                            FileLength  = $partialFile.Length
                            Action      = $null
                            Error       = $null
                        }

                        Write-Verbose "Remove incomplete uploaded file '$($partialFile.FullName)'"

                        Remove-SFTPItem @sessionParams -Path $partialFile.FullName

                        $result.Action = 'Removed incomplete uploaded file'
                    }
                    catch {
                        $result.Error = "Failed removing incomplete uploaded file: $_"
                        Write-Warning $result.Error
                        $Error.RemoveAt(0)
                    }
                    finally {
                        $result
                    }
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
                            Action      = $null
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
                                $retryCount = 0
                                $fileLocked = $true

                                while (
                                        ($fileLocked) -and
                                        ($retryCount -lt $RetryCountOnLockedFiles)
                                ) {
                                    try {
                                        Write-Verbose 'Remove duplicate file on SFTP server'

                                        $removeParams = @{
                                            Path        = $sftpFile.FullName
                                            ErrorAction = 'Stop'
                                        }
                                        Remove-SFTPItem @sessionParams @removeParams

                                        $fileLocked = $false

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
                                    catch {
                                        $errorMessage = $_
                                        $Error.RemoveAt(0)
                                        $retryCount++
                                        Write-Warning "File locked, wait $RetryWaitSeconds seconds, attempt $retryCount/$RetryCountOnLockedFiles"
                                        Start-Sleep -Seconds $RetryWaitSeconds
                                    }
                                }

                                if ($fileLocked) {
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
                        $retryCount = 0
                        $fileLocked = $true

                        while (
                                ($fileLocked) -and
                                ($retryCount -lt $RetryCountOnLockedFiles)
                        ) {
                            try {
                                Write-Verbose "Rename source file to temp file '$($tempFile.UploadFileName)'"
                                $file |
                                Rename-Item -NewName $tempFile.UploadFileName
                                $fileLocked = $false
                            }
                            catch {
                                $errorMessage = $_
                                $Error.RemoveAt(0)
                                $retryCount++
                                Write-Warning "File locked, wait $RetryWaitSeconds seconds, attempt $retryCount/$RetryCountOnLockedFiles"
                                Start-Sleep -Seconds $RetryWaitSeconds
                            }
                        }

                        if ($fileLocked) {
                            throw "Failed renaming the source file after multiple attempts within $($RetryCountOnLockedFiles * $RetryWaitSeconds) seconds (file in use): $errorMessage"
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

                        $result.Action = 'File moved'
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
