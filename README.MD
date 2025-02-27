# Description

Download files from an SFTP server or upload files to an SFTP server.

Simply create an input file based on the [example.JSON file](Example.json) and create a scheduled task to launch the script in an automated way.

# Download

## Steps
1. Move the file from the source folder to a temporary folder on the SFTP server
2. Download the file from the SFTP temporary folder to the local temporary folder
3. Move the file from the local temporary folder to the final destination folder

## Special cases

### Interrupted download

When a file starts downloading and the connection is cut, there are 2 files:
- one file in the sftp temporary folder (complete moved file)
- one file in the local temporary folder (incomplete downloaded file)

The file in the SFTP temporary folder remains untouched and the incomplete
downloaded local temporary file is removed. On the next run of the script, the previously moved SFTP temporary file will be downloaded again.

Any new file in the SFTP source folder with the same name will be ignored and only processed during the next run.

### Cannot overwrite destination file

When a file is downloaded to the local temporary folder, it can happen
that the destination file is in use by another process and the file cannot
be overwritten.

The script will leave the file in the local temporary folder an tries to move
it to the destination folder on the next run.

Any new file in the SFTP source folder with the same name will be ignored and only processed during the next run.

# Best practices

- Read the [help section in the script](Move%20file%20over%20SFTP.ps1) for an explanation on the input file parameters.

# Requirements

- Download the required modules from the [repository](https://github.com/DarkLite1?tab=repositories) (See the `#Requires` section at the top of [the script](Move%20file%20over%20SFTP.ps1))
- The machine running the SFTP client needs to have the module [Posh-SSH](https://github.com/darkoperator/Posh-SSH) installed
