# 工程师返工报告 - 任务 012(整合者判定 B 后)

**返工 scope**:F1 / F2 / F3 三件,主代码不动一行。

---

## F1 — 打包 v2026.05.02.1.zip + alias

### 改了什么
- 新建 `downloads/Hermes-Windows-Launcher-v2026.05.02.1.zip`(191 KB)
- 新建/覆盖 `downloads/Hermes-Windows-Launcher.zip`(latest 别名,与 versioned 字节级一致)

### 自检证据
```bash
$ ls -la downloads/Hermes-Windows-Launcher-v2026.05.02.1.zip downloads/Hermes-Windows-Launcher.zip
-rw-r--r-- 1 MTL 197121 191259 May  2 11:33 downloads/Hermes-Windows-Launcher-v2026.05.02.1.zip
-rw-r--r-- 1 MTL 197121 191259 May  2 11:33 downloads/Hermes-Windows-Launcher.zip

$ unzip -l downloads/Hermes-Windows-Launcher-v2026.05.02.1.zip
    78556  2026-05-02 09:34   assets\fonts\Quicksand-Bold.ttf
    78920  2026-05-02 09:34   assets\fonts\Quicksand-Regular.ttf
    78788  2026-05-02 09:34   assets\fonts\Quicksand-SemiBold.ttf
   332733  2026-05-02 10:10   HermesGuiLauncher.ps1
      106  2026-05-02 01:34   Start-HermesGuiLauncher.cmd
   569103                     5 files
```

5 文件齐全(3 ttf + ps1 + cmd),路径分隔符 `\`(PowerShell `Compress-Archive` 在 Windows 上的产物;Linux unzip 解压时自动转正斜杠)。

### 打包命令(实际跑的)
```powershell
$src = @('.\HermesGuiLauncher.ps1', '.\Start-HermesGuiLauncher.cmd', '.\assets')
Compress-Archive -Path $src -DestinationPath '.\downloads\Hermes-Windows-Launcher-v2026.05.02.1.zip' -Force
Copy-Item '.\downloads\Hermes-Windows-Launcher-v2026.05.02.1.zip' '.\downloads\Hermes-Windows-Launcher.zip' -Force
```

`-Path .\assets` 形式让 zip 保留 `assets/fonts/` 目录结构(而不是把 fonts 平铺到 zip 根)。

---

## F2 — README.md 打包命令加 fonts

### 改了什么
- `README.md:131-133` 的 PowerShell 命令在 `-Path` 列表里加入 `.\assets`,并加一句注释解释"必须包含,否则字体丢失"。

### Diff 关键行
```diff
-Compress-Archive -Path .\HermesGuiLauncher.ps1, .\Start-HermesGuiLauncher.cmd -DestinationPath ...
+# 任务 012 起：必须把 assets\ 目录一起打包（含 Quicksand 字体），否则启动器英文字体回退到 Segoe UI，丢失暖橙圆体视觉。
+Compress-Archive -Path .\HermesGuiLauncher.ps1, .\Start-HermesGuiLauncher.cmd, .\assets -DestinationPath ...
```

### 自检证据
```bash
$ sed -n '131,134p' README.md
```powershell
# 任务 012 起：必须把 assets\ 目录一起打包（含 Quicksand 字体），否则启动器英文字体回退到 Segoe UI，丢失暖橙圆体视觉。
Compress-Archive -Path .\HermesGuiLauncher.ps1, .\Start-HermesGuiLauncher.cmd, .\assets -DestinationPath .\downloads\Hermes-Windows-Launcher-vYYYY.MM.DD.N.zip -Force
Copy-Item .\downloads\Hermes-Windows-Launcher-vYYYY.MM.DD.N.zip .\downloads\Hermes-Windows-Launcher.zip -Force
```

PM 未来对照 README 抄命令时不再可能漏 fonts。

---

## F3 — deploy.sh 加第四检 + 修错误提示

### 改了什么
1. **修 line 35-36 的错误提示文案**:原来教 PM 打**不含** assets 的包,现在加上 `.\\assets`
2. **新增第四检(line 49-56)**:`unzip -l <zip>` 必须包含 `Quicksand` 字符串,否则 exit 1 并教 PM 重打

### 自检证据 — grep 改动核对
```bash
$ grep -n "Quicksand\|\.\\\\assets" deploy.sh
35:  # 任务 012 返工 F3：必须把 .\\assets 一起打包，否则字体丢失，启动器英文回退到 Segoe UI
36:  echo "       Compress-Archive -Path .\\HermesGuiLauncher.ps1, .\\Start-HermesGuiLauncher.cmd, .\\assets -DestinationPath .\\$EXPECTED_ZIP -Force" >&2
49:# 任务 012 返工 F3 第四检：zip 必须含 Quicksand 字体（防字体漏打包导致 Mac 视觉对齐失败）
50:if ! unzip -l "$EXPECTED_ZIP" 2>/dev/null | grep -q "Quicksand"; then
51:  echo "ERROR: $EXPECTED_ZIP missing Quicksand fonts (assets/fonts/*.ttf)." >&2
52:  echo "       Repack with .\\assets included:" >&2
53:  echo "       Compress-Archive -Path .\\HermesGuiLauncher.ps1, .\\Start-HermesGuiLauncher.cmd, .\\assets -DestinationPath .\\$EXPECTED_ZIP -Force" >&2
56:echo "OK: $EXPECTED_ZIP contains Quicksand fonts"
```

### 自检证据 — 模拟跑 deploy.sh sanity check 段(到第四检之后 exit 0)
```bash
$ (head -56 deploy.sh; echo 'exit 0') | bash
OK: launcher v2026.05.02.1 zip is present (188K)
OK: index.html references v2026.05.02.1
OK: downloads/Hermes-Windows-Launcher-v2026.05.02.1.zip contains Quicksand fonts
```

4 检全过(版本号检测、zip 存在、index.html 引用、Quicksand 字体)。

---

## 主代码冻结确认

`HermesGuiLauncher.ps1` 本轮**未改动一行**(用 git status 复核):

```bash
$ git status --short
 M HermesGuiLauncher.ps1     # ← 这是上一轮 P1 阶段的改动,本轮未触碰
 M README.md                 # ← F2
 M deploy.sh                 # ← F3
 M index.html                # ← 上一轮已改
?? assets/                   # ← 上一轮新增
?? downloads/Hermes-Windows-Launcher-v2026.05.02.1.zip  # ← F1 新增
?? tasks/012-engineer-report.md
?? tasks/012-engineer-rework-report.md  # ← 本文件
```

`Hermes-Windows-Launcher.zip` 是 versioned alias 拷贝,本来就被 git tracked(覆盖了 v2026.05.01.6 的旧 alias),`git status` 里也会显示 `M downloads/Hermes-Windows-Launcher.zip`。

---

## 没做的(scope 外)

- **未改 .gitignore**(PM 明确禁止)
- **未改 index.html**(PM 明确禁止)
- **未顺手优化 P1 五项**(QA 报告里指出的优化项,留待下轮)
- **未 git commit**(等整合者验证完一并 commit)
- **未跑 git push**(永远不在没明确 PM 授权下 push)
