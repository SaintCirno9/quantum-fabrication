# Benchmark TODO

- [ ] 拆分 `tracking.update_entity`，当前函数级总耗时最高：总 `127.5654ms`，均 `0.041257ms`
- [ ] 拆分队列处理 `nth(120,15,30,60,600)`、`nth(8)`、`nth(19)`、`nth(84)`，它们是当前最重的队列级热点
- [ ] 单独检查 `qs_utils.get_storage_signals`，当前单次均耗较高：均 `0.480024ms`
- [ ] 单独检查 `instant_fabrication`，当前总耗时偏高：总 `79.7824ms`
- [ ] 给 `tracking_utils.lua` 里的几个 `nth(...)` 队列补更细一级的 instrument
- [ ] 给 `tracking.update_entity` 补更细一级的 instrument，区分读箱子、算需求、电路信号、存取仓库、解构判断
- [ ] 后续 benchmark 统一只比较同一层数据，事件级和函数级不要混着相加
- [ ] `decraft` 暂时降级，不作为当前优化重点：总 `6.8819ms`，均 `0.002461ms`
