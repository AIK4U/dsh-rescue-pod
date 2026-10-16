# dsh-rescue-pod

> 一个急救包**只有在完整的时候才存在**。这份仓库是那条保证的构建器、它的失败注入测试，以及一个专门盯「你改了构建器、却忘了重跑测试」的只读闸门。

过期的包是**旧的但完整**，你能用它；半个包是**看着在、用的时候才失败**——而你去拿它的时候，已经没有第二次机会。

---

## 它解决什么

| 死法 | 现象 | 为什么难发现 |
|---|---|---|
| **① 就地构建留下缺口** | 报错退出后，盘上留一个删了一半的目录 | 目录还在、名字还对、点进去还有文件——**没有任何东西告诉人它是坏的** |
| **② 卫星文件静默覆盖** | 包里的文件被一个小文件顶掉 | 拷贝带 `-Force`，一声不响。实测：33 字节的卫星把包内 5347 字节的 `README.md` 覆盖了 |
| **③ 保证悄悄退化** | 构建器被改坏，而下一次构建在很久以后 | 每一次健康的构建**看起来完全一样**；手工纪律没有存量证据 |

三条的共同点：**它们都不是逻辑错误，而是「说的和做的不一致」**。所以没有任何单点检查能抓住它们，只能靠「先建到旁边、自检通过才换名」这种结构性做法，加上一个会把失败**注入**出来的测试。

完整的量测与踩坑见 **[`docs/half-built.md`](docs/half-built.md)**。那份文档比代码重要。

---

## 保证

```
1. 所有字节写进 <pod>.staging        活包一个字节都不碰
2. 在 staging 上跑自检               ASCII/BOM + 语法 + 清单
3. 活包  -> <pod>.replaced           一次 rename
4. staging -> <pod>                  一次 rename
5. 删掉 <pod>.replaced
```

换名是原子的：**「两个名字都不完整」的窗口只有一次 rename 那么宽**，不是整个构建耗时。失败发生在 1–2 步，活包原封不动；发生在第 3 步（活包被占），此时还什么都没破坏，而且报错很响。

三个细节是**量出来的**，不是猜的：

- `trap` 里写 **`throw $_`**，不写裸 `throw`。PS 5.1 实测：裸 `throw` 会把原始消息替换成 `ScriptHalted`——重名那条指名道姓的报错被吞掉。
- 清理代码**只认识 staging 路径**，结构上碰不到活包；且必须写成 `if ($stageDir -and (Test-Path ...))`，否则在 `$stageDir` 赋值之前的失败会让清理代码自己变成新错误。
- 换名之后的失败（比如打包 zip）不会伤到已换入的包——staging 路径已经不存在，清理是空转。

---

## 快速开始

```powershell
# 1. 构建（产出落进 .\build\，已被 .gitignore 覆盖）
powershell -NoProfile -ExecutionPolicy Bypass -File example\pkg\_guard\build-pod.ps1 `
    -PodDir .\build\RESCUE-POD -RootDir .\build

# 2. 失败注入测试：16 条断言。全绿时写一个戳
powershell -NoProfile -ExecutionPolicy Bypass -File example\pkg\_selftest\pod-failtest.ps1

# 3. 只读闸门：构建器改过而没重跑测试，就会叫
powershell -NoProfile -ExecutionPolicy Bypass -File tools\check-buildtest-stamp.ps1

# 4. 本仓库自己的测试套件
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
```

三个工具的退出码：

| 工具 | 退出码 | 含义 |
|---|---|---|
| `example\pkg\_guard\build-pod.ps1` | `0` / `1` | 构建成功 / 失败（**失败时活包未被碰过**，staging 已被清） |
| `example\pkg\_selftest\pod-failtest.ps1` | `0` / `1` | 16 条断言全过 / 有断言失败（**失败不写戳**） |
| `tools\check-buildtest-stamp.ps1` | `0` / `1` / `2` | 戳与盘上构建器一致 / 改过了或从没跑过 / **读不到**（`2` 绝不当作 `0` 用） |

---

## 目录结构

```
example\pkg\                        一个可以真的跑起来的最小包
  _guard\build-pod.ps1              两阶段构建器
  _pod-src\                         包的源：入口、看门狗、指南、声明版本
    _extra\                         卫星文件：随包走，且会进清单
  _local-extensions\                本地补丁的快照
  _payload\                         载荷（这里是一个同名桩件，见 .gitignore 注释）
  _selftest\pod-failtest.ps1        失败注入测试
tools\check-buildtest-stamp.ps1     留戳闸门
tests\run-tests.ps1                 本仓库的测试套件
docs\half-built.md                  事故、量测、以及为什么这么设计
```

---

## 测试

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
```

- **保证**：`pod-failtest.ps1` 注入一次重名碰撞，断言活包逐文件哈希未变、staging 已清、`.replaced` 不存在，然后去掉碰撞再断言干净构建**确实**换入（含清单逐条重算 + zip 条目名只用 `/`）。16 条。
- **闸门**：`0 / 1 / 2` 六个分支各有一个夹具**专门把它叫响**——戳匹配、构建器被追加一个空格、删戳、删构建器、戳写成非 JSON、戳指向另一个源码树。一个从没被看见失败过的闸门只是装饰。

---

## 已知限制

- **面向 Windows / PowerShell 5.1。** 两阶段换名靠同卷 rename；跨卷会退化成拷贝，而拷贝不是原子的。编码陷阱与文件锁行为也是 Windows 特有的。
- **不做自愈看门狗。** 仓库里只有一个写了 `watch.log` 的看门狗替身——它的作用是制造那把会阻断重建的文件锁。真正的自愈是另一类东西：它会持续改文件系统，需要自己的失败模式分析。
- **zip 只在拷到别的盘/别的机器时才有意义。** 和目录躺在同一块盘上时它是纯重复：盘活着目录就在，盘死了 zip 一起没。
- **戳是机器状态，已被 .gitignore 排除。** 因此新克隆的仓库跑闸门会得到 `1`（从没测过）——这是设计，不是故障。
- **载荷裁剪。** 仓库里那个 `.tgz` 是几字节的桩件：构建器只按**文件名**选载荷，从不打开它。真实部署不要把真实 tarball 放进仓库。

---

## 贡献

两条要求：

1. **任何新的检查，都要在 `tests\run-tests.ps1` 里有一个能证明它会拦住的场景。** 一个没有失败用例的闸门无法被验证。
2. **`.ps1` / `.cmd` 保持纯 ASCII**，或者存成带 BOM 的 UTF-8。构建器的自检会拒绝把违反这条的脚本打进包里——因为在 CJK 区域设置下，PS 5.1 会把无 BOM 的脚本按 ANSI 读，一个乱码字节能吃掉**下一行代码**。

---

## License

MIT
