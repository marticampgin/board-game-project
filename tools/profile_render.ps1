param([string]$Godot = 'Godot_v4.7.2-stable_win64_console.exe')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$artifactDirectory = Join-Path $projectRoot 'artifacts'
New-Item -ItemType Directory -Path $artifactDirectory -Force | Out-Null
$outputLog = Join-Path $artifactDirectory 'presentation_profile.stdout.log'
$errorLog = Join-Path $artifactDirectory 'presentation_profile.stderr.log'
# A native offscreen window still renders through the actual GPU. Hide the
# console helper as well; do not disturb an interactive play session.
$arguments = @('--path', ('"' + $projectRoot + '"'), '--position', '-20000,-20000', '--resolution', '1920x1080', '--script', 'res://tests/presentation/profile_render.gd')
$process = Start-Process -FilePath $Godot -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $outputLog -RedirectStandardError $errorLog
# Keep the native handle open so Windows PowerShell can read ExitCode after the
# short-lived child exits (Refresh can otherwise discard that information).
$processHandle = $process.Handle
if (-not $process.WaitForExit(45000)) {
    $process.Kill()
    throw 'Native render profiling exceeded 45 seconds. See artifacts/presentation_profile.*.log.'
}
$exitCode = $process.ExitCode
$outputText = Get-Content -LiteralPath $outputLog -Raw
$errorText = Get-Content -LiteralPath $errorLog -Raw
Write-Output $outputText
if ($exitCode -ne 0 -or ($outputText + $errorText) -match '(SCRIPT ERROR:|\bERROR:)') {
    Write-Output $errorText
    throw 'Native render profile failed. Inspect the saved engine logs.'
}
$report = Get-Content -LiteralPath (Join-Path $artifactDirectory 'presentation_profile.json') -Raw | ConvertFrom-Json
if (-not $report.success) { throw 'The run produced no rendered GPU frames.' }
