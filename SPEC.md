# 实现说明

## 执行流程

- `apply.cmd` 和 `restore.cmd` 使用 Windows PowerShell 启动脚本。用户设置以当前 Windows 账户写入，软件限制策略由单独的管理员子进程处理。
- 安装路径和版本来自搜狗输入法注册表项。脚本使用 `SGTool.exe` 的广告开关，关闭 `Sogou.Ime.SysToast.Biz` 通知，并修改用户配置中的 `BizCenterCom`、`EnableImePop`、`EnableStatusSkinPop` 和 `Popup_DisableSkinBubble`。
- Windows 软件限制策略使用三条路径规则，分别匹配安装目录下的 `Components\biz_center\*`、`*\PinyinUp.exe` 和 `*\SGDownload.exe`。遇到其他软件限制策略时停止。写入后通过挂起创建进程检查规则，随后结束已运行的匹配程序。挂起检查会在目标代码启动前结束进程。
- 当前用户的备份保存在本机。重复应用沿用现有备份，新出现的配置项在首次改动前补入备份。恢复按备份撤销注册表值、INI 项和对应的启动规则。旧版脚本的有效本机备份可以迁移。
- 策略首次写入失败时会回滚。若策略通过后用户设置写入失败，可重新应用或执行恢复。

Windows 路径规则的行为见 [Microsoft 软件限制策略文档](https://learn.microsoft.com/en-us/windows-server/identity/software-restriction-policies/work-with-software-restriction-policies-rules)。
