function Get-SogouInstallation {
    foreach ($view in 'Registry32', 'Registry64') {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', $view)
        try {
            $key = $base.OpenSubKey('SOFTWARE\SogouInput')
            if ($null -eq $key) { continue }
            try {
                $root = [string]$key.GetValue('')
                $version = [string]$key.GetValue('Version')
                $bizPath = [string]$key.GetValue('BizPath')
            } finally {
                $key.Dispose()
            }
        } finally {
            $base.Dispose()
        }

        if (-not [IO.Path]::IsPathRooted($root) -or $version -notmatch '^\d+(\.\d+)+$') { continue }
        $root = [IO.Path]::GetFullPath($root)
        $versionFolder = Join-Path $root $version
        $tool = Join-Path $versionFolder 'SGTool.exe'
        if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) { continue }

        $bizRoot = Join-Path $root 'Components\biz_center'
        $bizFolder = if ($bizPath.StartsWith("$bizRoot\", [StringComparison]::OrdinalIgnoreCase)) {
            Split-Path -Parent $bizPath
        }
        return [pscustomobject]@{
            Root = $root
            VersionFolder = $versionFolder
            Tool = $tool
            BizFolder = $bizFolder
        }
    }
    throw '未找到已安装的搜狗输入法。请先安装，再运行此脚本。'
}
