# CS Study Rotation for Windows

A small, user-controlled Windows utility that rotates through computer-science study notes in Notepad.

While enabled, it:

1. Selects a random `.txt` study file.
2. Opens the file in Notepad, maximizes it, and brings it to the screen.
3. Keeps it open for a random **5–10 minutes**.
4. Sends **Alt+Tab every 5–10 seconds**.
5. Closes only the Notepad window it opened, then selects another file.
6. Continues until the user runs the Stop launcher.

It does **not** start automatically with Windows. The user must explicitly start it, and can stop it at any time.

## Install

Requirements:

- Windows 10 or Windows 11
- Windows PowerShell 5.1 or newer (included with supported Windows versions)
- Notepad

Double-click **`Install.cmd`** in this project folder. The installer uses Windows' actual Desktop location, including a OneDrive-backed Desktop, and creates:

```text
Desktop\
├── CS Study Rotation App\
│   ├── Start CS Study Rotation.cmd
│   ├── Stop CS Study Rotation.cmd
│   ├── Check CS Study Rotation.cmd
│   └── StudyRotation.ps1
└── CS Study Files\
    ├── 00_README_CS_STUDY_GUIDE.txt
    ├── ...
    └── 09_CORE_CS_INTERVIEW_CHECKLIST.txt
```

The installer copies or updates the supplied files. It does not remove extra `.txt` notes you add to `CS Study Files`.

## Use

Open **`CS Study Rotation App`** on the Desktop and double-click:

- **`Start CS Study Rotation.cmd`** to enable the rotation.
- **`Stop CS Study Rotation.cmd`** to stop it and close its current note.
- **`Check CS Study Rotation.cmd`** to see whether it is running.

Only one rotation can run at a time. Starting it a second time shows an “already running” message.

> [!IMPORTANT]
> Alt+Tab changes the foreground window. Enable the app only when you want this behavior. The Stop launcher is checked at least twice per second, so it remains responsive even during a 10-minute display period.

## Study files

The installation includes 10 plain-text references:

- CS study workflow and complexity guide
- Binary search (Python)
- Merge sort (JavaScript)
- Breadth-first search (C++)
- Dijkstra's shortest path (Python)
- Union-find (Java)
- Topological sort (Python)
- LRU cache (Python)
- 0/1 knapsack (C++)
- Core CS interview checklist

You can edit these notes or add more `.txt` files. New text files are included the next time the app refreshes its randomized list.

## Safety and runtime data

- The runner tracks and closes its own Notepad window; it does not run `taskkill` or kill every Notepad process.
- If a normal window-close request fails, it records a warning rather than force-killing Notepad.
- Runtime PID, heartbeat, and logs are stored in `%LOCALAPPDATA%\CSStudyRotation`.
- The activity log rotates after 2 MB.

## Test

Run the automated smoke suite from Windows PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\SmokeTest.ps1
```

It checks PowerShell syntax, the study files, a shortened rotation, Alt+Tab scheduling, detached Start/Stop controls, and cleanup.

To also perform a short real Notepad open-and-close test:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\SmokeTest.ps1 -IncludeNotepad
```

The Notepad integration test disables Alt+Tab so it does not deliberately change the tester's foreground app.

## Uninstall

1. Run `Stop CS Study Rotation.cmd`.
2. Delete `Desktop\CS Study Rotation App`.
3. Optionally delete `Desktop\CS Study Files` and `%LOCALAPPDATA%\CSStudyRotation`.
