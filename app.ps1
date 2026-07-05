<#
.SYNOPSIS
    Collect Windows artifacts defined in a YAML file (multidocument support).
.DESCRIPTION
    Uses powershell-yaml module to parse YAML documents (separated by ---),
    then collects registry keys/values, files, and executes commands.
.PARAMETER yamlPath
    Path to the YAML file with artifact definitions.
.EXAMPLE
    .\app.ps1 -yamlPath .\artifactWIN.yaml
.NOTES
    Requires PowerShell 5.1+ and internet access for module installation.
    Run as Administrator for full access.
#>

param(
    [string]$yamlPath = "windows.yaml"
)

if (-not (Test-Path $yamlPath)) {
    Write-Error "File '$yamlPath' not found."
    exit 1
}

# ---------- Ensure YAML module is available ----------
if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    Write-Host "Module 'powershell-yaml' not found. Installing..." -ForegroundColor Yellow
    try {
        Install-Module -Name powershell-yaml -Force -Scope CurrentUser -AllowClobber -ErrorAction Stop
        Write-Host "Module installed successfully." -ForegroundColor Green
    } catch {
        Write-Error "Failed to install module. Please install manually: Install-Module -Name powershell-yaml -Scope CurrentUser"
        exit 1
    }
}
Import-Module powershell-yaml -Force

# ---------- Load YAML (multidocument support) ----------
$yamlContent = Get-Content $yamlPath -Raw -Encoding UTF8
try {
    # Разбиваем на документы по --- (с учетом возможных пробелов)
    $documents = $yamlContent -split '(?m)^---\s*$' | Where-Object { $_ -match '\S' }
    $artifacts = @()
    foreach ($doc in $documents) {
        $parsed = ConvertFrom-Yaml -Yaml $doc
        if ($parsed) {
            # Если это массив (уже несколько объектов), добавляем их все
            if ($parsed -is [System.Collections.IEnumerable] -and $parsed -isnot [string]) {
                $artifacts += $parsed
            } else {
                $artifacts += $parsed
            }
        }
    }
    Write-Host "Loaded $($artifacts.Count) artifacts from YAML file." -ForegroundColor Cyan
} catch {
    Write-Error "YAML parsing error: $_"
    exit 1
}

# ---------- Environment variable substitution (fixed for PowerShell 5.1) ----------
function Expand-EnvVars {
    param($string)
    if ($null -eq $string) { return $null }
    
    $pattern = '%%([^%]+)%%'
    $result = $string
    
    $matches = [regex]::Matches($string, $pattern)
    foreach ($match in $matches) {
        $var = $match.Groups[1].Value
        $replacement = ""
        switch ($var) {
            'users.sid' { 
                $replacement = ([System.Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
            }
            'users.username' { $replacement = $env:USERNAME }
            'users.userprofile' { $replacement = $env:USERPROFILE }
            'users.appdata' { $replacement = $env:APPDATA }
            'users.localappdata' { $replacement = $env:LOCALAPPDATA }
            'users.localappdata_low' { $replacement = "$env:LOCALAPPDATA_LOW" }
            'users.personal' { $replacement = [Environment]::GetFolderPath('MyDocuments') }
            'users.desktop' { $replacement = [Environment]::GetFolderPath('Desktop') }
            'users.startup' { $replacement = [Environment]::GetFolderPath('Startup') }
            'users.cookies' { $replacement = [Environment]::GetFolderPath('Cookies') }
            'users.recent' { $replacement = [Environment]::GetFolderPath('Recent') }
            'users.temp' { $replacement = [Environment]::GetEnvironmentVariable('TEMP', 'User') }
            'users.homedir' { $replacement = $env:HOMEDRIVE + $env:HOMEPATH }
            'users.internet_cache' { $replacement = "$env:USERPROFILE\AppData\Local\Microsoft\Windows\INetCache" }
            'environ_systemroot' { $replacement = $env:SystemRoot }
            'environ_windir' { $replacement = $env:windir }
            'environ_systemdrive' { $replacement = $env:SystemDrive }
            'environ_programfiles' { $replacement = $env:ProgramFiles }
            'environ_programfilesx86' { $replacement = ${env:ProgramFiles(x86)} }
            'environ_commonprogramfiles' { $replacement = ${env:CommonProgramFiles} }
            'environ_commonprogramfilesx86' { $replacement = ${env:CommonProgramFiles(x86)} }
            'environ_allusersprofile' { $replacement = $env:ALLUSERSPROFILE }
            'environ_allusersappdata' { $replacement = "$env:ALLUSERSPROFILE\Application Data" }
            'environ_programdata' { $replacement = $env:ProgramData }
            'environ_profilesdirectory' {
                $val = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" -Name ProfilesDirectory -ErrorAction SilentlyContinue).ProfilesDirectory
                if ($val) { $replacement = $val } else { $replacement = "$env:SystemDrive\Users" }
            }
            'environ_comspec' { $replacement = $env:ComSpec }
            'environ_temp' { $replacement = [System.IO.Path]::GetTempPath() }
            'environ_path' { $replacement = $env:Path }
            'environ_driverdata' { $replacement = $env:DriverData }
            default {
                if (Test-Path "env:$var") { $replacement = (Get-ChildItem "env:$var").Value }
                else { $replacement = "%%$var%%" }
            }
        }
        $result = $result -replace [regex]::Escape($match.Value), $replacement
    }
    
    return $result
}

function Resolve-ArtifactPath {
    param($path)
    return Expand-EnvVars $path
}

# ---------- Collection functions ----------
function Get-RegistryKeyArtifact {
    param($keyPattern)
    $keyPattern = Resolve-ArtifactPath $keyPattern
    $keyPattern = $keyPattern -replace 'HKEY_LOCAL_MACHINE', 'HKLM:' -replace 'HKEY_USERS', 'HKU:' -replace 'HKEY_CURRENT_USER', 'HKCU:' -replace 'HKEY_CLASSES_ROOT', 'HKCR:'
    if ($keyPattern -match '\*') {
        $base = $keyPattern -replace '\*.*$', ''
        if (Test-Path $base) {
            Get-ChildItem -Path $base -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.PSPath -like $keyPattern }
        }
    } else {
        if (Test-Path $keyPattern) {
            Get-ChildItem -Path $keyPattern -ErrorAction SilentlyContinue
        }
    }
}

function Get-RegistryValueArtifact {
    param($key, $valueName)
    $key = Resolve-ArtifactPath $key
    $key = $key -replace 'HKEY_LOCAL_MACHINE', 'HKLM:' -replace 'HKEY_USERS', 'HKU:' -replace 'HKEY_CURRENT_USER', 'HKCU:' -replace 'HKEY_CLASSES_ROOT', 'HKCR:'
    
    if ($key -match '\*') {
        $base = $key -replace '\*.*$', ''
        if (Test-Path $base) {
            $matchingKeys = Get-ChildItem -Path $base -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.PSPath -like $key }
            $results = @()
            foreach ($item in $matchingKeys) {
                $itemProps = Get-ItemProperty -Path $item.PSPath -ErrorAction SilentlyContinue
                if ($valueName -eq '' -or $valueName -eq '*') {
                    $props = $itemProps.PSObject.Properties | Where-Object { $_.Name -notin @('PSPath','PSParentPath','PSChildName','PSDrive','PSProvider') }
                    foreach ($prop in $props) {
                        $results += [PSCustomObject]@{ Key = $item.PSPath; Name = $prop.Name; Value = $prop.Value }
                    }
                } else {
                    if ($itemProps.PSObject.Properties.Name -contains $valueName) {
                        $results += [PSCustomObject]@{ Key = $item.PSPath; Name = $valueName; Value = $itemProps.$valueName }
                    }
                }
            }
            return $results
        }
        return $null
    } else {
        if (Test-Path $key) {
            $item = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
            if ($valueName -eq '' -or $valueName -eq '*') {
                return $item.PSObject.Properties | Where-Object { $_.Name -notin @('PSPath','PSParentPath','PSChildName','PSDrive','PSProvider') }
            } else {
                if ($item.PSObject.Properties.Name -contains $valueName) {
                    return $item.$valueName
                }
            }
        }
        return $null
    }
}

function Get-FileArtifact {
    param($pathPattern)
    $pathPattern = Resolve-ArtifactPath $pathPattern
    if ($pathPattern -match '\*') {
        Get-ChildItem -Path $pathPattern -ErrorAction SilentlyContinue
    } else {
        if (Test-Path $pathPattern) {
            Get-Item -Path $pathPattern -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-CommandArtifact {
    param($cmd, $args)
    if ($cmd -eq 'netsh.exe') {
        $output = netsh $args 2>&1
        return $output
    } else {
        $output = & $cmd $args 2>&1
        return $output
    }
}

# ---------- Main collection routine ----------
function Invoke-ArtifactCollection {
    param($artifacts)

    $Host.UI.RawUI.ForegroundColor = "White"
    Write-Host "============================================================"
    Write-Host "WINDOWS ARTIFACT COLLECTION" -ForegroundColor Cyan
    Write-Host "============================================================"
    Write-Host "YAML file: $yamlPath" -ForegroundColor Gray
    Write-Host "Collected on: $(Get-Date)" -ForegroundColor Gray
    Write-Host "Total artifacts in file: $($artifacts.Count)" -ForegroundColor Yellow
    Write-Host "============================================================"
    Write-Host ""

    $total = 0
    $errors = 0

    foreach ($artifact in $artifacts) {
        $name = $artifact.name
        $doc = $artifact.doc -replace "`n", " " -replace "`r", ""
        $sources = $artifact.sources
        if (-not $sources) { continue }

        Write-Host "[$total] Artifact: $name" -ForegroundColor Yellow
        Write-Host "  Description: $doc" -ForegroundColor Gray
        Write-Host "  Sources:" -ForegroundColor Gray

        foreach ($source in $sources) {
            $type = $source.type
            $attrs = $source.attributes
            Write-Host "    Type: $type" -ForegroundColor Magenta

            switch ($type) {
                "REGISTRY_KEY" {
                    $keys = $attrs.keys
                    if ($keys) {
                        foreach ($k in $keys) {
                            Write-Host "      Key: $k" -ForegroundColor DarkCyan
                            $items = Get-RegistryKeyArtifact $k
                            if ($items) {
                                foreach ($item in $items) {
                                    Write-Host "        $($item.PSPath)" -ForegroundColor Green
                                }
                            } else {
                                Write-Host "        (not found)" -ForegroundColor DarkGray
                                $errors++
                            }
                        }
                    }
                }

                "REGISTRY_VALUE" {
                    $kvs = $attrs.key_value_pairs
                    if ($kvs) {
                        foreach ($kv in $kvs) {
                            $key = $kv.key
                            $valueName = $kv.value
                            Write-Host "      Key: $key" -ForegroundColor DarkCyan
                            $resolvedKey = Resolve-ArtifactPath $key
                            Write-Host "      Resolved key: $resolvedKey" -ForegroundColor Gray
                            Write-Host "      Value: $valueName" -ForegroundColor DarkCyan
                            $res = Get-RegistryValueArtifact -key $key -valueName $valueName
                            if ($null -ne $res) {
                                if ($res -is [System.Management.Automation.PSCustomObject] -or $res -is [System.Collections.IEnumerable]) {
                                    foreach ($item in $res) {
                                        if ($item -is [PSCustomObject]) {
                                            Write-Host "        $($item.Key) -> $($item.Name) = $($item.Value)" -ForegroundColor Green
                                        } else {
                                            foreach ($prop in $item.PSObject.Properties) {
                                                Write-Host "        $($prop.Name) = $($prop.Value)" -ForegroundColor Green
                                            }
                                        }
                                    }
                                } else {
                                    Write-Host "        Value: $res" -ForegroundColor Green
                                }
                            } else {
                                Write-Host "        (not found)" -ForegroundColor DarkGray
                                $errors++
                            }
                        }
                    }
                }

                "FILE" {
                    $paths = $attrs.paths
                    if ($paths) {
                        foreach ($p in $paths) {
                            Write-Host "      Path: $p" -ForegroundColor DarkCyan
                            $files = Get-FileArtifact $p
                            if ($files) {
                                foreach ($f in $files) {
                                    $size = if ($f.Length) { "$([math]::Round($f.Length/1KB,2)) KB" } else { "" }
                                    Write-Host "        $($f.FullName) $size" -ForegroundColor Green
                                }
                            } else {
                                Write-Host "        (not found)" -ForegroundColor DarkGray
                                $errors++
                            }
                        }
                    }
                }

                "COMMAND" {
                    $cmd = $attrs.cmd
                    $args = $attrs.args
                    Write-Host "      Command: $cmd $args" -ForegroundColor DarkCyan
                    $output = Invoke-CommandArtifact -cmd $cmd -args $args
                    if ($output) {
                        $lines = $output -split "`n" | Where-Object { $_ -ne "" }
                        if ($lines.Count -gt 10) {
                            Write-Host "        (showing first 10 of $($lines.Count) lines)" -ForegroundColor DarkGray
                            $lines = $lines[0..9]
                        }
                        foreach ($line in $lines) {
                            Write-Host "        $line" -ForegroundColor Green
                        }
                    } else {
                        Write-Host "        (empty output)" -ForegroundColor DarkGray
                        $errors++
                    }
                }

                "ARTIFACT_GROUP" {
                    $names = $attrs.names
                    Write-Host "      Artifact group: $($names -join ', ')" -ForegroundColor DarkCyan
                }

                default {
                    Write-Host "      Unsupported type: $type" -ForegroundColor Red
                }
            }
            Write-Host ""
        }
        $total++
        Write-Host "------------------------------------------------------------"
        Write-Host ""
    }

    Write-Host "============================================================"
    Write-Host "Collection finished. Processed artifacts: $total, errors/not found: $errors" -ForegroundColor Cyan
    Write-Host "============================================================"
}

# ---------- Run ----------
Invoke-ArtifactCollection -artifacts $artifacts