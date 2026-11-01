[CmdletBinding()]
param(
    [ValidateSet('Start', 'Run', 'Stop', 'Status')]
    [string]$Action = 'Start',

    [string]$StudyFolder = '',
    [string]$StateDirectory = '',

    [ValidateRange(1, 86400)]
    [int]$MinDisplaySeconds = 300,

    [ValidateRange(1, 86400)]
    [int]$MaxDisplaySeconds = 600,

    [ValidateRange(1, 3600)]
    [int]$MinSwitchSeconds = 30,

    [ValidateRange(1, 3600)]
    [int]$MaxSwitchSeconds = 40,

    [ValidateRange(0, 10000)]
    [int]$MaxFiles = 0,

    [switch]$DisableWindowSwitching,
    [switch]$DryRun,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ProductName = 'CS Study Rotation'
$script:NativeApiLoaded = $false

function Get-DefaultDesktopPath {
    return [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
}

if ([string]::IsNullOrWhiteSpace($StudyFolder)) {
    $StudyFolder = Join-Path (Get-DefaultDesktopPath) 'CS Study Files'
}

if ([string]::IsNullOrWhiteSpace($StateDirectory)) {
    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    $StateDirectory = Join-Path $localAppData 'CSStudyRotation'
}

$script:StudyFolder = [IO.Path]::GetFullPath($StudyFolder)
$script:StateDirectory = [IO.Path]::GetFullPath($StateDirectory)
$script:PidPath = Join-Path $script:StateDirectory 'runner.pid'
$script:HeartbeatPath = Join-Path $script:StateDirectory 'heartbeat.txt'
$script:StopPath = Join-Path $script:StateDirectory 'stop.request'
$script:LogPath = Join-Path $script:StateDirectory 'activity.log'

function Initialize-StateDirectory {
    if (-not (Test-Path -LiteralPath $script:StateDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $script:StateDirectory -Force | Out-Null
    }

    if ((Test-Path -LiteralPath $script:LogPath -PathType Leaf) -and
        (Get-Item -LiteralPath $script:LogPath).Length -gt 2MB) {
        $oldLog = Join-Path $script:StateDirectory 'activity.previous.log'
        Move-Item -LiteralPath $script:LogPath -Destination $oldLog -Force
    }
}

function Write-ActivityLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    Initialize-StateDirectory
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
}

function Show-AppMessage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet('Information', 'Warning', 'Error')]
        [string]$Kind = 'Information'
    )

    if ($Quiet) {
        return
    }

    Add-Type -AssemblyName System.Windows.Forms
    $icon = [System.Windows.Forms.MessageBoxIcon]::$Kind
    [System.Windows.Forms.MessageBox]::Show(
        $Message,
        $script:ProductName,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        $icon
    ) | Out-Null
}

function Test-RunnerActive {
    if (-not (Test-Path -LiteralPath $script:PidPath -PathType Leaf)) {
        return $false
    }

    try {
        $runnerId = [int](Get-Content -LiteralPath $script:PidPath -Raw).Trim()
        $process = Get-Process -Id $runnerId -ErrorAction Stop

        if (-not (Test-Path -LiteralPath $script:HeartbeatPath -PathType Leaf)) {
            return $false
        }

        $heartbeatAge = (Get-Date) - (Get-Item -LiteralPath $script:HeartbeatPath).LastWriteTime
        return ($null -ne $process -and $heartbeatAge.TotalSeconds -lt 10)
    }
    catch {
        return $false
    }
}

function Update-Heartbeat {
    Set-Content -LiteralPath $script:HeartbeatPath -Value ([DateTime]::UtcNow.ToString('O')) -Encoding ASCII
}

function Remove-StaleState {
    Remove-Item -LiteralPath $script:PidPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:HeartbeatPath -Force -ErrorAction SilentlyContinue
}

function Assert-Settings {
    if ($MinDisplaySeconds -gt $MaxDisplaySeconds) {
        throw 'MinDisplaySeconds cannot be greater than MaxDisplaySeconds.'
    }
    if ($MinSwitchSeconds -gt $MaxSwitchSeconds) {
        throw 'MinSwitchSeconds cannot be greater than MaxSwitchSeconds.'
    }
    if (-not (Test-Path -LiteralPath $script:StudyFolder -PathType Container)) {
        throw "Study folder was not found: $($script:StudyFolder)"
    }
    if (@(Get-ChildItem -LiteralPath $script:StudyFolder -Filter '*.txt' -File).Count -eq 0) {
        throw "No .txt files were found in: $($script:StudyFolder)"
    }
}

function Get-RandomInclusive {
    param(
        [int]$Minimum,
        [int]$Maximum
    )

    if ($Minimum -eq $Maximum) {
        return $Minimum
    }
    return Get-Random -Minimum $Minimum -Maximum ($Maximum + 1)
}

function Get-StateMutexName {
    $bytes = [Text.Encoding]::UTF8.GetBytes($script:StateDirectory.ToLowerInvariant())
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').Substring(0, 16)
    }
    finally {
        $sha.Dispose()
    }
    return "Local\CSStudyRotation_$hash"
}

function Initialize-NativeApi {
    if ($script:NativeApiLoaded) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class StudyRotationNative
{
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    private const uint WM_CLOSE = 0x0010;
    private const byte VK_MENU = 0x12;
    private const byte VK_TAB = 0x09;
    private const uint KEYEVENTF_KEYUP = 0x0002;

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int maxCount);

    [DllImport("user32.dll")]
    private static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hWnd, int command);

    [DllImport("user32.dll")]
    private static extern bool PostMessage(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern void keybd_event(byte virtualKey, byte scanCode, uint flags, UIntPtr extraInfo);

    public static IntPtr FindVisibleWindow(string titleFragment)
    {
        IntPtr result = IntPtr.Zero;
        EnumWindows(delegate(IntPtr window, IntPtr parameter)
        {
            if (!IsWindowVisible(window)) return true;
            int length = GetWindowTextLength(window);
            if (length == 0) return true;

            StringBuilder title = new StringBuilder(length + 1);
            GetWindowText(window, title, title.Capacity);
            if (title.ToString().IndexOf(titleFragment, StringComparison.OrdinalIgnoreCase) >= 0 &&
                title.ToString().IndexOf("Notepad", StringComparison.OrdinalIgnoreCase) >= 0)
            {
                result = window;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return result;
    }

    public static void ActivateWindow(IntPtr window)
    {
        if (window == IntPtr.Zero) return;
        ShowWindow(window, 9); // SW_RESTORE
        SetForegroundWindow(window);
    }

    public static bool CloseWindow(IntPtr window)
    {
        return window != IntPtr.Zero && PostMessage(window, WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
    }

    public static void SendAltTab()
    {
        keybd_event(VK_MENU, 0, 0, UIntPtr.Zero);
        keybd_event(VK_TAB, 0, 0, UIntPtr.Zero);
        keybd_event(VK_TAB, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
        keybd_event(VK_MENU, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
    }
}
'@

    $script:NativeApiLoaded = $true
}

function Open-StudyFile {
    param(
        [Parameter(Mandatory = $true)]
        [IO.FileInfo]$File
    )

    Write-ActivityLog "Opening '$($File.Name)'."
    if ($DryRun) {
        return [pscustomobject]@{
            Process = $null
            Handle = [IntPtr]::Zero
            File = $File
        }
    }

    Initialize-NativeApi
    $quotedPath = '"{0}"' -f $File.FullName.Replace('"', '\"')
    $process = Start-Process -FilePath 'notepad.exe' -ArgumentList $quotedPath -PassThru
    $handle = [IntPtr]::Zero
    $deadline = (Get-Date).AddSeconds(12)

    while ((Get-Date) -lt $deadline -and $handle -eq [IntPtr]::Zero) {
        try {
            if (-not $process.HasExited) {
                $process.Refresh()
                $handle = $process.MainWindowHandle
            }
        }
        catch {
            # Modern Notepad can hand the file to an existing app process.
        }

        if ($handle -eq [IntPtr]::Zero) {
            $handle = [StudyRotationNative]::FindVisibleWindow($File.Name)
        }
        if ($handle -eq [IntPtr]::Zero) {
            Start-Sleep -Milliseconds 200
        }
    }

    if ($handle -ne [IntPtr]::Zero) {
        [StudyRotationNative]::ActivateWindow($handle)
    }
    else {
        Write-ActivityLog "Could not identify the Notepad window for '$($File.Name)'; it was still opened." 'WARN'
    }

    return [pscustomobject]@{
        Process = $process
        Handle = $handle
        File = $File
    }
}

function Close-StudyFile {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Session
    )

    Write-ActivityLog "Closing '$($Session.File.Name)'."
    if ($DryRun) {
        return
    }

    Initialize-NativeApi
    $closeRequested = $false
    if ($Session.Handle -ne [IntPtr]::Zero -and [StudyRotationNative]::IsWindow($Session.Handle)) {
        $closeRequested = [StudyRotationNative]::CloseWindow($Session.Handle)
    }

    if (-not $closeRequested -and $null -ne $Session.Process) {
        try {
            if (-not $Session.Process.HasExited) {
                $Session.Process.Refresh()
                $closeRequested = $Session.Process.CloseMainWindow()
            }
        }
        catch {
            # The launcher process may already have handed off to modern Notepad.
        }
    }

    if (-not $closeRequested) {
        Write-ActivityLog "Could not send a close request to '$($Session.File.Name)'." 'WARN'
        return
    }

    $deadline = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $deadline) {
        if ($Session.Handle -eq [IntPtr]::Zero -or -not [StudyRotationNative]::IsWindow($Session.Handle)) {
            return
        }
        Start-Sleep -Milliseconds 100
    }

    Write-ActivityLog "The Notepad window for '$($Session.File.Name)' did not close within five seconds; it was not force-killed." 'WARN'
}

function Invoke-WindowSwitch {
    if ($DisableWindowSwitching) {
        Write-ActivityLog 'Window switch skipped because it is disabled.'
        return
    }
    if ($DryRun) {
        Write-ActivityLog 'Dry run: Alt+Tab window switch.'
        return
    }

    Initialize-NativeApi
    [StudyRotationNative]::SendAltTab()
    Write-ActivityLog 'Sent Alt+Tab window switch.'
}

function Start-Runner {
    Initialize-StateDirectory
    Assert-Settings

    if (Test-RunnerActive) {
        Show-AppMessage 'The study rotation is already running.' 'Information'
        return
    }

    Remove-StaleState
    Remove-Item -LiteralPath $script:StopPath -Force -ErrorAction SilentlyContinue

    $powerShellExe = Join-Path $PSHOME 'powershell.exe'
    $arguments = @(
        '-NoProfile'
        '-ExecutionPolicy Bypass'
        '-WindowStyle Hidden'
        ('-File "{0}"' -f $PSCommandPath)
        '-Action Run'
        ('-StudyFolder "{0}"' -f $script:StudyFolder)
        ('-StateDirectory "{0}"' -f $script:StateDirectory)
        "-MinDisplaySeconds $MinDisplaySeconds"
        "-MaxDisplaySeconds $MaxDisplaySeconds"
        "-MinSwitchSeconds $MinSwitchSeconds"
        "-MaxSwitchSeconds $MaxSwitchSeconds"
        "-MaxFiles $MaxFiles"
    )
    if ($DisableWindowSwitching) { $arguments += '-DisableWindowSwitching' }
    if ($DryRun) { $arguments += '-DryRun' }
    if ($Quiet) { $arguments += '-Quiet' }

    $runner = Start-Process -FilePath $powerShellExe -ArgumentList ($arguments -join ' ') -WindowStyle Hidden -PassThru
    $deadline = (Get-Date).AddSeconds(6)
    while ((Get-Date) -lt $deadline) {
        if (Test-RunnerActive) {
            Show-AppMessage "Study rotation started.`n`nFiles: $($script:StudyFolder)`nUse the Stop launcher to end it." 'Information'
            return
        }
        if ($runner.HasExited) {
            break
        }
        Start-Sleep -Milliseconds 250
    }

    Show-AppMessage "The study rotation could not start. Check the log:`n$($script:LogPath)" 'Error'
    throw 'Runner failed to start.'
}

function Stop-Runner {
    Initialize-StateDirectory
    if (-not (Test-RunnerActive)) {
        Remove-StaleState
        Remove-Item -LiteralPath $script:StopPath -Force -ErrorAction SilentlyContinue
        Show-AppMessage 'The study rotation is not running.' 'Information'
        return
    }

    Set-Content -LiteralPath $script:StopPath -Value ([DateTime]::UtcNow.ToString('O')) -Encoding ASCII
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-RunnerActive)) {
            Show-AppMessage 'The study rotation has stopped.' 'Information'
            return
        }
        Start-Sleep -Milliseconds 250
    }

    Show-AppMessage "A stop was requested, but the runner has not exited yet. Check:`n$($script:LogPath)" 'Warning'
}

function Show-RunnerStatus {
    if (Test-RunnerActive) {
        Show-AppMessage "The study rotation is running.`n`nFiles: $($script:StudyFolder)" 'Information'
    }
    else {
        Show-AppMessage 'The study rotation is not running.' 'Information'
    }
}

function Invoke-Rotation {
    Initialize-StateDirectory
    Assert-Settings

    $mutex = New-Object Threading.Mutex($false, (Get-StateMutexName))
    $ownsMutex = $false
    $currentSession = $null

    try {
        try {
            $ownsMutex = $mutex.WaitOne(0)
        }
        catch [Threading.AbandonedMutexException] {
            $ownsMutex = $true
        }

        if (-not $ownsMutex) {
            Write-ActivityLog 'A second runner tried to start and was rejected.' 'WARN'
            return
        }

        Set-Content -LiteralPath $script:PidPath -Value $PID -Encoding ASCII
        Update-Heartbeat
        Write-ActivityLog "Runner started. Study folder: '$($script:StudyFolder)'."

        $openedCount = 0
        :rotation while (-not (Test-Path -LiteralPath $script:StopPath -PathType Leaf)) {
            $files = @(Get-ChildItem -LiteralPath $script:StudyFolder -Filter '*.txt' -File)
            if ($files.Count -eq 0) {
                throw "No .txt files were found in: $($script:StudyFolder)"
            }
            $files = @(Get-Random -InputObject $files -Count $files.Count)

            foreach ($file in $files) {
                if (Test-Path -LiteralPath $script:StopPath -PathType Leaf) {
                    break rotation
                }
                if ($MaxFiles -gt 0 -and $openedCount -ge $MaxFiles) {
                    break rotation
                }

                $currentSession = Open-StudyFile -File $file
                $openedCount++
                $displaySeconds = Get-RandomInclusive -Minimum $MinDisplaySeconds -Maximum $MaxDisplaySeconds
                $nextSwitch = (Get-Date).AddSeconds(
                    (Get-RandomInclusive -Minimum $MinSwitchSeconds -Maximum $MaxSwitchSeconds)
                )
                $displayUntil = (Get-Date).AddSeconds($displaySeconds)
                Write-ActivityLog "Displaying '$($file.Name)' for $displaySeconds seconds."

                while ((Get-Date) -lt $displayUntil) {
                    Update-Heartbeat
                    if (Test-Path -LiteralPath $script:StopPath -PathType Leaf) {
                        break
                    }
                    if ((Get-Date) -ge $nextSwitch) {
                        Invoke-WindowSwitch
                        $nextSwitch = (Get-Date).AddSeconds(
                            (Get-RandomInclusive -Minimum $MinSwitchSeconds -Maximum $MaxSwitchSeconds)
                        )
                    }
                    Start-Sleep -Milliseconds 500
                }

                Close-StudyFile -Session $currentSession
                $currentSession = $null

                if (Test-Path -LiteralPath $script:StopPath -PathType Leaf) {
                    break rotation
                }
            }
        }
    }
    finally {
        if ($null -ne $currentSession) {
            try {
                Close-StudyFile -Session $currentSession
            }
            catch {
                Write-ActivityLog "Cleanup could not close the current study file: $($_.Exception.Message)" 'ERROR'
            }
        }

        Write-ActivityLog 'Runner stopped.'
        Remove-StaleState
        Remove-Item -LiteralPath $script:StopPath -Force -ErrorAction SilentlyContinue
        if ($ownsMutex) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}

try {
    switch ($Action) {
        'Start'  { Start-Runner }
        'Run'    { Invoke-Rotation }
        'Stop'   { Stop-Runner }
        'Status' { Show-RunnerStatus }
    }
}
catch {
    try {
        Write-ActivityLog $_.Exception.Message 'ERROR'
    }
    catch {
        # Preserve the original failure if logging is unavailable.
    }

    if ($Action -ne 'Run') {
        Show-AppMessage $_.Exception.Message 'Error'
    }
    Write-Error $_.Exception.Message
    exit 1
}
