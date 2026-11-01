[CmdletBinding()]
param(
    [switch]$IncludeNotepad
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw "TEST FAILED: $Message"
    }
}

function Invoke-AppProcess {
    param(
        [string[]]$AppArguments
    )

    $powerShellExe = Join-Path $PSHOME 'powershell.exe'
    & $powerShellExe -NoProfile -ExecutionPolicy Bypass -File $script:AppScript @AppArguments
    Assert-True ($LASTEXITCODE -eq 0) "App command failed with exit code $LASTEXITCODE."
}

$projectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$script:AppScript = Join-Path $projectRoot 'app\StudyRotation.ps1'
$sourceStudyFolder = Join-Path $projectRoot 'study-files'
$tempRoot = Join-Path $projectRoot "tests\tmp\smoke-$PID"
$tempStudyFolder = Join-Path $tempRoot 'Study Files With Spaces'
$controllerState = Join-Path $tempRoot 'controller-state'

try {
    New-Item -ItemType Directory -Path $tempStudyFolder -Force | Out-Null

    Write-Output 'Checking project files...'
    Assert-True (Test-Path -LiteralPath $script:AppScript -PathType Leaf) 'StudyRotation.ps1 is missing.'
    foreach ($launcher in @('Start CS Study Rotation.cmd', 'Stop CS Study Rotation.cmd', 'Check CS Study Rotation.cmd')) {
        Assert-True (Test-Path -LiteralPath (Join-Path $projectRoot "app\$launcher") -PathType Leaf) "$launcher is missing."
    }

    $studyFiles = @(Get-ChildItem -LiteralPath $sourceStudyFolder -Filter '*.txt' -File)
    Assert-True ($studyFiles.Count -ge 5 -and $studyFiles.Count -le 10) 'Study file count must be between 5 and 10.'
    $studyFiles | Select-Object -First 2 | Copy-Item -Destination $tempStudyFolder

    $tokens = $null
    $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile(
        $script:AppScript,
        [ref]$tokens,
        [ref]$parseErrors
    ) | Out-Null
    Assert-True ($parseErrors.Count -eq 0) 'StudyRotation.ps1 has PowerShell parse errors.'

    Write-Output 'Running a short rotation in dry-run mode...'
    $directState = Join-Path $tempRoot 'direct-state'
    Invoke-AppProcess @(
        '-Action', 'Run',
        '-StudyFolder', $tempStudyFolder,
        '-StateDirectory', $directState,
        '-MinDisplaySeconds', '2',
        '-MaxDisplaySeconds', '2',
        '-MinSwitchSeconds', '1',
        '-MaxSwitchSeconds', '1',
        '-MaxFiles', '1',
        '-DryRun',
        '-Quiet'
    )

    $directLog = Get-Content -LiteralPath (Join-Path $directState 'activity.log') -Raw
    Assert-True ($directLog -match 'Runner started') 'Dry-run log has no start event.'
    Assert-True ($directLog -match 'Opening .*\.txt') 'Dry-run log has no open event.'
    Assert-True ($directLog -match 'Dry run: Alt\+Tab') 'Dry-run log has no Alt+Tab event.'
    Assert-True ($directLog -match 'Closing .*\.txt') 'Dry-run log has no close event.'
    Assert-True ($directLog -match 'Runner stopped') 'Dry-run log has no stop event.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $directState 'runner.pid'))) 'Runner PID was not cleaned up.'

    Write-Output 'Testing detached Start and Stop controls...'
    Invoke-AppProcess @(
        '-Action', 'Start',
        '-StudyFolder', $tempStudyFolder,
        '-StateDirectory', $controllerState,
        '-MinDisplaySeconds', '30',
        '-MaxDisplaySeconds', '30',
        '-MinSwitchSeconds', '5',
        '-MaxSwitchSeconds', '5',
        '-DryRun',
        '-Quiet'
    )
    Assert-True (Test-Path -LiteralPath (Join-Path $controllerState 'runner.pid') -PathType Leaf) 'Detached runner did not create a PID file.'
    Assert-True (Test-Path -LiteralPath (Join-Path $controllerState 'heartbeat.txt') -PathType Leaf) 'Detached runner did not create a heartbeat.'

    Invoke-AppProcess @(
        '-Action', 'Stop',
        '-StudyFolder', $tempStudyFolder,
        '-StateDirectory', $controllerState,
        '-Quiet'
    )
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $controllerState 'runner.pid'))) 'Detached runner did not stop cleanly.'

    if ($IncludeNotepad) {
        Write-Output 'Running the real Notepad open/close integration test...'
        $notepadState = Join-Path $tempRoot 'notepad-state'
        Invoke-AppProcess @(
            '-Action', 'Run',
            '-StudyFolder', $tempStudyFolder,
            '-StateDirectory', $notepadState,
            '-MinDisplaySeconds', '3',
            '-MaxDisplaySeconds', '3',
            '-MinSwitchSeconds', '1',
            '-MaxSwitchSeconds', '1',
            '-MaxFiles', '1',
            '-DisableWindowSwitching',
            '-Quiet'
        )

        $notepadLog = Get-Content -LiteralPath (Join-Path $notepadState 'activity.log') -Raw
        Assert-True ($notepadLog -match 'Opening .*\.txt') 'Notepad test has no open event.'
        Assert-True ($notepadLog -match 'Closing .*\.txt') 'Notepad test has no close event.'
        Assert-True ($notepadLog -notmatch '\[(WARN|ERROR)\]') 'Notepad integration logged a warning or error.'
    }

    Write-Output "All smoke tests passed. Study files checked: $($studyFiles.Count)."
}
finally {
    if (Test-Path -LiteralPath (Join-Path $controllerState 'runner.pid') -PathType Leaf) {
        try {
            Invoke-AppProcess @(
                '-Action', 'Stop',
                '-StudyFolder', $tempStudyFolder,
                '-StateDirectory', $controllerState,
                '-Quiet'
            )
        }
        catch {
            Write-Warning "Test cleanup could not stop the detached runner: $($_.Exception.Message)"
        }
    }

    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
