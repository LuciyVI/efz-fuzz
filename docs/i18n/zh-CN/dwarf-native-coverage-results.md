# DWARF/原生覆盖率结果

[English](../../dwarf-native-coverage-results.md) · [Русский](../ru/dwarf-native-coverage-results.md) · [Español](../es/dwarf-native-coverage-results.md) · **简体中文** · [所有语言](../README.md)

2026-10-03 的状态：**直接读取辅助程序已推迟**。有关观察到的 OTP
布局、指针生命周期问题以及可复现的后续研究设置，请参阅
[`dwarf-native-coverage.md`](dwarf-native-coverage.md)。

| 检查 | 结果 |
| --- | --- |
| OTP 原生覆盖率公共 API | 通过小型行覆盖率测试夹具和实验性 `otp_native_public` 后端的检查 |
| DWARF 类型/字段发现 | 在所研究的 OTP 27.0 二进制文件上通过 |
| 安全的直接覆盖率读取 | 未运行 — 尚无经过验证的代码加载器生命周期约定/辅助程序 |
| 直接读取与 `code:get_coverage/2` 的比较 | 未运行 |
| OTP-public Cowboy 冒烟测试（30 s） | 修复语料库元数据形态后通过：最终代码完成 5889 次执行，196.26 exec/s，0 次基础设施错误；最终代码仅运行一次 |
| DWARF-native Cowboy 冒烟测试（30 s） | 未运行 — 后端尚未实现 |
| 原生重置/读取/新颖性/合并微基准测试 | 通过；参见 `docs/performance/otp-native-public-2026-10-03.term` 和 `otp-native-public-cowboy-2026-10-03.term` |
| 15 分钟 Cowboy 运行 | 未运行；留待冒烟测试后手动执行 |

在固定的 Cowboy GET 路径上，各组件的中位数为：重置 0.50 µs，
`code:get_coverage` 5.63 µs，紧凑表示转换 30.77 µs，无新颖性扫描
3.37 µs，合并 4.97 µs，完整的直接目标循环 68.68 µs（两次预热后，采集 10 个样本，
每个样本 100 次迭代）。30 秒完整 EFZ 运行的平均每次执行时间约为
5.1 ms，因此目前尚未证明 `get_coverage` 或转换
主导了端到端 EFZ 时间。仅凭这些测量结果，尚不足以支持实现直接读取辅助程序。
**没有** DWARF-native 性能数据。
