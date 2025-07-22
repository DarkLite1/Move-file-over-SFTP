# PowerShell SFTP Transfer Script

A robust PowerShell script for automating SFTP file transfers (downloading and uploading), configured via a simple JSON input file. It supports parallel actions, comprehensive logging, email notifications, and flexible file matching with regular expressions.

## 🌟 Features

* **Configurable Transfers**: Define multiple SFTP tasks and actions in a single JSON configuration file.
* **Parallel Processing**: Execute multiple SFTP actions concurrently within a task for improved performance.
* **Secure Authentication**: Supports username/password or SSH private key file authentication for SFTP connections.
* **File Overwrite Control**: Option to prevent or allow overwriting of existing files at the destination.
* **Zero-Size File Exclusion**: Prevent the transfer of empty (0-byte) files.
* **Regex-Based File Filtering**: Precisely control which files are transferred using regular expressions.
* **Comprehensive Logging**: Configurable logging to file (CSV, JSON, TXT, XLSX) and Windows Event Log.
* **Email Notifications**: Send detailed email summaries or error alerts after script execution.
* **Remote Execution**: Ability to run SFTP commands on remote machines using PowerShell remoting.
* **Retry Mechanism**: Built-in retries for transient issues, including file locks, ensuring robust transfers.

## 🚀 Getting Started

### Prerequisites

* **PowerShell 7.x or later**: This script is built for modern PowerShell.
* **Posh-SSH Module**: Install this module on the computer where the SFTP commands will be executed (local or remote).
    ```powershell
    Install-Module -Name 'Posh-SSH' -Scope 'AllUsers'
    ```
* **Emailing Prerequisites (Optional)**: If you plan to use email notifications, install the `MailKit` and `MimeKit` NuGet packages.
    ```powershell
    Install-Package -Name 'MailKit' -Source 'https://www.nuget.org/api/v2' -Scope 'AllUsers' -SkipDependencies
    Install-Package -Name 'MimeKit' -Source 'https://www.nuget.org/api/v2' -Scope 'AllUsers' -SkipDependencies
    ```
* **Excel Logging Prerequisites (Optional)**: If you plan to log to `.xlsx` files, install the `ImportExcel` PowerShell module.
    ```powershell
    Install-Module -Name 'ImportExcel' -Scope 'AllUsers'
    ```

### Installation

1.  Clone this repository to your local machine:
    ```bash
    git clone https://github.com/DarkLite1/Move-file-over-SFTP.git
    cd Move-file-over-SFTP
    ```
2.  Review `Example.json` to understand the configuration options.
3.  Create your own configuration file (e.g., `MyConfig.json`) based on `Example.json`.

## 📝 Usage

Execute the script from PowerShell, providing the path to your configuration JSON file.

```powershell
& '.\Move file over SFTP.ps1' -ConfigurationJsonFile '.\MyConfig.json'
```

### Scheduled Task Example ⏱️
For automated, recurring executions (e.g., via Windows Task Scheduler), you'll typically invoke the script using `pwsh.exe -Command`. This allows you to pass parameters directly.

**The `-ReportOnly` switch is especially useful for scheduled tasks.** If your script runs frequently (e.g., every 5 minutes) with email notifications set to 'OnError', you can use `-ReportOnly` in a separate, less frequent task (e.g., once a day). This allows you to generate a comprehensive summary email of all actions from the exported Excel log file, even if no errors occurred during the frequent runs.

- Program: `pwsh.exe`
- Arguments:

```
-Command  "& 'C:\Move-file-over-SFTP\Move file over SFTP.ps1' -ConfigurationJsonFile 'C:\Reports.json' -ReportOnly; exit $LASTEXITCODE"
```

## 🙏 Acknowledgements
This script relies on the excellent work of others in the PowerShell and .NET communities. We extend our sincere gratitude to the developers and maintainers of the following projects:

- [Posh-SSH](https://github.com/darkoperator/Posh-SSH): For providing robust SSH and SFTP capabilities in PowerShell.
- [MailKit](https://github.com/jstedfast/MailKit) & [MimeKit](https://mimekit.net/): For powerful and flexible email sending functionality.
- [ImportExcel](https://github.com/dfinke/ImportExcel): For seamless importing and exporting of data to Excel files in PowerShell.

Their contributions make this script possible!

## 🤝 Contributing
Feel free to open issues or submit pull requests if you have suggestions for improvements or bug fixes.

## 📞 Support
If you encounter any issues or have questions, please open an issue on the GitHub repository.

## 📜 License

This software is provided for your use, free of charge, for both private and professional purposes.

**NO GUARANTEES ARE GIVEN:** This software is provided "as is," without any warranty of any kind, express or implied, including but not limited to the warranties of merchantability, fitness for a particular purpose, and non-infringement.

**YOUR RESPONSIBILITY:** In no event shall the author be liable for any claim, damages, or other liability, whether in an action of contract, tort, or otherwise, arising from, out of, or in connection with the software or the use or other dealings in the software. You are solely responsible for the code you deploy and its consequences.