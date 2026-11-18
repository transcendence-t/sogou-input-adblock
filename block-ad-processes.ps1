param(
    [ValidateSet('Apply', 'Restore', 'Check')]
    [string]$Action = 'Check',
    [string]$Snapshot
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'sogou-installation.ps1')
$policyRoot = 'HKLM:\Software\Policies\Microsoft\Windows\Safer\CodeIdentifiers'
$ruleRoot = Join-Path $policyRoot '0\Paths'
$policyValues = @{
    DefaultLevel = 262144
    PolicyScope = 0
    TransparentEnabled = 1
}
$rules = @(
    @{ Id = '{EA334C12-45AA-459A-B539-87AB705A5B10}'; Suffix = 'Components\biz_center\*' },
    @{ Id = '{B77B7044-55A0-4F87-AE88-7D95E1C95CC0}'; Suffix = '*\PinyinUp.exe' },
    @{ Id = '{A4A7AFD1-8D3D-4E18-98A6-26D8D3A2863E}'; Suffix = '*\SGDownload.exe' }
)

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class SogouAdLaunchCheck {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct StartupInfo {
        public int cb;
        public string reserved, desktop, title;
        public uint x, y, width, height, xChars, yChars, fill, flags;
        public short show, reservedSize;
        public IntPtr reservedPointer, stdin, stdout, stderr;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct ProcessInfo {
        public IntPtr process, thread;
        public uint processId, threadId;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateProcess(string application, string command,
        IntPtr processSecurity, IntPtr threadSecurity, bool inheritHandles,
        uint flags, IntPtr environment, string directory,
        ref StartupInfo startup, out ProcessInfo info);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool TerminateProcess(IntPtr process, uint exitCode);
    [DllImport("kernel32.dll")]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);
    public static int Check(string file) {
        var startup = new StartupInfo();
        startup.cb = Marshal.SizeOf(typeof(StartupInfo));
        startup.flags = 1;
        ProcessInfo info;
        // CREATE_SUSPENDED prevents the target's entry point from running.
        if (!CreateProcess(file, null, IntPtr.Zero, IntPtr.Zero, false,
            0x08000004, IntPtr.Zero, null, ref startup, out info))
            return Marshal.GetLastWin32Error();
        try {
            if (!TerminateProcess(info.process, 0))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            if (WaitForSingleObject(info.process, 5000) != 0)
                throw new Exception("Probe termination did not complete.");
        } finally {
            CloseHandle(info.thread);
            CloseHandle(info.process);
        }
        return 0;
    }
}
'@

function Test-LaunchRestrictions($Install) {
    $tests = @(
        foreach ($name in 'PinyinUp.exe', 'SGDownload.exe', 'SGTool.exe', 'SogouCloud.exe') {
            @{ Path = Join-Path $Install.VersionFolder $name; ExpectedBlocked = $name -in 'PinyinUp.exe', 'SGDownload.exe' }
        }
        if ($Install.BizFolder) {
            foreach ($name in 'biz_helper.exe', 'biz_notify.exe', 'biz_render.exe') {
                @{ Path = Join-Path $Install.BizFolder $name; ExpectedBlocked = $true }
            }
        }
    )
    foreach ($test in $tests) {
        if (-not (Test-Path -LiteralPath $test.Path -PathType Leaf)) { continue }
        $errorCode = [SogouAdLaunchCheck]::Check($test.Path)
        [pscustomobject]@{
            Path = $test.Path
            CreateProcessError = $errorCode
            TargetCodeExecuted = $false
            ExpectedBlocked = $test.ExpectedBlocked
        }
    }
}

if ($Action -eq 'Check') {
    @{ Checks = @(Test-LaunchRestrictions (Get-SogouInstallation)) } | ConvertTo-Json -Depth 4
    exit 0
}

$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw '修改 Windows 软件限制策略需要管理员权限。'
}
if (-not $Snapshot) { throw '缺少备份目录。' }
$stateFile = Join-Path $Snapshot 'machine-ad-policy-before.json'
$errorFile = Join-Path $Snapshot 'policy-error.txt'

function Restore-Policy {
    $original = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
    foreach ($rule in $rules) {
        $rulePath = Join-Path $ruleRoot $rule.Id
        if (Test-Path -LiteralPath $rulePath) {
            Remove-Item -LiteralPath $rulePath -Recurse
        }
    }
    foreach ($path in @((Join-Path $policyRoot '0\Paths'), (Join-Path $policyRoot '0'))) {
        if (Test-Path -LiteralPath $path) {
            $key = Get-Item -LiteralPath $path
            if ($key.SubKeyCount -eq 0 -and $key.ValueCount -eq 0) {
                Remove-Item -LiteralPath $path
            }
        }
    }
    if (-not (Test-Path -LiteralPath $policyRoot)) { return }
    foreach ($value in $original.Values) {
        if (-not $policyValues.ContainsKey([string]$value.Name)) { continue }
        if ($value.Existed) {
            New-ItemProperty -LiteralPath $policyRoot -Name $value.Name -Value ([int]$value.Value) -PropertyType DWord -Force | Out-Null
        } elseif ((Get-Item -LiteralPath $policyRoot).GetValueNames() -contains $value.Name) {
            Remove-ItemProperty -LiteralPath $policyRoot -Name $value.Name
        }
    }
    $key = Get-Item -LiteralPath $policyRoot
    if ($original.RootExisted -eq $false -and $key.SubKeyCount -eq 0 -and $key.ValueCount -eq 0) {
        Remove-Item -LiteralPath $policyRoot
    }
}

function Assert-PolicyOwnership($HasBackup) {
    if (-not (Test-Path -LiteralPath $policyRoot)) { return }
    $key = Get-Item -LiteralPath $policyRoot
    $hasDefault = $key.GetValueNames() -contains 'DefaultLevel'
    $allowedKeys = @("$($key.Name)\0", "$($key.Name)\0\Paths")
    $allowedKeys += @($rules | ForEach-Object { "$($key.Name)\0\Paths\$($_.Id)" })
    $extraKeys = @(Get-ChildItem -LiteralPath $policyRoot -Recurse | Where-Object {
        $_.Name -notin $allowedKeys
    })
    $unexpectedDefault = $hasDefault -and (-not $HasBackup -or $key.GetValue('DefaultLevel') -ne $policyValues.DefaultLevel)
    if ($extraKeys.Count -gt 0 -or $unexpectedDefault -or (-not $HasBackup -and $key.SubKeyCount -ne 0)) {
        throw '检测到已有 Windows 软件限制策略。请先恢复旧版脚本的规则，或请策略管理员处理。'
    }
}

function Save-Policy {
    $key = Get-Item -LiteralPath $policyRoot -ErrorAction SilentlyContinue
    $values = foreach ($name in $policyValues.Keys) {
        $exists = $null -ne $key -and $key.GetValueNames() -contains $name
        [pscustomobject]@{
            Name = $name
            Existed = $exists
            Value = if ($exists) { $key.GetValue($name) } else { $null }
        }
    }
    $tempFile = Join-Path $Snapshot 'machine-ad-policy-before.tmp'
    @{ RootExisted = $null -ne $key; Values = @($values) } |
        ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $tempFile -Encoding UTF8
    Move-Item -LiteralPath $tempFile -Destination $stateFile -Force
}

$mutex = [Threading.Mutex]::new($false, 'Global\SogouInputAdBlockPolicy')
$locked = $false
$newPolicy = $false
try {
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw '已有脚本正在修改 Windows 启动规则。' }
    $hasBackup = Test-Path -LiteralPath $stateFile
    Assert-PolicyOwnership $hasBackup
    if ($Action -eq 'Restore') {
        if ($hasBackup) { Restore-Policy }
        exit 0
    }

    $install = Get-SogouInstallation
    if (-not $hasBackup) {
        Save-Policy
        $newPolicy = $true
    }
    foreach ($rule in $rules) {
        $rulePath = Join-Path $ruleRoot $rule.Id
        New-Item -Path $rulePath -Force | Out-Null
        New-ItemProperty -LiteralPath $rulePath -Name ItemData -Value (Join-Path $install.Root $rule.Suffix) -PropertyType String -Force | Out-Null
        New-ItemProperty -LiteralPath $rulePath -Name Description -Value 'Block Sogou advertisements and software updates' -PropertyType String -Force | Out-Null
        New-ItemProperty -LiteralPath $rulePath -Name SaferFlags -Value 0 -PropertyType DWord -Force | Out-Null
        New-ItemProperty -LiteralPath $rulePath -Name LastModified -Value ([DateTime]::UtcNow.ToFileTimeUtc()) -PropertyType QWord -Force | Out-Null
    }
    foreach ($name in $policyValues.Keys) {
        New-ItemProperty -LiteralPath $policyRoot -Name $name -Value $policyValues[$name] -PropertyType DWord -Force | Out-Null
    }
    $checkOutput = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Action Check
    if ($LASTEXITCODE -ne 0) { throw '无法运行 Windows 启动规则检查。' }
    $checks = @((($checkOutput | Out-String) | ConvertFrom-Json).Checks)
    $failed = @($checks | Where-Object {
        ($_.ExpectedBlocked -and $_.CreateProcessError -ne 1260) -or
        (-not $_.ExpectedBlocked -and $_.CreateProcessError -ne 0)
    })
    if ($failed.Count) { throw ('Windows 启动规则校验失败。' + ($failed | ConvertTo-Json -Compress)) }
    $installPattern = [WildcardPattern]::Escape($install.Root.TrimEnd('\'))
    Get-CimInstance Win32_Process | Where-Object {
        $_.ExecutablePath -like "$installPattern\Components\biz_center\*" -or
        ($_.ExecutablePath -like "$installPattern\*" -and $_.Name -in 'PinyinUp.exe', 'SGDownload.exe')
    } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
} catch {
    $failure = $_.Exception.Message
    if ($newPolicy) {
        try {
            Restore-Policy
            Remove-Item -LiteralPath $stateFile
        } catch {
            $failure += " Windows 启动规则自动恢复失败。$($_.Exception.Message)"
        }
    }
    Set-Content -LiteralPath $errorFile -Value $failure -Encoding UTF8
    exit 1
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
exit 0
