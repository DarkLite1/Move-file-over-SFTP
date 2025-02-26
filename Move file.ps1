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
            Param (
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
        function Remove-LocalFileHC {
            Param (
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
                        
                        Save-ActionMessageHC "removed file '$Path'"
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
            Param (
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
            Param (
                [parameter(Mandatory)]
                [string]$ActionMessage
            )

            Write-Verbose "Add action: $ActionMessage"

            $result.Actions += $ActionMessage
        }
 
        try {
            $path = $_

            Write-Verbose "Path source '$($path.Source)' destination '$($path.Destination)'"

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

            $tempFolderName = @{
                download = 'sftpTransfer/download' 
                upload   = 'sftpTransfer/upload' 
            }

            if ($path.Source -like 'sftp*' ) {
                Write-Verbose 'Download from SFTP server'
                <# 
                    Files moved to the SFTP temporary folder during a previous 
                    run, but not successfully downloaded, will be re-downloaded 
                    in this run. 
                    
                    If a file with the same name exists in both the SFTP 
                    source and the SFTP temporary folder, the temporary file 
                    will be downloaded first. The new file in the SFTP source
                    folder will be downloaded during the next run of the script.
                #>

                $processedFiles = @{}

                $tempFolder = @{}

                $joinPath = @{
                    Path      = $path.Destination 
                    ChildPath = $tempFolderName.download
                }
                $tempFolder.local = Join-Path @joinPath

                #region Get all files and folders on local file system
                try {
                    $localFilesAndFoldersInDestination = @(
                        Get-ChildItem -LiteralPath $path.Destination -Recurse
                    )

                    $localFilesInDestinationFolder = 
                    $localFilesAndFoldersInDestination.Where(
                        {
                            (-not $_.PSIsContainer) -and
                            ($_.Directory.FullName -eq $path.Destination)
                        }
                    )
                    
                    $localFilesInTempDownloadFolder = 
                    $localFilesAndFoldersInDestination.Where(
                        {
                            (-not $_.PSIsContainer) -and
                            ($_.Directory.FullName -eq $tempFolder.local)
                        }
                    )
                }
                catch {
                    throw "Path '$($path.Destination)' not found on the file system"
                }
                #endregion

                #region Create temp folder on local file system
                $isLocalTempDownloadFolderCreated = $localFilesAndFoldersInDestination.Where(
                    {
                        ($_.PSIsContainer) -and
                        ($_.FullName -eq $tempFolder.local)
                    }
                )

                if (-not ($isLocalTempDownloadFolderCreated)) {
                    try {
                        Write-Verbose "Create folder '$($tempFolder.local)'"

                        $null = New-Item -Path $tempFolder.local -ItemType Directory
                    }
                    catch {
                        throw "Failed creating local temporary download folder '$($tempFolder.local)': $_"
                    }
                }
                #endregion

                #region Move previously downloaded files
                <# 
                    When files could not be moved from the local temp folder
                    to the destination folder during the previous run, they will
                    now be moved to the destination folder.
                    
                    Files get stuck in the local temp folder when the file in 
                    the destination folder was in use during the previous run.
                #>
                foreach (
                    $localTempFile in 
                    $localFilesInTempDownloadFolder
                ) {
                    try {
                        Write-Verbose "Found previous completely downloaded file '$localTempFile'"

                        $processedFiles[$localTempFile.Name] = $localTempFile

                        $result = [PSCustomObject]@{
                            DateTime    = Get-Date
                            Source      = $localTempFile.Directory.FullName
                            Destination = $path.Destination
                            FileName    = $localTempFile.Name
                            FileLength  = $localTempFile.Length
                            Actions     = @()
                            Moved       = $false
                            Errors      = @()
                        }

                        if (
                            (-not $OverwriteFile) -and    
                            ($localFilesInDestinationFolder.Name -contains $localTempFile.Name)
                        ) {
                            Save-ErrorMessageHC "In the destination folder is a file with the same name '$($result.FileName)' as a previously downloaded file, use OverwriteFile if needed"

                            Continue
                        }

                        $params = @{
                            LiteralPath = Join-Path $result.Source $result.FileName
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

                        Save-ActionMessageHC 'moved previously downloaded file to the destination folder'

                        $result.Moved = $true
                    }
                    catch {
                        Save-ErrorMessageHC "Failed to move the previously downloaded file to the destination folder: $_"

                        $Error.RemoveAt(0)
                    }
                    finally {
                        $result
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
                        Verbose           = $false
                    }

                    if ($SftpOpenSshKeyFile) {
                        $params.KeyString = $SftpOpenSshKeyFile
                    }

                    $sftpSession = New-SFTPSession @params

                    $sessionParams = @{
                        SessionId = $sftpSession.SessionID
                        Verbose   = $false
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

                $tempFolder.sftp = "$($sftpPath)$($tempFolderName.download)"

                #region Get folder content on SFTP server
                try {
                    Write-Verbose "Get folder content 'sftp:$SftpPath'"

                    $sftpServerFolderContent = @(
                        Get-SFTPChildItemHC -Path $sftpPath
                    )

                    $sftpServerTempFiles = $sftpServerFolderContent.where(
                        {
                            ( -not $_.isDirectory ) -and
                            ($_.FullName -eq "$($tempFolder.sftp)/$($_.Name)")
                        }
                    )

                    $sftpServerSourceFiles = $sftpServerFolderContent.where(
                        {
                            ( -not $_.isDirectory ) -and
                            ($_.FullName -eq "$sftpPath$($_.Name)") 
                        }
                    )
                }
                catch {
                    $M = "Failed retrieving the content of SFTP folder '$sftpPath'. Most likely the path does not exist on the SFTP server: $_"
                    $Error.RemoveAt(0)
                    throw $M
                }
                #endregion

                #region Select files to download by file extension
                try {
                    $filesToDownload = $sftpServerTempFiles + $sftpServerSourceFiles

                    if ($FileExtensions) {
                        Write-Verbose "Select files with extension '$FileExtensions'"

                        $fileExtensionFilter = (
                            $FileExtensions | ForEach-Object { "$_$" }
                        ) -join '|'

                        $filesToDownload = $filesToDownload.where(
                            { $_.Name -match $fileExtensionFilter }
                        )
                    }

                    Write-Verbose "Found $($filesToDownload.Count) file(s) on the SFTP server to download"
                }
                catch {
                    $M = "Failed to select SFTP root files to download in folder '$sftpPath': $_"
                    $Error.RemoveAt(0)
                    throw $M
                }
                #endregion

                #region Create temp folder on SFTP server
                try {
                    $isTempDownloadFolderOnSftpServerCreated = $sftpServerFolderContent.where(
                        {
                            $_.IsDirectory -and
                            $_.FullName -eq $tempFolder.sftp
                        }
                    )

                    if (-not $isTempDownloadFolderOnSftpServerCreated) {
                        Write-Verbose "Create folder 'sftp:$($tempFolder.sftp)'"

                        New-SFTPItem @sessionParams -Path $tempFolder.sftp -ItemType Directory -Recurse
                    }
                }
                catch {
                    $M = "Failed creating folder 'sftp:$($tempFolder.sftp)' $_"
                    $Error.RemoveAt(0)
                    throw $M
                }
                #endregion

                #region Exit when no files to download
                if (-not $filesToDownload) {
                    Write-Verbose 'No files to download'
                    Write-Verbose 'Exit script'
                    Return
                }
                #endregion

                foreach ($fileToDownload in $filesToDownload) {
                    try {
                        Write-Verbose "File to download '$($fileToDownload.FullName)'"

                        #region Only process unique file names
                        if ($processedFiles[$fileToDownload.Name]) {
                            Write-Verbose "File name '$($fileToDownload.Name)' already processed"
                            continue
                        }

                        $processedFiles[$filesToDownload.Name] = $filesToDownload
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

                        #region Test duplicate file in destination folder
                        $isDuplicateFileInDestinationFolder = $localFilesInDestinationFolder.where(
                            { 
                                $fileToDownload.Name -eq $_.Name 
                            }
                        )

                        if (
                            $isDuplicateFileInDestinationFolder -and 
                            (-not $OverwriteFile)
                        ) {
                            Save-ErrorMessageHC 'Duplicate file in destination folder, use OverwriteFile if needed'    

                            Continue
                        }
                        #endregion

                        #region Move file to SFTP temp folder
                        $isTempFile = $fileToDownload.FullName -eq $tempFile.sftp
                        
                        if (-not $isTempFile) {
                            try {
                                $params = @{
                                    Path        = $fileToDownload.FullName
                                    Destination = $tempFile.sftp
                                    Force       = $true
                                }

                                Write-Verbose "Move file 'sftp:$($params.Path)' to 'sftp:$($params.Destination)'"

                                Start-RetryActionHC -ScriptBlock {
                                    Move-SFTPItem @sessionParams @params
                                }

                                Save-ActionMessageHC 'file moved to SFTP temp folder'
                            }
                            catch {
                                Save-ErrorMessageHC "Failed moving file to sftp temp folder, because it was most likely in use by another process: $_"

                                $Error.RemoveAt(0)

                                continue
                            }
                        }
                        #endregion

                        #region Download SFTP file to local temp folder
                        try {
                            Write-Verbose "Download file 'sftp:$($tempFile.sftp)' to '$($tempFile.local)'"

                            Start-RetryActionHC -ScriptBlock {
                                $params = @{
                                    Path        = $tempFile.sftp
                                    Destination = $tempFolder.local
                                }
                                Get-SFTPItemHC @params
                            }

                            Save-ActionMessageHC 'downloaded to local temp folder'
                        }
                        catch {
                            Save-ErrorMessageHC "Failed to download file 'sftp:$($tempFile.sftp)' to '$($tempFile.local)': $_"

                            $Error.RemoveAt(0)

                            Remove-LocalFileHC -Path $tempFile.local

                            continue
                        }
                        #endregion

                        #region Remove SFTP temp file
                        try {
                            Write-Verbose "Remove file 'sftp:$($tempFile.sftp)'"
                            
                            Start-RetryActionHC -ScriptBlock {
                                $params = @{
                                    Path = $tempFile.sftp
                                }
                                Remove-SFTPItem @sessionParams @params
                            }

                            Save-ActionMessageHC 'removed file in SFTP temp folder'
                        }
                        catch {
                            Save-ErrorMessageHC "Failed to remove file 'sftp:$($tempFile.sftp)', most likely the file is in use: $_"

                            $Error.RemoveAt(0)

                            Remove-LocalFileHC -Path $tempFile.local

                            continue
                        }
                        #endregion

                        #region Move local temp file to destination folder
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
                                    
                                    Save-ActionMessageHC 'removed duplicate destination file'
                                }
                                # move-item has an error 'Cannot create file'
                                Move-Item @params

                                Save-ActionMessageHC 'temp file moved to destination folder'
                            }                            
                        }
                        catch {
                            Save-ErrorMessageHC "Failed to move temp file to destination folder: $_"

                            $Error.RemoveAt(0)

                            continue
                        }
                        #endregion

                        $result.Moved = $true
                    }
                    catch {
                        Save-ErrorMessageHC $_
                        $Error.RemoveAt(0)
                    }
                    finally {
                        $result
                    }
                }
            }
            else {
                Write-Verbose 'Upload to SFTP server'

                $joinPath = @{
                    Path      = $path.Source 
                    ChildPath = $tempFolderName.upload
                }
                $localTempUploadFolder = Join-Path @joinPath

                #region Get all files and folders on local file system
                try {
                    $localFilesAndFoldersInSource = @(
                        Get-ChildItem -LiteralPath $path.Source -Recurse
                    )

                    $localFilesInSourceFolder = 
                    $localFilesAndFoldersInSource.Where(
                        {
                            (-not $_.PSIsContainer) -and
                            $_.Directory.FullName -eq $path.Source
                        }
                    )
                    
                    $localFilesInTempUploadFolder = 
                    $localFilesAndFoldersInSource.Where(
                        {
                            (-not $_.PSIsContainer) -and
                            $_.Directory.FullName -eq $localTempUploadFolder
                        }
                    )
                }
                catch {
                    throw "Path '$($path.Source)' not found on the file system"
                }
                #endregion

                #region Create temp folder on local file system
                $isLocalTempUploadFolderCreated = $localFilesAndFoldersInSource.where(
                    {
                        ($_.PSIsContainer) -and
                        ($_.FullName -eq $localTempUploadFolder)
                    }
                )
                
                if (-not ($isLocalTempUploadFolderCreated)) {
                    try {
                        Write-Verbose "Create folder '$localTempUploadFolder '"
                
                        $null = New-Item -Path $localTempUploadFolder -ItemType Directory
                    }
                    catch {
                        throw "Failed creating local temporary upload folder '$localTempUploadFolder': $_"
                    }
                }
                #endregion

                #region Select files to upload
                <# 
                    Files in the local source folder and files in the local 
                    temp upload folder, as this folder contains files that 
                    previously failed uploading due to transfer issues 
                #>
                try {
                    $filesToUpload = $localFilesInSourceFolder + $localFilesInTempUploadFolder

                    if ($FileExtensions) {
                        Write-Verbose "Select files with extension '$FileExtensions'"

                        $filesToUpload = $filesToUpload.where(
                            { $FileExtensions -contains $_.Extension }
                        )
                    }

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
                        Verbose   = $false
                    }
                }
                catch {
                    $M = "Failed creating an SFTP session to '$SftpComputerName': $_"
                    $Error.RemoveAt(0)
                    throw $M
                }
                #endregion

                $sftpPath = $path.Destination.TrimStart('sftp:')

                $tempUploadFolderSftpServer = "$($sftpPath)$($tempFolderName.upload)"
                #region Get folder content on SFTP server
                try {
                    Write-Verbose "Get folder content 'sftp:$SftpPath'"

                    $sftpServerFolderContent = @(
                        Get-SFTPChildItemHC -Path $sftpPath
                    )

                    $sftpFilesInTempUploadFolder = $sftpServerFolderContent.Where(
                        { 
                            (-not $_.isDirectory ) -and
                            ($_.FullName -eq "$tempUploadFolderSftpServer/$($_.Name)")
                        }
                    )

                    $sftpFilesInUploadFolder = $sftpServerFolderContent.Where(
                        { 
                            (-not $_.isDirectory ) -and
                            ($_.FullName -eq "$sftpPath/$($_.Name)")
                        }
                    )
                }
                catch {
                    $M = "Failed retrieving the content of SFTP folder '$sftpPath'. Most likely the path does not exist on the SFTP server: $_"
                    $Error.RemoveAt(0)
                    throw $M
                }
                #endregion

                foreach ($fileToUpload in $filesToUpload) {
                    try {
                        Write-Verbose "File to upload '$($fileToUpload.FullName)'"

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

                        #region Incomplete uploaded file
                        <# 
                         - File in sftp temp folder and in local temp folder
                            > upload incomplete
                            > upload again 
                        #>
                        $isIncompleteUploadedFile = $false

                        if (
                            ($sftpFilesInTempUploadFolder.Name -contains $result.FileName) -and
                            ($sftpFilesInUploadFolder.Name -contains $result.FileName)
                        ) {
                            $isIncompleteUploadedFile = $true
                        }
                        #endregion

                        #region Upload completed but could not be moved
                        <# 
                        - File in sftp temp folder but not in local temp folder
                            > upload complete
                            > move to destination
                        #>
                        $isUploadedFileThatFailedToMoveToDestination = $false
                        
                        if (
                            ($sftpFilesInTempUploadFolder.Name -contains $result.FileName) -and
                            ($localTempUploadFolder.Name -notContains $result.FileName)
                        ) {
                            $isUploadedFileThatFailedToMoveToDestination = $true
                        }
                        #endregion

                        #region Duplicate file in sftp destination folder
                        $isDuplicateFileInSftpDestinationFolder = $false

                        if (
                            $sftpFilesInUploadFolder.Name -contains $result.FileName
                        ) {
                            $isDuplicateFileInSftpDestinationFolder = $true
                        }
                        #endregion

                        #region Test duplicate file
                        $duplicateFileInDestinationFolder = $localFilesInDestinationFolder.where(
                            { $_.Name -eq $result.FileName }
                        )

                        if (-not $OverwriteFile) {
                            $duplicateFileInLocalTempFolder = $localFilesInTempDownloadFolder.where(
                                { $_.Name -eq $result.FileName }
                            )

                            if ($duplicateFileInDestinationFolder) {
                                Save-ErrorMessageHC "Duplicate file in the destination folder '$($path.Destination)', use OverwriteFile if desired"

                                continue
                            }
    
                            if ($duplicateFileInLocalTempFolder) {
                                Save-ErrorMessageHC "Duplicate file in the local temp folder '$($tempFolder.local)', most likely due to the file being in use in the destination folder during the previous run, use OverwriteFile if desired"

                                continue
                            }
                        }
                        #endregion
                        
                        $tempFile = @{
                            UploadFileName = $fileToUpload.Name + $PartialFileExtension.Upload
                        }
                        $tempFile.UploadFilePath = Join-Path $result.Source $tempFile.UploadFileName

                        #region Duplicate file on SFTP server
                        if (
                            $sftpFile = $sftpFiles.where(
                                { $_.Name -eq $fileToUpload.Name }, 'First'
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

                                        Save-ActionMessageHC 'Removed duplicate file from SFTP server'
                                    }          
                                }
                                catch {
                                    Save-ErrorMessageHC "Failed removing duplicate file from the SFTP server after multiple attempts within $($RetryCountOnLockedFiles * $RetryWaitSeconds) seconds (file in use): $errorMessage"

                                    $Error.RemoveAt(0)

                                    continue
                                }
                            }
                            else {
                                Save-ErrorMessageHC 'Duplicate file on SFTP server, use Option.OverwriteFile if desired'

                                $Error.RemoveAt(0)

                                continue
                            }
                        }
                        #endregion

                        #region Upload temp file to SFTP server
                        try {
                            $params = @{
                                Path        = $tempFile.UploadFilePath
                                Destination = $SftpPath
                                Force       = $true
                            }

                            Write-Verbose 'Upload temp file'

                            Start-RetryActionHC -ScriptBlock {
                                Set-SFTPItem @sessionParams @params
                            }
                        }
                        catch {
                            $errorMessage = $_

                            if ($_ -like '*Failure*') {
                                $errorMessage = "Most like likely the destination file '$($params.Destination)/$($result.FileName)' is in use by another process: $_"
                            }

                            Save-ErrorMessageHC "Failed to upload file '$($params.Path)': $errorMessage"

                            $Error.RemoveAt(0)

                            continue
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
                            Save-ErrorMessageHC "Failed to rename the file on the SFTP server from '$($tempFile.UploadFileName)' to '$($result.FileName)': $_"
                       
                            $Error.RemoveAt(0)

                            continue
                        }
                        #endregion

                        #region Remove local temp file
                        try {
                            Write-Verbose 'Remove local temp file'

                            $tempFile.UploadFilePath | Remove-Item -Force
                        }
                        catch {
                            Save-ErrorMessageHC "Failed to remove the local temp file '$($tempFile.UploadFilePath)': $_"
                            
                            $Error.RemoveAt(0)

                            continue
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
                                Write-Verbose "Rename temp file '$($tempFile.UploadFilePath)' back to its original name '$($fileToUpload.Name)'"

                                $tempFile.UploadFilePath |
                                    Rename-Item -NewName $fileToUpload.Name
                            }
                            catch {
                                [PSCustomObject]@{
                                    DateTime    = Get-Date
                                    Source      = $result.Source
                                    Destination = $result.Destination
                                    FileName    = $tempFile.Name
                                    FileLength  = $result.Length
                                    Actions     = @()
                                    Errors      = @("Failed to rename temp file '$($tempFile.UploadFilePath)' back to its original name '$($fileToUpload.Name)': $_")
                                }

                                $Error.RemoveAt(0)
                            }
                        }
                        #endregion

                        Save-ErrorMessageHC $_
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
