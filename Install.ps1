[CmdletBinding()]
param(
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Show-InstallerMessage {
    param(
        [string]$Message,
        [string]$Kind = 'Information'
    )

    if ($Quiet) {
        return
    }

    Add-Type -AssemblyName System.Windows.Forms
    $icon = [System.Windows.Forms.MessageBoxIcon]::$Kind
    [System.Windows.Forms.MessageBox]::Show(
        $Message,
        'CS Study Rotation Installer',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        $icon
    ) | Out-Null
}

try {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'CS Study Rotation can only be installed on Windows.'
    }

    $projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    $appSource = Join-Path $projectRoot 'app'
    $studySource = Join-Path $projectRoot 'study-files'

    if (-not (Test-Path -LiteralPath (Join-Path $appSource 'StudyRotation.ps1') -PathType Leaf)) {
        throw "App source files were not found in: $appSource"
    }

    $studyFiles = @(Get-ChildItem -LiteralPath $studySource -Filter '*.txt' -File)
    if ($studyFiles.Count -lt 5 -or $studyFiles.Count -gt 10) {
        throw "Expected 5 to 10 study files, but found $($studyFiles.Count)."
    }

    $desktop = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
    $appDestination = Join-Path $desktop 'CS Study Rotation App'
    $studyDestination = Join-Path $desktop 'CS Study Files'

    New-Item -ItemType Directory -Path $appDestination -Force | Out-Null
    New-Item -ItemType Directory -Path $studyDestination -Force | Out-Null

    # Copy known files only. Extra notes added by the user are never removed.
    Get-ChildItem -LiteralPath $appSource -File | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $appDestination -Force
    }
    $studyFiles | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $studyDestination -Force
    }

    Get-ChildItem -LiteralPath $appDestination -File | Unblock-File -ErrorAction SilentlyContinue

    $installedApp = Join-Path $appDestination 'StudyRotation.ps1'
    $installedNotes = @(Get-ChildItem -LiteralPath $studyDestination -Filter '*.txt' -File)
    if (-not (Test-Path -LiteralPath $installedApp -PathType Leaf) -or $installedNotes.Count -lt 5) {
        throw 'Installation verification failed.'
    }

    Show-InstallerMessage (
        "Installation complete.`n`n" +
        "Start: $appDestination\Start CS Study Rotation.cmd`n" +
        "Stop:  $appDestination\Stop CS Study Rotation.cmd`n`n" +
        "Study files: $studyDestination"
    )

    Write-Output "Installed app: $appDestination"
    Write-Output "Installed $($installedNotes.Count) study files: $studyDestination"
}
catch {
    Show-InstallerMessage $_.Exception.Message 'Error'
    Write-Error $_.Exception.Message
    exit 1
}
