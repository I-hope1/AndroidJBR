# 构建说明（BUILD）

本文记录 AndroidJBR 的完整构建链路。`scripts/` 里的脚本就是本文的可执行版本；
两者的差别只在路径（脚本用 `$WORK` 覆盖）。

> 原构建环境：**Ubuntu 24.04 aarch64、2 vCPU / 11 GB、无 root**（JBR 21）。
> `make images` 约 1 小时；`tar.xz` 约 30 MB、解压约 140 MB。
> JBR 25 的构建流程相同，但**尚未在本项目里端到端跑过**。

## 1. 选择 JBR line

`scripts/env.sh` 用 `JBR_LINE` 选择源码 pin、boot JDK 和补丁目录：

| JBR_LINE | branch @ pin | boot JDK | 补丁目录 | 状态 |
|---|---|---|---|---|
| `21`（默认） | `jbr21` @ `015db36d` | Temurin 21.0.13+9 | `patches/jbr21/` | 已构建 + 真机验证 |
| `25` | `jbr25` @ `1b5d5af9` | Temurin 25.0.5+8 | `patches/jbr25/` | 已构建成功（2026-11-14）；真机未验证 |

```bash
./scripts/build.sh            # JBR 21
./scripts/build.sh --jbr 25   # JBR 25
JBR_LINE=25 ./scripts/check-patch.sh
```

每个 line 有独立的源码树（`$WORK/JetBrainsRuntime-<line>`）和日志，可以并存；
NDK/freetype/elf-cleaner 等工具链组件共享。

## 2. 组件与版本

| 组件 | 版本 / 固定点 | 用途 |
|---|---|---|
| JetBrainsRuntime | `jbr21` @ `015db36d…`（21.0.11）或 `jbr25` @ `1b5d5af9…` | 源码 |
| bionic 移植基线（JBR 21） | `PojavLauncherTeam/android-openjdk-build-multiarch` @ `f3936fb`：`patches/jre_21/android/jdk21u_android.diff` + `26_skip_proc_net6_check.diff` | 手解 6 个冲突后并入补丁 |
| bionic 移植基线（JBR 25） | `AngelAuraMC/angelauramc-openjdk-build`（`fcl/BUILD_JRE_25`）`patches/jdk25u_android.diff`，sha256 `c9aa3e95…` | 手解 4 个冲突后并入补丁 |
| NDK | r27c（`android-ndk-r27c-linux.zip`） | **只用 sysroot / 头文件 / clang resource dir** |
| 交叉编译器 | 宿主 clang-18 + lld-18 + LLVM 18 binutils | 真正的编译器 |
| Boot/Build JDK | Temurin 21.0.13+9（JBR 21）/ Temurin 25.0.5+8（JBR 25），宿主架构 | 编译期 javac/jlink |
| freetype | 2.10.0（交叉编译） | AWT 字体 |
| CUPS | 2.2.4 源码（只用头文件） | `--with-cups-include` |
| termux-elf-cleaner | `f9273bc` | 产物 ELF 的 API 21 清理 |

## 3. 主机依赖

### 3.1 有 root（推荐）

```bash
sudo apt-get update
sudo apt-get install -y \
  build-essential make autoconf m4 zip unzip file \
  clang-18 lld-18 llvm-18 libclang-18-dev \
  cmake git curl xz-utils \
  libfontconfig1-dev libx11-dev libxext-dev libxrender-dev \
  libxrandr-dev libxi-dev libxtst-dev libxt-dev
```

后两组 `-dev` 包只提供**头文件**：NDK r27c 的 sysroot 里没有
`fontconfig/fontconfig.h` 和 `X11/*`，而 java.desktop（headless 的
`libfontmanager`/`libawt`）和 JBR 21 的 configure 需要它们。`fetch-deps.sh` 会把
这些头目录拷进 `$ANDROID_SYSROOT/usr/include`，因此 **glibc 的其它头不会被带进
bionic 构建**。

`clang-18` 提供 `/usr/bin/clang-18`、`/usr/bin/llvm-ar`、`/usr/lib/llvm-18/lib`，
即 `scripts/env.sh` 默认的 `LLVM_ROOT=/usr`。

### 3.2 无 root：解包 .deb（原构建设备的做法）

原环境没有 sudo，做法是 `apt-get download` + `dpkg -x` 到用户目录，然后把
`LLVM_ROOT` 指过去：

```bash
mkdir -p work/pkgs work/llvm && cd work/pkgs
apt-get download clang-18 libclang-common-18-dev libclang-cpp18 libclang1-18 \
  libllvm18 lld-18 llvm-18 llvm-18-linker-tools autoconf m4
for d in *.deb; do dpkg -x "$d" ../llvm; done
cd ../..

# 让 LLVM_ROOT 指向解包前缀（含 bin/clang-18 与 lib/llvm-18/lib）
LLVM_ROOT=$PWD/work/llvm/usr ./scripts/setup-toolchain.sh
```

若 clang 运行时报找不到 `libLLVM-18.so.1`，`scripts/lib.sh` 生成的包装器已经
把 `$LLVM_LIB` 加进 `LD_LIBRARY_PATH`；手工调用时同样需要：

```bash
export LD_LIBRARY_PATH=$LLVM_ROOT/lib/llvm-18/lib:$LD_LIBRARY_PATH
```

> 原设备另外解包了 `libx11-dev`、`libfontconfig1-dev`、`libstdc++-13-dev` 等，
> 并把 fontconfig/X11 头目录拷进了 NDK sysroot——这正是现在 `fetch-deps.sh`
> 自动做的步骤（见 3.1）；没有这些头，java.desktop 和 JBR 21 的 configure 会失败。

## 4. 工具链原理（最容易踩坑的部分）

### 4.1 为什么用宿主 clang-18 而不是 NDK 的 clang

Android NDK 不提供 linux-aarch64 宿主版编译器（只发 linux-x86_64）。但本构建
只需要 NDK 的 **sysroot（bionic 头文件 + 各架构 .so）** 和 **clang resource
dir（compiler-rt / libc++ 归档）**，二者与宿主架构无关。

因此：

- `NDK_PREBUILT=.../toolchains/llvm/prebuilt/linux-x86_64` —— 在 aarch64 宿主上
  也照样可用，**不是笔误**；
- 实际编译器是宿主的 `clang-18`，用 `--target=aarch64-linux-android21` 交叉。

### 4.2 clang 包装器

OpenJDK 的 `configure` 要按 gcc 家族识别工具链（构建文件里到处是
`-fno-var-tracking-assignments` 这类 gcc 参数），所以 `setup-toolchain.sh`
生成两个包装器，`configure` 把它们当成 gcc：

```bash
# 关键内容（scripts/lib.sh: write_clang_wrapper）
clang-18 --target=aarch64-linux-android21 \
         --sysroot=<NDK sysroot> \
         -resource-dir=<NDK>/toolchains/llvm/prebuilt/linux-x86_64/lib/clang/18 \
         --rtlib=compiler-rt -fuse-ld=lld \
         -Wno-unknown-warning-option "${@/-fno-var-tracking-assignments/}"
```

几个必须的细节：

| 细节 | 原因 |
|---|---|
| `--version` 伪装成 `gcc (GCC) 4.9` | 让 configure 的 `CLAIMED_TOOLCHAIN_VERSION` 判断通过 |
| 过滤 `-fno-var-tracking-assignments` | clang 不认这个 gcc 专属参数 |
| C++ 链接时追加 `-lunwind` | NDK 静态 `libc++abi.a` 引用 LLVM unwinder，且必须排在归档之后 |
| `--rtlib=compiler-rt` + `-fuse-ld=lld` | bionic 目标的标准组合；用 GNU ld 会失败 |
| `scope`/版本探测通过 | configure 的 `--with-toolchain-type=gcc` 只是分类，不实际调用 gcc |

### 4.3 dummy_libs

bionic 没有 `libpthread.so`/`librt.so`/`libthread_db.so`（都并进 libc），但
OpenJDK 的链接命令会显式 `-lpthread -lrt -lthread_db`。`scripts/02` 在
`$JBR_SRC/dummy_libs/` 生成三个空归档（内容就是 `!<arch>\n`），configure 通过
`--with-extra-ldflags=-L$JBR_SRC/dummy_libs` 把它们排在系统库之前，链接即可成功。

## 5. Configure

`scripts/03-configure.sh` 执行的参数（与产物 `spec.gmk` 的
`CONFIGURE_COMMAND_LINE` 一致，路径用变量表示）：

```bash
ANDROID_BUILD=1 \
CC=$WRAP_CC CXX=$WRAP_CXX \
AR=$HOST_AR RANLIB=$HOST_RANLIB OBJCOPY=$HOST_OBJCOPY STRIP=$HOST_STRIP \
bash configure \
  --openjdk-target=aarch64-linux-android \
  --with-boot-jdk=$BOOT_JDK \
  --with-build-jdk=$BOOT_JDK \
  --with-toolchain-type=gcc \
  --with-devkit=$NDK_PREBUILT \
  --with-extra-cflags="-DLE_STANDALONE -O3 -DANDROID \
      -Wno-error=implicit-function-declaration -Wno-error=int-conversion" \
  --with-extra-cxxflags="<同上>" \
  --with-extra-ldflags="-L$JBR_SRC/dummy_libs -Wl,--undefined-version" \
  --disable-warnings-as-errors \
  --enable-option-checking=fatal \
  --enable-headless-only=yes \
  --with-jvm-variants=server \
  --with-jvm-features=-dtrace,-zero,-vm-structs,-epsilongc,-zgc,-shenandoahgc,-jvmci \
  --with-native-debug-symbols=external \
  --with-debug-level=release \
  --with-freetype-include=$FREETYPE_PREFIX/include/freetype2 \
  --with-freetype-lib=$FREETYPE_PREFIX/lib \
  --with-cups-include=$CUPS_SRC \
  --with-fontconfig-include=$ANDROID_SYSROOT/usr/include \
  --x-includes=$ANDROID_SYSROOT/usr/include/X11 \
  --x-libraries=/usr/lib
```

参数分组说明：

| 组 | 说明 |
|---|---|
| `--openjdk-target` / `--with-devkit` / `--with-toolchain-type=gcc` | 目标平台是 `aarch64-linux-android`；`TARGET_OS` 最终仍解析为 `linux`（`platform.m4` 的 android 分支故意排在 `*linux*` 之后，整个 port 都建立在 `isTargetOs linux` 之上） |
| `ANDROID_BUILD=1` | **必须导出**：`libraries.m4` 靠它跳过 ALSA/DBus 探测，否则 configure 会尝试链宿主 ALSA |
| `--enable-headless-only=yes` | 无 X11 AWT 后端；Minecraft 场景足够，补丁另放开 `libfontmanager_xawt.so` |
| `--with-jvm-variants=server` | C1+C2；DCEVM 需要 |
| `--with-jvm-features=-dtrace,...` | 去掉 dtrace/zero/vm-structs/epsilongc/zgc/shenandoahgc/jvmci：bionic 交叉环境下要么不可用，要么不需要 |
| `--with-extra-ldflags=...-Wl,--undefined-version` | 配合 NDK lld 与 dummy_libs |
| `--with-fontconfig-include`/`--x-includes` | 都指向 NDK sysroot；**不要**指向宿主 `/usr/include`，否则会把 glibc 头带进来 |
| `--with-freetype-*` | 必须用交叉编译出来的 freetype（`file` 显示 ARM aarch64），宿主 freetype 会链接失败 |

> JBR 25 实测（2026-11-14，aarch64 / 2 vCPU，`make images` 1423 秒）：上面这组 flag
> 可用，但需要三处 line 专属调整，脚本已处理：
>
> 1. **`make JOBS=N`**：JDK 25 的构建系统拒绝 `make -jN`（报 `'make -jN' is not supported`）；
> 2. **显式 `--build=<host config.guess>`**：端口补丁让 `TARGET_OS` 保持 `linux`，JDK 25
>    因此把 Android 目标当成 native 编译，adlc 等 build tool 被编成 bionic 二进制
>    （`cannot execute: required file not found`）。传 `--build` 后 `COMPILE_TYPE=cross`，
>    build tool 用宿主编译器（`BUILD_CC`）；
> 3. **`PRECOMPILED_HEADERS=disabled`**：JDK 25 的 PCH 依赖 gcc 式 `.gch` 查找，clang
>    需要头文件与 `.gch` 同目录，直接开 PCH 会报 `precompiled.hpp file not found`。
>
> 另外 JDK 25 的 `dictionary.hpp` 只前向声明 `InstanceKlass`，JBR 的 DCEVM 内联函数
> `old_if_redefining()` 在类内定义会编译失败；补丁已改为在 `dictionary.cpp` 里
> out-of-line 定义。

configure 成功后产物目录固定为：

```
$JBR_SRC/build/linux-aarch64-server-release/
```

（由 `TARGET_JDK=aarch64`、`JVM_VARIANTS=server`、`DEBUG_LEVEL=release` 决定。）

## 6. 构建

```bash
cd $JBR_SRC
make images JOBS=2        # scripts/04-build.sh
```

- 2 vCPU 约 1 小时；`JOBS` 建议不超过 `min(nproc, 内存GB/4)`。
- 全程用 boot JDK 作 `--with-build-jdk`，跳过 `buildjdk`（PCH 打开），这是时间可控的关键。
- 失败时先看 `$JBR_SRC/build/linux-aarch64-server-release/build.log` 的最后一个
  `Error`；`scripts/04-build.sh` 会把日志落到 `$WORK/build.log` 并打印尾部。

产物：`build/linux-aarch64-server-release/images/jdk/`。

## 7. 打包（jlink → Pojav 可导入的 JRE）

`scripts/05-package-jre.sh` 的步骤：

1. 复制 `images/jdk` 到暂存目录，并把交叉编译的 `libfreetype.so` 放进 `lib/`；
2. 用 **宿主 boot JDK 的 jlink**（JRE 的 jmods 是平台无关的）按
   `scripts/pojav-modules.txt` 的模块清单生成运行时：
   `--no-man-pages --no-header-files --release-info --compress=0
    --strip-native-debug-symbols=exclude-debuginfo-files:objcopy=llvm-objcopy`；
3. 覆盖 Pojav 的 `jre_override/lib`（fontconfig/fonts/dummy `libawt_xawt.so`）；
4. `llvm-strip --strip-unneeded` 所有 `.so`；
5. `termux-elf-cleaner --api-level 21`：去掉 API 21 不接受的 `DT_RPATH`、
   `GNU_HASH`、`VERDEF`、`VERNEED`；
6. 断言 `release` 含 `JAVA_VERSION`/`OS_ARCH`（Pojav 的 MultiRTUtils 依赖）；
7. 生成 `tar.xz` 与 `SHA256SUMS.txt`。

模块清单来自 Pojav 的 jlink 列表（去掉 `jvmci`；`java.desktop` 保留供字体/AWT
类加载，但实现是 headless）。

## 8. 产物校验

```bash
file out/jre*-jbr-android-arm64-*.tar.xz      # 存在
tar -xJf out/jre...tar.xz -C /tmp/jre && file /tmp/jre/lib/server/libjvm.so
# -> ELF 64-bit LSB shared object, ARM aarch64

readelf -n /tmp/jre/lib/server/libjvm.so | grep -A2 Android
# -> Android ABI: 21, NDK version: 27

readelf -d /tmp/jre/lib/server/libjvm.so | grep NEEDED
# -> 仅 libm.so / libdl.so / libc.so（libc++/libunwind 已静态链接）

strings /tmp/jre/lib/server/libjvm.so | grep -c AllowEnhancedClassRedefinition   # >0
grep -E '^(JAVA_VERSION|OS_ARCH)=' /tmp/jre/release
# -> JAVA_VERSION="21.0.11"  OS_ARCH="aarch64"
```

`scripts/05-package-jre.sh` 会自动做上述关键断言。

## 9. 常见问题

**Q: `git apply --check` 报 hunk 冲突（`patch does not apply`）。**
JBR pin 与补丁必须成对存在。检查 `JBR_PIN` 是否被改动；先用
`./scripts/check-patch.sh` 复现，再按 `patches/README.md` 重新生成补丁。
不要用 `git apply --3way` 掩盖冲突——冲突点通常意味着 JBR 上游改了相关代码。

**Q: `01-clone-jbr.sh` 之后补丁说文件不存在。**
说明拿到的是 sparse/部分检出（本项目 CI 的 sparse 校验流程是特例）。正常构建
必须是完整检出；`01-clone-jbr.sh` 末尾会检查 `java.desktop`/`make/modules` 是否
存在，缺失会直接报错。

**Q: configure 报找不到 ALSA / DBus / X11。**
确认 `ANDROID_BUILD=1` 已导出，且 `--x-includes`、`--with-fontconfig-include`
指向 NDK sysroot 而不是宿主路径。

**Q: 链接报 `wrong ELF class` 或 `file` 显示 x86-64。**
某个依赖（最常见是 freetype）是宿主架构构建的。删掉 `$FREETYPE_PREFIX` 重跑
`setup-toolchain.sh`；`setup-toolchain.sh` 的 C/C++ 冒烟测试也会提前暴露这个
问题。

**Q: 在 Ubuntu 上 `apt-get install llvm-18` 后报 `llvm-ar not found`？**
Ubuntu 的 `llvm-18` 包只安装带版本号的二进制（`llvm-ar-18`、`llvm-strip-18`…），
无版本号的名字来自 `update-alternatives`，CI 镜像上通常没启用。`scripts/lib.sh`
会自动解析 `-22`…`-17` 后缀版本（也支持 PATH 里的无版本名），所以
`LLVM_ROOT=/usr` 直接可用；无需手工设 `HOST_AR`。

**Q: configure 找不到 clang / `libLLVM-18.so.1`。**
`LLVM_ROOT` 指向的前缀里需要有 `bin/clang-18`、`bin/llvm-ar`（无 root 解包场景
还要 `lib/llvm-18/lib`）。看 `scripts/env.sh` 的 `LLVM_*` 变量。

**Q: 能否用 x86_64 主机构建？**
工具链设计与宿主架构无关（NDK sysroot + 宿主 clang），`fetch-deps.sh` 会按
`uname -m` 选 Temurin 的 x64 资产。`.github/workflows/build-hosted.yml` 就是
在 GitHub 托管的 ubuntu-24.04（x86_64）上跑完整构建；`build-full.yml` 保留
自托管 arm64 的路径。实测 JBR 25 全程 **18 分钟**（4 vCPU，含依赖下载），依赖走
`actions/cache`；x86_64 宿主不需要删任何预装组件（runner 有 100+ GB 可用）。

x86_64 宿主和 aarch64 宿主有两处行为差异，脚本都已处理：

- 宿主 GNU binutils（`/usr/bin/objcopy` 等）只能处理 x86 ELF，必须用 LLVM 的
  多目标版本；JDK 25 会忽略环境变量里的 `AR/STRIP/OBJCOPY`，所以要作为
  configure 命令行变量传入（`03-configure.sh` 两者都传）；
- NDK sysroot 缺 fontconfig / X11 头，`fetch-deps.sh` 会把宿主发行版的
  `fontconfig/`、`X11/` 头目录拷进 sysroot。

**Q: 无 root 环境用解包的 autoconf，configure 报找不到 autom4te / m4sugar？**
deb 解包的 autoconf 内部路径仍指向 `/usr/share/autoconf`、`/usr/bin/autom4te`。
需要显式重定向（原构建环境就是这样做的）：

```bash
export AUTOM4TE=/path/to/usr/bin/autom4te
export M4=/path/to/usr/bin/m4
export autom4te_perllibdir=/path/to/usr/share/autoconf
export AC_MACRODIR=/path/to/usr/share/autoconf
export trailer_m4=/path/to/usr/share/autoconf/autoconf/trailer.m4
# autom4te.cfg 里写死了 /usr/share/autoconf，复制一份并 sed 成实际前缀
sed 's#/usr/share/autoconf#/path/to/usr/share/autoconf#g' \
  /path/to/usr/share/autoconf/autom4te.cfg > /tmp/autom4te.cfg
export AUTOM4TE_CFG=/tmp/autom4te.cfg
```

**Q: JBR 25 构建时 PCH 相关报错？**
`PRECOMPILED_HEADERS=disabled ./scripts/build.sh --jbr 25`（25 轨道默认就是 disabled）。

**Q: `--jbr 25` 构建失败/找不到文件怎么办？**
JBR 25 目前只做到补丁级验证。若失败，先确认 `./scripts/check-patch.sh`（带
`JBR_LINE=25`）通过，再看 `$WORK/build-jbr25.log`；构建系统差异属于已知风险，
见 README「支持矩阵」。

**Q: 两个 line 会互相覆盖吗？**
不会：源码树、build 目录、日志、产物名都带 line/版本（`$WORK/JetBrainsRuntime-<line>`、
`$WORK/build-jbr<line>.log`、`jre<21|25>-...`）。共享的只有 NDK/freetype/elf-cleaner。

**Q: CI 为什么只校验补丁？**
完整构建需要 ~1 小时 + 数 GB 磁盘 + NDK/boot JDK，不适合 GitHub 托管 runner。
`.github/workflows/ci.yml` 只做补丁应用校验（5 秒级）；完整构建放在
`.github/workflows/build-full.yml`，用 `workflow_dispatch` 在自托管 arm64
runner 上跑，产物作为 artifact 上传。
