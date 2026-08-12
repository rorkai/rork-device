[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Binary,

    [Parameter(Mandatory = $true)]
    [string]$WorkingDirectory,

    [int]$TimeoutSeconds = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$binaryPath = (Resolve-Path $Binary).Path
$probeDirectory = Join-Path $WorkingDirectory "static-runtime-probe"
if (Test-Path $probeDirectory) {
    Remove-Item $probeDirectory -Recurse -Force
}
New-Item -ItemType Directory -Path $probeDirectory -Force | Out-Null

$standardOutput = Join-Path $probeDirectory "stdout.log"
$standardError = Join-Path $probeDirectory "stderr.log"
$identityPath = Join-Path $probeDirectory "identity\selfIdentity.plist"
$arguments = @(
    "tunnel",
    "start",
    "--udid=ci-missing-device",
    "--identity=$identityPath",
    "--reconnect"
)

$process = Start-Process `
    -FilePath $binaryPath `
    -ArgumentList $arguments `
    -WorkingDirectory $probeDirectory `
    -RedirectStandardOutput $standardOutput `
    -RedirectStandardError $standardError `
    -PassThru

try {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $process.Refresh()
        if ($process.HasExited) {
            $process.WaitForExit()
            $exitCode = if ($null -eq $process.ExitCode) {
                "unavailable"
            } else {
                $process.ExitCode
            }
            $stdout = if (Test-Path $standardOutput) {
                Get-Content $standardOutput -Raw
            } else {
                ""
            }
            $stderr = if (Test-Path $standardError) {
                Get-Content $standardError -Raw
            } else {
                ""
            }
            throw "The packaged executable exited before reconnect attempt 2 with code $exitCode.`nstdout:`n$stdout`nstderr:`n$stderr"
        }

        if (Test-Path $standardOutput) {
            foreach ($line in Get-Content $standardOutput) {
                try {
                    $event = $line | ConvertFrom-Json -ErrorAction Stop
                } catch {
                    continue
                }
                if (
                    $event.event -eq "re-establishing" -and
                    $event.attempt -eq 2
                ) {
                    Write-Output "The packaged executable survived through reconnect attempt 2."
                    return
                }
            }
        }

        Start-Sleep -Milliseconds 200
    }

    throw "The packaged executable did not reach reconnect attempt 2 within $TimeoutSeconds seconds."
} finally {
    $process.Refresh()
    if (-not $process.HasExited) {
        Stop-Process -Id $process.Id -Force
        $process.WaitForExit()
    }
}
