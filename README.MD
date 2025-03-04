# SFTP File Transfer Script

This script facilitates automated file transfers between a local file system and an SFTP server, supporting both downloads and uploads. It's designed for scheduled execution, ensuring reliable file synchronization.

## Features

* **SFTP Download:** Downloads files from an SFTP server to a local directory.
* **SFTP Upload:** Uploads files from a local directory to an SFTP server.
* **Robust Error Handling:** Manages common issues like interrupted transfers and file-in-use scenarios.
* **Detailed Logging:** Logs all actions to an Excel sheet and sends a summary email.
* **Configuration via JSON:** Uses a JSON input file for easy configuration.
* **Scheduled Task Friendly:** Designed for automated execution.

## Getting Started

1.  **Configuration:**
    * Create a configuration file based on the provided `Example.json`. This file defines SFTP connection details, source and destination paths, and logging settings.
    * Refer to the inline help in the script (`Move file over SFTP.ps1`) for detailed explanations of each configuration parameter.
2.  **Dependencies:**
    * Install the `Posh-SSH` module: `Install-Module -Name Posh-SSH`.
    * Download any other required modules from the repository linked in the script's `#Requires` section.
3.  **Execution:**
    * Run the script (`Move file over SFTP.ps1`) with the path to your configuration file as an argument.
    * Schedule the script using Scheduled Tasks for automated execution.

## Workflow

### Download

1.  **SFTP Stage:**
    * Moves the file from the SFTP source folder to an SFTP temporary folder.
2.  **Local Stage:**
    * Downloads the file from the SFTP temporary folder to a local temporary folder.
    * Moves the file from the local temporary folder to the local destination folder.

### Upload

1.  **Local Stage:**
    * Moves the file from the local source folder to a local temporary folder.
2.  **SFTP Stage:**
    * Uploads the file from the local temporary folder to an SFTP temporary folder.
    * Moves the file from the SFTP temporary folder to the SFTP destination folder.
    * Removes the local temporary file.

## Error Handling

### Interrupted Transfers

* **Download:** The incomplete local temporary file is removed. The SFTP temporary file remains and will be re-downloaded on the next run.
* **Upload:** The incomplete SFTP temporary file will be deleted and the local temporary file will be re-uploaded on the next run.

### File in Use

* **Source (Local/SFTP):** The script retries moving the file for 12 seconds. If it fails, the error "file in use" is logged, and the file is skipped. It will be retried on the next run.
* **Destination (Local):** The file remains in the local temporary folder and will be retried on the next run.
* **Destination (SFTP):** The SFTP temporary file is removed and another upload is initiated. The process repeats until the file is successfully moved to the destination.

### Duplicate in Destination

* The script logs when a duplicate file exists in the destination folder.

## Logging and Reporting

* **Excel Logging:** All file transfer actions, including timestamps, source and destination paths, and status, are recorded in an Excel log file.
* **Email Summary:** A summary email is sent, containing tables of source and destination paths, action counts, and error counts.
* Logging configurations can be set in the input JSON file.

## Requirements

* PowerShell
* [Posh-SSH](https://github.com/darkoperator/Posh-SSH) module (`Install-Module -Name Posh-SSH`)
* Other modules as specified in the script's `#Requires` section (available in the linked repository).
* A configured SFTP server.

## Best Practices

* Thoroughly review and customize the [Example.json](Example.json) file to match your environment.
* Consult the inline help in [Move file over SFTP.ps1](Move%20file%20over%20SFTP.ps1) for detailed parameter explanations.
* Test the script in a non-production environment before scheduling it for automated execution.
* Monitor the log files and email summaries to ensure successful file transfers.