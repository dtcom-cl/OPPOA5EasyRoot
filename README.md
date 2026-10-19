# OPPO A5 一键 Root 工具箱

> OPPO A5 2018 版的一键 root 工具

目前暂不支持其他型号

# 主要功能

* 一键root：替换 system 分区为内置 Magisk 27 的原厂系统，开启 Zygisk，安装完整性绕过与弹窗关闭模块，自动验收
* 一键救砖：从本地备份恢复 system，或 system + boot
* 刷前自动备份原机 system 与 boot，最多保留 3 份
* 镜像不预置，每次用当前手机自己的 system 现场制作，避免系统与 vendor 不匹配

# 使用说明

解压后双击 `双击运行.bat`，本工具支持一键root和救砖，菜单里选 1 或 2。

唯一需要手动操作的是进入 9008 下载模式：手机关机，同时按住电源键、音量加、音量减，直到出现OPPO logo时松开关机键，音量上下键继续按，进入recovery模式，选择任意语言，确保数据线插入，连续点击版本号可进入授权的9008。进入后自动继续，未识别到会一直等待，按 Ctrl+C 中止。

# 运行环境

* Windows 10 / 11，系统自带 PowerShell 5.1
* 高通 9008 驱动，设备管理器中应显示 Qualcomm HS-USB QDLoader 9008
* 支持数据传输的 USB 线
* 工具箱所在盘可用空间不少于 12 GB
* 手机电量充足

# 救砖

开机卡在第二屏时，强制关机后重新开机，在开机动画出现时长按音量减进入安全模式，删除可疑模块后重启。仍进不去系统则用菜单里的一键救砖。

# 免责声明

本工具会直接改写手机的 system 分区，操作不当可能导致设备无法开机或数据丢失。使用前请确认已完成备份，风险由使用者自行承担，作者不对任何设备损坏或数据丢失负责。

# 注意事项

* 不要在 Magisk App 中点「安装 / 修补 boot」，会导致无法开机
* 不要安装 Shamiko，本机型实测会卡开机
* 不要写入 persist、modemst1、modemst2、fsg、ocdt 分区
* 刷入后 ro.adb.secure 关闭，shell 用户获得永久 root 权限，任何能通过 USB 连接的设备都可直接取得 root

# 文件说明

自己写的部分：

* `双击运行.bat` 入口，纯 ASCII，避免中文与 cmd 特殊字符冲突
* `bin\toolkit.ps1` 主流程：菜单、前置自检、按步骤调度
* `bin\lib\*.ps1` 功能模块，共 7 个：`00-common` 输出与日志、`10-precheck` 前置自检、`20-device` 设备与分区表、`30-image` 镜像制作、`40-flash` 刷写、`50-config` Magisk 配置、`60-rescue` 救砖

第三方与素材：

* `bin\tools\` 高通 EDL 工具与 adb，来源见 `bin\tools\CREDITS.txt`
* `bin\ref\` 镜像注入素材，含 Magisk 与系统文件
* `bin\modules\` Magisk 模块包
* `bin\images\`、`bin\backup\`、`bin\logs\`、`bin\work\` 运行期生成，不随包发布

# 工具链设计说明

* **干跑自检**：`-Check` 只跑前置检查并退出，全程不接触手机，用来确认环境是否齐备
* **误触保护**：菜单连续输错 5 次自动退出，避免反复误选触发刷写
* **异常安全**：主流程包在 `try/finally` 里，成功、抛异常、Ctrl+C 都会清理暂存区，不留残片
* **模块自载入**：`bin\lib` 下的模块按文件名序号依次加载，新增模块命名对齐即自动生效，无需改主流程

# 问题反馈

如遇问题请到 GitHub 提 issue：https://github.com/dtcom-cl/OPPOA5EasyRoot/issues
反馈时说明问题，会尽快核实并修复，感谢支持。
