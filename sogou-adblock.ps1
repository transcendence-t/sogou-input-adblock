param(
    [ValidateSet('Apply', 'Restore')]
    [string]$Action = 'Apply'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'sogou-installation.ps1')

$store = 'HKCU:\Software\SogouInput.store.user'
$toast = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Sogou.Ime.SysToast.Biz'
$profileRoot = Join-Path (Split-Path $env:LOCALAPPDATA -Parent) 'LocalLow\SogouPY.users'
$backup = Join-Path $env:LOCALAPPDATA 'SogouInputAdBlock'
$settingsFile = Join-Path $backup 'settings.json'
$policyFile = Join-Path $backup 'machine-ad-policy-before.json'
$policyScript = Join-Path $PSScriptRoot 'block-ad-processes.ps1'

Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
using System.Text;
public static class SogouAdConfig {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool WritePrivateProfileString(string section, string key, string value, string fileName);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    public static extern uint GetPrivateProfileString(string section, string key, string defaultValue, StringBuilder value, uint size, string fileName);
}
'@

function Get-RegistrySetting($Path, $Name) {
    $key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    $exists = $null -ne $key -and $key.GetValueNames() -contains $Name
    [pscustomobject]@{
        KeyExisted = $null -ne $key
        Kind = if ($exists) { $key.GetValueKind($Name).ToString() } else { $null }
        Value = if ($exists) { $key.GetValue($Name, $null, 'DoNotExpandEnvironmentNames') } else { $null }
    }
}

function Set-RegistrySetting($Path, $Name, $Setting) {
    if ($Setting.Kind) {
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Setting.Value -PropertyType $Setting.Kind -Force | Out-Null
    } elseif (Test-Path -LiteralPath $Path) {
        $key = Get-Item -LiteralPath $Path
        if ($key.GetValueNames() -contains $Name) { Remove-ItemProperty -LiteralPath $Path -Name $Name }
        if (-not $Setting.KeyExisted -and $key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0) {
            Remove-Item -LiteralPath $Path
        }
    }
}

function Get-IniSetting($Path, $Section, $Name) {
    $missing = [string][char]1
    $buffer = [Text.StringBuilder]::new(2048)
    [void][SogouAdConfig]::GetPrivateProfileString($Section, $Name, $missing, $buffer, $buffer.Capacity, $Path)
    $value = $buffer.ToString()
    if ($value -eq $missing) { return $null }
    return $value
}

function Set-IniSetting($Setting, $Value) {
    $text = if ($null -eq $Value) { [NullString]::Value } else { [string]$Value }
    if (-not [SogouAdConfig]::WritePrivateProfileString($Setting.Section, $Setting.Name, $text, $Setting.Path)) {
        throw "无法写入 $($Setting.Path) 中的 $($Setting.Name)。"
    }
}

function Get-ProfileSettings {
    $profiles = Get-ChildItem -LiteralPath $profileRoot -Directory -ErrorAction SilentlyContinue
    foreach ($profile in $profiles) {
        $config = Join-Path $profile.FullName 'Components\ComponentConfig.ini'
        $envIni = Join-Path $profile.FullName 'env.ini'
        if (Test-Path -LiteralPath $config -PathType Leaf) {
            [pscustomobject]@{ Path = $config; Section = 'Active'; Name = 'BizCenterCom'; Target = '0' }
        }
        if (Test-Path -LiteralPath $envIni -PathType Leaf) {
            foreach ($name in 'EnableImePop', 'EnableStatusSkinPop', 'Popup_DisableSkinBubble') {
                $target = if ($name -eq 'Popup_DisableSkinBubble') { '1' } else { '0' }
                [pscustomobject]@{ Path = $envIni; Section = 'Setting'; Name = $name; Target = $target }
            }
        }
    }
}

function Get-LegacyBackup {
    $latest = Join-Path $PSScriptRoot 'backups\latest.txt'
    $legacyRule = 'HKLM:\Software\Policies\Microsoft\Windows\Safer\CodeIdentifiers\0\Paths\{EA334C12-45AA-459A-B539-87AB705A5B10}'
    if (-not (Test-Path -LiteralPath $latest) -or -not (Test-Path -LiteralPath $legacyRule)) { return }

    $source = (Get-Content -LiteralPath $latest -Raw -Encoding UTF8).Trim()
    $legacyPolicy = Join-Path $source 'machine-ad-policy-before.json'
    $result = Get-Content -LiteralPath (Join-Path $source 'machine-ad-policy-result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $changes = Get-Content -LiteralPath (Join-Path $source 'changes.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $result.Applied -or $changes.EnvPath -notlike "$profileRoot\*") { return }
    $storeFile = Join-Path $source 'store-user-values.json'
    Add-Type -AssemblyName System.Web.Extensions
    $serializer = [System.Web.Script.Serialization.JavaScriptSerializer]::new()
    $original = $serializer.DeserializeObject((Get-Content -LiteralPath $storeFile -Raw -Encoding UTF8))
    $originalToast = Get-Content -LiteralPath (Join-Path $source 'toast-setting.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $oldEnv = Join-Path $source 'env.ini'
    $ini = @(
        [pscustomobject]@{ Path = $changes.ConfigPath; Section = 'Active'; Name = 'BizCenterCom'; Value = [string]$changes.OriginalBizCenter }
        foreach ($name in 'EnableImePop', 'EnableStatusSkinPop', 'Popup_DisableSkinBubble') {
            [pscustomobject]@{ Path = $changes.EnvPath; Section = 'Setting'; Name = $name; Value = (Get-IniSetting $oldEnv 'Setting' $name) }
        }
    )
    New-Item -Path $backup -ItemType Directory -Force | Out-Null
    Copy-Item -LiteralPath $legacyPolicy -Destination $policyFile
    [pscustomobject]@{
        Ad = @{
            KeyExisted = $true
            Kind = if ($original.ContainsKey('usafenable')) { 'DWord' } else { $null }
            Value = $original['usafenable']
        }
        Toast = @{ KeyExisted = $originalToast.KeyExisted; Kind = $originalToast.EnabledKind; Value = $originalToast.EnabledValue }
        Ini = $ini
    }
}

function Invoke-MachinePolicy($Operation) {
    $errorFile = Join-Path $backup 'policy-error.txt'
    if (Test-Path -LiteralPath $errorFile) { Remove-Item -LiteralPath $errorFile }
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File ""$policyScript"" -Action $Operation -Snapshot ""$backup"""
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    $elevation = if ($principal.IsInRole('Administrator')) { @{} } else { @{ Verb = 'RunAs' } }
    $process = Start-Process -FilePath $powershell -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru @elevation
    if ($process.ExitCode -ne 0) {
        if (Test-Path -LiteralPath $errorFile) { throw (Get-Content -LiteralPath $errorFile -Raw) }
        throw "Windows 软件限制策略操作失败，退出码 $($process.ExitCode)。"
    }
}

function Invoke-AdSwitch($Tool) {
    $process = Start-Process -FilePath $Tool -ArgumentList '--appid=usadfree', '-usafswitch', '1' -WindowStyle Hidden -PassThru
    if (-not $process.WaitForExit(10000)) { throw '搜狗广告开关执行超时。' }
    if ($process.ExitCode -ne 0) { throw "搜狗广告开关执行失败，退出码 $($process.ExitCode)。" }
}

function Save-Settings($Settings) {
    New-Item -Path $backup -ItemType Directory -Force | Out-Null
    $tempFile = Join-Path $backup 'settings.tmp'
    $Settings | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tempFile -Encoding UTF8
    Move-Item -LiteralPath $tempFile -Destination $settingsFile -Force
}

$userId = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$mutex = [Threading.Mutex]::new($false, "Global\SogouInputAdBlock-$userId")
$locked = $false
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw '已有去广告或恢复脚本正在运行。' }

    $settings = if (Test-Path -LiteralPath $settingsFile) {
        Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json
    } else {
        $legacy = Get-LegacyBackup
        if ($legacy) { Save-Settings $legacy; $legacy }
    }

    if ($Action -eq 'Restore') {
        if (-not $settings) {
            Write-Host '当前用户没有可恢复的备份。'
            exit 0
        }
        if (Test-Path -LiteralPath $policyFile) { Invoke-MachinePolicy Restore }
        Set-RegistrySetting $store 'usafenable' $settings.Ad
        Set-RegistrySetting $toast 'Enabled' $settings.Toast
        foreach ($entry in $settings.Ini) {
            if (Test-Path -LiteralPath $entry.Path -PathType Leaf) { Set-IniSetting $entry $entry.Value }
        }
        if (Test-Path -LiteralPath $policyFile) { Remove-Item -LiteralPath $policyFile }
        Remove-Item -LiteralPath $settingsFile
        Write-Host '已恢复搜狗设置和 Windows 启动规则。'
        exit 0
    }

    $install = Get-SogouInstallation
    $targets = @(Get-ProfileSettings)
    if ($targets.Count -eq 0) { throw '尚未找到搜狗用户配置。请先用搜狗输入法打一次字，再运行本脚本。' }

    $newBackup = -not $settings
    if ($newBackup) {
        $settings = [pscustomobject]@{
            Ad = Get-RegistrySetting $store 'usafenable'
            Toast = Get-RegistrySetting $toast 'Enabled'
            Ini = @()
        }
    }
    $newEntries = foreach ($target in $targets) {
        if (-not ($settings.Ini | Where-Object { $_.Path -eq $target.Path -and $_.Name -eq $target.Name })) {
            [pscustomobject]@{
                Path = $target.Path; Section = $target.Section; Name = $target.Name
                Value = Get-IniSetting $target.Path $target.Section $target.Name
            }
        }
    }
    if ($newBackup -or $newEntries) {
        $settings.Ini = @($settings.Ini) + @($newEntries | Where-Object { $null -ne $_ })
        Save-Settings $settings
    }

    try {
        Invoke-MachinePolicy Apply
    } catch {
        if ($newBackup -and -not (Test-Path -LiteralPath $policyFile)) { Remove-Item -LiteralPath $settingsFile }
        throw
    }
    Invoke-AdSwitch $install.Tool
    if ((Get-RegistrySetting $store 'usafenable').Value -ne 1) {
        throw '搜狗广告开关未生效。可重新应用或运行恢复脚本撤销。'
    }
    Set-RegistrySetting $toast 'Enabled' @{ Kind = 'DWord'; Value = 0 }
    foreach ($target in $targets) { Set-IniSetting $target $target.Target }
    Write-Host "已禁用搜狗广告和更新程序。备份位于 $backup"
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
exit 0
