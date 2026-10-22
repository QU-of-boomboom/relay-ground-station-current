# 地面站当前源码（2026-10-22�?

仅收录当前旧版融合告警工程和正在使用的软件依赖。原工程不变�?

| 目录 | 内容 | 入口 |
|---|---|---|
| FPGA | 保留官方AI_Mate/MIG、PS原结算的PDR+RTT+AoI融合持续告警工程 | fpai_demo_vivado.xpr |
| PS | 板端接收、结算、寄存器访问、结果打印、UIO及热点适配 | runtime/push_worker.py |
| Sender | 电脑/未来Linux节点的独立发送程�? | node_sender.py |

不含旧工程分支、PS搬迁候选、网页服�?/HTML、日志、会话密钥、BOOT和综合布线缓存�?
PS的共享模块必须一起保留：接收入口会导入它们，有些旧名称仍是当前必需依赖，不是另一套运行版本�?
原生MMIO库仍含既有批量API声明；本接收程序未启用PS搬迁路线。不得为精简源码删除现用ABI依赖�?

## FPGA怎么打开

打开 `FPGA/fpai_demo_vivado.xpr`。需要原FMQL30TAI适配的Vivado 2018.3及官方数据库/补丁环境，不能用普通Xilinx安装代替�?
保留XPR中的宏、IP路径、约束和Tcl钩子；相对依赖已随包带上。XPR的原绝对Project Path/ImportPath为历史元数据，主要文件使用PPRDIR/PSRCDIR相对引用�?
toolchain_lock.json是原F173环境/基线记录，不是本导出包的完整清单；本包以SHA256SUMS和source_manifest.json绑定�?
这是源码工程，不包含Open Implemented Design所需的runs/DCP。没有重新综合或改写RTL/时钟�?
官方负脉宽仍在，严格bitstream门禁保留；不要直接把生成成功当成整板时序通过�?

## 板端和发送端

PS程序需要Python 3.10或以上；当前板端实际使用3.11.17，系统自�?3.8不能直接运行这些模块�?
`PS/runtime/push_worker.py` 是接收入口；`--candidate` 指向PS目录，使其找到software/pdr�?
其它参数通过 `--help` 查看。config.example.json仅是结构示例：文档保留地址、全零nonce和身�?1均必须替换；需要为每次会话分配新身份和独立密钥，不能直接作为现网配置�?
现有接收入口需要打开的控制stdin；输入STOP或Ctrl+C触发停止、排空及资源释放。等待done及cleanup结果，不要直接拔电或用kill -9代替清理�?
`PS/runtime/print_board_quality.py` 只读取接收日志；Ctrl+C只关闭打印，不会停止接收�?
网页已弃用；本包没有新增或验证一键终端会话配置器，不把复制源码称为全新设备一键部署完成�?

Sender/node_sender.py需要与接收端匹配的节点、会话、地址端口�?32字节密钥以hex从stdin输入，不放命令行或仓库�?
发送周�?50ms对应20�?/秒。当前发送的是明确标记synthetic的测试计数器和协议证据，不是无人机传感器数据�?

原生库源码在PS/software/pdr/register_mmio_library.cpp，连同同目录头文件保留�?
在AArch64 Linux或交叉编译环境使用C++17构建共享库，部署时重新计算SHA并传入接收入口；本次打包没有重新编译库�?
UIO程序/设备树在PS/board_platform。热点脚本在PS/board_wifi，仍依赖原板Linux5.4.52及配�?8821cu、cfg80211等模块、hostapd/dnsmasq和板上配置�?
完整厂家内核/无线驱动和板端私有热点配置不在本包中；不能仅凭本包宣称可以给任意板重新安装无线环境�?

## 当前验证范围

已有综合布线：地面站路径setup +0.083ns、hold +0.035ns；官方AI最差脉�?-0.409ns，整板仍Failed Timing。Slice 98.51%，CDC原警告保留�?
已有真实板寄存器融合告警触发/恢复/过期、单USB无线节点20�?/秒和正常停止测试。未完成长期恶劣链路与多节点完整验收�?
软件包含2026-10-22 RTT窗口边界修复，未修改RTL。RSSI、NPU推理和进一步PS迁移暂停�?
详细历史实现指标在implementation_summary.json；其中board_tested=false是生成该报告当时状态，不覆盖后来实板结果�?

## 上传GitHub

上传本文件夹内容即可，保留目录结构。密码、节点密钥和运行日志不在包内�?
包含运行所需的厂家IP/网表及补丁，建议先使用私有仓库；公开再分发前确认厂家许可。没有替厂家代码添加开源许可证�?
SHA256SUMS用于检查本次副本，source_manifest.json记录原仓库相对来源与原始SHA�?
