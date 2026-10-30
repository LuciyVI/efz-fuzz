# 本地 Erlamsa 变异提供者

本页是简明指南。[完整契约和操作目录](../../erlamsa-integration.md)以英语发布。

通过 `mutation_provider.mode = erlamsa` 或 `hybrid` 显式启用。语义适配器独立配置；默认仍为 native。`vendor/erlamsa` 的 gitlink 固定 core 版本，不会随 fork 分支自动更新。

```sh
git submodule update --init --recursive
ERL_FLAGS='+S 2:2' rebar3 as erlamsa compile
```

启用提供者但缺少已构建 core 时，目标执行前会报告配置错误。已保存字节的 raw replay 不需要 core；重新生成需要匹配的构建和配置标识。提供者错误及超时不计为目标崩溃。[历史验证](../../erlamsa-validation.md)仅对应其中记录的 SHA。
