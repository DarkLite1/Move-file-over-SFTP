### Description

Download files from an SFTP server or upload files to an SFTP server.

Simply create an input file for this script based on the [example.JSON](Example.json) file. This script dan be executed in an automated way by using Scheduled Tasks.

### Logging

All actions performed by the script are logged in an Excel sheet. Each row represents a single file with all its details (uploaded, downloaded, duplicate in destination folder, ...). An e-mail is sent with a summary table of all source and destination paths combined with an action count and an error count.

Configure the logging settings in the input file based on the [Example.json](Example.json) file.

# Download

Download a file from the source folder on the SFTP server to the destination folder on the local file system.

### Steps
1. Move the file from the source folder to a temporary folder on the SFTP server
2. Download the file from the SFTP temporary folder to the local temporary folder
3. Move the file from the local temporary folder to the final destination folder

## Special cases

### Interrupted download

When a file starts downloading and the connection is cut, there are 2 files:
- one file in the SFTP temporary folder (complete moved file)
- one file in the local temporary folder (incomplete downloaded file)

The file in the SFTP temporary folder remains untouched and the incomplete
downloaded local temporary file is removed. On the next run of the script, the previously moved SFTP temporary file will be downloaded again.

Any new file in the SFTP source folder with the same name will be ignored and only processed during the next run.

### Source file in use

A file is in use by another process when it cannot be moved from the SFTP source folder to the SFTP temporary folder.

The script will retry to move the file for 12 seconds. When moving the file ultimately fails, it will simply be reported with the error "file in use".

Further processing for this file is ignored. On the next run, the script will try to download the file again.

### Destination file in use

A file is in use by another process when it cannot be overwritten in the destination folder.

The script will leave the file in the local temporary folder an tries to move
it to the destination folder on the next run.

Any new file in the SFTP source folder with the same name will be ignored and only downloaded during the next run.

# Upload

Upload a file from the source folder to the destination folder on the SFTP server. 

A connection to the SFTP server is only made when there are files in the source folder or in the local temporary folder. This is done to ensure that the SFTP server is not spammed with connection requests when there is nothing to upload.

### Steps
1. Move the file from the source folder to the local temporary folder
2. Upload the file from the local temporary folder to the SFTP temporary folder
3. Move the file from the SFTP temporary folder to the SFTP destination folder
4. Remove the file in the local temporary folder

## Special cases

### Interrupted upload

When a file starts uploading and the connection is cut, there are 2 files:
- one file in the local temporary folder (complete moved file)
- one file in the SFTP temporary folder (incomplete uploaded file)

The error will be reported and in the next run the the file in the SFTP temporary folder will be removed and the file in the local temporary folder will be uploaded again.

Any new file in the source folder with the same name will be ignored and only uploaded during the next run.

### Source file in use

A file is in use by another process when it cannot be moved from the source folder to the temporary folder on the file system.

The script will retry to move the file for 12 seconds. When moving the file ultimately fails, it will simply be reported with the error "file in use".

Further processing for this file is ignored. On the next run, the script will try to upload the file again.

### Destination file in use

A file is in use by another process when it cannot be overwritten in the SFTP destination folder. At this point there are 3 files:
- one file in the local temporary folder (complete moved file)
- one file in the SFTP temporary folder (uploaded file)
- one file in the SFTP destination folder (file to be replaced, file in use)

On the next run of the script, the file in the SFTP temporary folder will be removed and another upload will be initiated. After the file is uploaded to the SFTP temporary folder, another move to the SFTP destination folder will be attempted. 

The steps above repeat until the file is successfully moved to the SFTP destination folder in one of the script runs.

Any new file in the source folder with the same name will be ignored and only uploaded during the next run.

# Best practices

- Read the [help section in the script](Move%20file%20over%20SFTP.ps1) for an explanation on the input file parameters.

# Requirements

- Download the required modules from the [repository](https://github.com/DarkLite1?tab=repositories) (See the `#Requires` section at the top of [the script](Move%20file%20over%20SFTP.ps1))
- The machine running the SFTP client needs to have the module [Posh-SSH](https://github.com/darkoperator/Posh-SSH) installed
