# OCTOP ARM64 飞牛 fnOS 安装包（非官方构建）

为 **ARM64（aarch64）** 飞牛 NAS 构建的 [OCTOP](https://github.com/TencentCloud/Octop) 原生安装包（`.fpk`）。

> ⚠️ **本项目不是腾讯官方项目。** OCTOP 由 [TencentCloud OrcaKit](https://github.com/TencentCloud/Octop) 开发，本项目只是**重新打包**，使其能在 ARM64 设备上运行。所有代码版权归原作者，遵循 MIT 许可（见 [LICENSE](LICENSE) 与 [NOTICE](NOTICE)）。

---

## 使用方法

### 1. 下载

到本仓库的 [Releases](../../releases) 页面下载：

```
Octop-fnos-native-arm64-1.0.1.fpk
```

### 2. 安装

1. 把 `.fpk` 文件放到飞牛 NAS 的任意目录（如个人空间 `/vol1/1000/`）
2. 打开飞牛网页界面 → **应用中心** → **手动安装**
3. 选择该文件，按向导设置管理员账号密码

> 安装会自动关联 `python312` 组件；若未安装会一并装上。

### 3. 访问

```
http://<NAS_IP>:8089
```

登录凭据见安装向导；也可在应用中心 → OCTOP → **设置**窗口中查看，或读取数据目录下的 `octop-login.txt`。

---

## 已知限制

| 限制 | 说明 |
|---|---|
| **仅 ARM64（aarch64）** | manifest 声明 `platform = arm`，x86_64 设备不会看到此包 |
| **无桌面控制功能** | `evdev` 无 aarch64 构建产物，已排除；该功能用于远程控制桌面（鼠标键盘），**无头 NAS 上无实际影响**，且 OCTOP 是惰性导入它，不影响启动 |
| **安装较慢** | 包约 194 MB，解压需写入约 2 GB，在 eMMC 存储的 NAS 上可能耗时几分钟 |
| **内存占用** | OCTOP 常驻约 400–500 MB。若 NAS 总内存 ≤2 GB，建议参考下方「内存提示」 |

### 内存提示

在内存较小的 NAS 上（如 1.9 GB），fnOS 自身服务已占用约 800 MB，加上 OCTOP 容易触发交换抖动，导致整机卡顿。建议增加磁盘 swap：

```bash
# 在数据卷上创建 4GB swap（需 root）
sudo fallocate -l 4G /vol1/swapfile
sudo chmod 600 /vol1/swapfile
sudo mkswap /vol1/swapfile
sudo swapon /vol1/swapfile
echo '/vol1/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

---

## 自行构建

### 前置条件

- Linux x86_64 或 WSL（**不需要** ARM 设备，交叉安装）
- `bash` / `curl` / `python3` / `git`
- 网络可访问 PyPI 与 GitHub

### 构建

```bash
git clone https://github.com/<你的用户名>/octop-native-arm64.git
cd octop-native-arm64

# 构建指定版本（默认 1.0.1）
OCTOP_VERSION=1.0.1 ./build.sh
```

产物：`dist/Octop-fnos-native-arm64-<version>.fpk`

### 构建脚本做了什么

1. 克隆上游 OCTOP 仓库（获取 `fnos/native` 包模板与打包脚本）
2. 下载对应版本的 `octop` wheel
3. **构建 3 个无预编译 wheel 的依赖**（见下）
4. **交叉安装全部依赖到 aarch64**（关键步骤）
5. 按上游 CI 要求固定 `mcp` / `langchain-mcp-adapters` 版本
6. 修正 manifest：`platform = all` → `platform = arm`
7. 调用飞牛官方 `fnpack` 打包

### 关键技术点

**① 交叉安装（核心修复）**

```bash
uv pip install \
  --python-platform aarch64-unknown-linux-gnu \
  --python-version 3.12 \
  --target fnos/native/app/site-packages \
  --only-binary :all: \
  octop-<ver>-py3-none-any.whl
```

`--only-binary :all:` 确保**不会**在 x86 上编译出错误架构的产物。

**② 三个依赖没有可用的 aarch64 wheel**

| 包 | 情况 | 处理 |
|---|---|---|
| `oss2` | 仅源码包，**纯 Python** | 在 x86 上构建 wheel（产物 `py3-none-any`，架构无关） |
| `esdk-obs-python` | 仅源码包，**纯 Python** | 同上 |
| `crcmod` | 仅源码包，**含 C 扩展**（但自带纯 Python 回退实现） | 用 `CC=/bin/false` 触发其自带的回退构建 |

**③ 排除 `evdev`**

`evdev` 是 C 扩展且无 aarch64 构建产物，仅被 `pynput` 用于桌面控制功能。构建时将其从依赖列表中剔除（OCTOP 惰性导入该功能，不影响启动）。

**④ 必须按 ELF 内容判断架构，不能按文件名**

```python
# 判断 ELF 架构（偏移 18 处的 2 字节）
machine = struct.unpack_from("<H", open(path, "rb").read(20), 18)[0]
# 0xB7 = AArch64, 0x3E = x86-64
```

> 许多扩展文件名**不含架构标记**（如 `_ffi.abi3.so`、`_rust.abi3.so`），按文件名匹配会漏检。

**⑤ `platform` 字段的合法值**

飞牛 `fnpack` 校验时明确要求：

```
x86 | arm | loongarch | risc-v | all
```

ARM64 应填 **`arm`**（不是 `aarch64`）。

---

## 反馈

- OCTOP 本身的问题（功能、BUG）→ [上游仓库](https://github.com/TencentCloud/Octop/issues)
- 本打包项目的问题（构建失败、ARM 兼容性）→ 本仓库 Issues

---

## 许可

MIT，源自 [TencentCloud/Octop](https://github.com/TencentCloud/Octop)。
详见 [LICENSE](LICENSE) 与 [NOTICE](NOTICE)。
