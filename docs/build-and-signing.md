# 构建与固定签名证书

本项目的 App 和虚拟麦克风驱动都包含可执行代码，构建脚本会分别签名。固定签名身份主要用于保持 App 跨版本的身份，避免输入监控、辅助功能的旧授权因代码哈希变化而失效；驱动本身不申请这两项权限。

| 构建方式 | 签名来源 | 是否需要发布私钥 |
| --- | --- | --- |
| 普通本地构建 | 默认 ad-hoc 签名 | 不需要 |
| PR 构建 | 默认 ad-hoc 签名 | 不需要，也不读取发布 Secrets |
| main 自动发布 | 固定自签名证书 | 需要配置本仓库的两个签名 Secrets |

其他人可以直接从源码构建，无需获得本项目的发布私钥。维护自己的连续发布版本时，应生成并长期复用自己的证书。本项目的公开证书只能用于校验身份，不能代替私钥进行签名。

## 普通本地构建

需要 macOS、完整 Xcode、Swift 6.2 或更新版本、Python 3。命令在项目根目录执行；Xcode 路径按实际安装位置调整。

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build --disable-keychain
swift test --disable-keychain
scripts/build-app.sh
scripts/build-driver.sh
```

输出为 `dist/Remote Buddy.app` 和 `dist/RemoteBuddyMic.driver`。`BUILD_ARCH=arm64` 或 `BUILD_ARCH=x86_64` 可指定架构，默认使用本机架构。若没有设置 `CODE_SIGN_IDENTITY`，两个 bundle 都使用 ad-hoc 签名，不会因缺少 GitHub Secrets 而阻止本地构建。

不要把直接运行 `.build` 中的可执行文件、`dist` 中的 App 和安装到 `/Applications` 的 App 混作同一份权限验收。ad-hoc 构建的代码哈希会变化，替换 App 后可能需要重新授予权限。

### 本地连续真机调试：复用固定身份

维护者已经保存本项目固定签名身份时，可以使用：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  python3 scripts/build-local-signed.py
```

此入口默认读取仓库外的 `~/Library/Application Support/RemoteBuddySigning/`
中的 `release-signing.p12` 和 `password.txt`，也可以用 `--identity-directory` 指定
已有备份目录。不会生成新证书；证书必须与仓库公开证书一致。它复用现有签名
辅助脚本导入临时 Keychain，构建并验证 App、驱动与驱动安装包，然后恢复
Keychain 搜索列表并清理临时身份，不修改证书信任设置。

默认构建调试版，`--configuration release` 可生成优化版。普通本地构建和 PR
仍默认使用 ad-hoc；此入口必须显式执行。缺少身份或校验失败时停止，不回退。
私钥与密码不会传入编译、打包子进程，也不会进入仓库、产物或日志。

连续测试固定运行 `dist/Remote Buddy.app`。首次从 ad-hoc 切换到固定身份
需要重新授权；后续仍应实际验证同一证书下的版本升级是否保留系统权限。

固定签名身份不等于具备 Apple Team ID。验证 Sparkle 的 PKG 更新流程时，必须通过一体安装包安装到 `/Applications`，让安装脚本保留 `Autoupdate` 助手的 root 归属；直接运行或手动复制普通用户所有的本地 App，会在 Sparkle 启动安装器前失败。已处于此状态的 App 需要手动安装一次修复后的一体安装包，单纯重试应用内更新不能修复当前助手的归属。

## 为自己的发布生成证书：只运行一次

以下脚本只生成文件，不调用 Keychain 或证书信任工具。使用 macOS 自带的 `/usr/bin/openssl`，其 PKCS#12 导出格式可由 macOS Keychain 导入。输出保存在仓库外、仅当前用户可访问的目录；目录已存在时会停止，防止覆盖正在使用的身份。

```bash
python3 - <<'PY'
import os
from pathlib import Path
import secrets
import subprocess

backup = Path.home() / 'Library/Application Support/RemoteBuddySigning'
backup.mkdir(mode=0o700, parents=True, exist_ok=False)
password = backup / 'password.txt'
password.write_text(secrets.token_hex(32) + '\n')
password.chmod(0o600)
config = backup / 'certificate.cnf'
config.write_text('''[req]
prompt = no
distinguished_name = subject
x509_extensions = extensions
[subject]
CN = Remote Buddy Release Signing
[extensions]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
''')
openssl = '/usr/bin/openssl'
subprocess.run([
    openssl, 'req', '-new', '-x509', '-newkey', 'rsa:3072', '-sha256',
    '-days', '3650', '-config', str(config),
    '-keyout', str(backup / 'private-key.pem'),
    '-out', str(backup / 'certificate.pem'), '-passout', 'file:' + str(password),
], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
subprocess.run([
    openssl, 'pkcs12', '-export', '-inkey', str(backup / 'private-key.pem'),
    '-in', str(backup / 'certificate.pem'), '-name', 'Remote Buddy Release Signing',
    '-out', str(backup / 'release-signing.p12'),
    '-passin', 'file:' + str(password), '-passout', 'stdin',
], input=password.read_bytes(), check=True,
   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
for file in backup.iterdir():
    os.chmod(file, 0o600)
print('Signing identity generated; no Keychain or certificate trust settings changed.')
PY
```

文件用途：

- `certificate.pem`：公开证书，可提交到自己的仓库。
- `private-key.pem`：加密的私钥，不可提交。
- `release-signing.p12`：包含证书和私钥的加密身份包，不可提交。
- `password.txt`：私钥和身份包的密码，不可提交或输出到日志。

将身份包和密码安全备份到受控的备份或密码管理系统。不要每次构建重新生成证书；同一个证书名称并不意味着同一个身份，证书指纹和对应私钥必须保持不变。

## 配置自己的 GitHub 仓库

下面的仓库名必须替换成自己的 fork。不要把自己的签名身份上传到上游仓库。

先用自己的公开证书替换 fork 中的签名校验基准，提交的只有公开证书：

```bash
cp "$HOME/Library/Application Support/RemoteBuddySigning/certificate.pem" \
   scripts/signing/release-certificate.pem
chmod 644 scripts/signing/release-certificate.pem
/usr/bin/openssl x509 -in scripts/signing/release-certificate.pem \
    -noout -subject -dates -fingerprint -sha1
```

公开 PEM 文件本身就是签名校验基准，脚本每次从它计算指纹。在自己的 fork 中替换证书时，也应同步更新 `docs/releases.md` 中展示的指纹和有效期；不要只改文档中的指纹。

使用已登录的 GitHub CLI 上传两个 Secrets。下例通过标准输入传递内容，不在命令参数或输出中显示私钥与密码；不要开启 shell 的 `set -x`。

```bash
signing_repository=your-account/remote-buddy
python3 - "$signing_repository" <<'PY'
import base64
from pathlib import Path
import subprocess
import sys

backup = Path.home() / 'Library/Application Support/RemoteBuddySigning'
values = {
    'MACOS_SIGNING_P12_BASE64': base64.b64encode((backup / 'release-signing.p12').read_bytes()),
    'MACOS_SIGNING_P12_PASSWORD': (backup / 'password.txt').read_bytes().strip(),
}
for name, value in values.items():
    result = subprocess.run(['gh', 'secret', 'set', name, '--repo', sys.argv[1]],
                            input=value, capture_output=True)
    if result.returncode:
        raise SystemExit('Failed to configure repository secret: ' + name)
    print('Configured: ' + name)
PY
gh secret list --repo "$signing_repository"
```

Base64 只是编码，保密依赖 GitHub Secrets。公开证书与 Secrets 中的证书不匹配、密码错误、缺少任一 Secret，都会阻止 main 发布，不能静默回退到 ad-hoc。

完整发布还需要独立的 Sparkle 密钥、更新源和网站配置，见 [releases.md](releases.md)。App 证书不代替 `SPARKLE_PRIVATE_KEY`，自行发布也不能使用本项目的 Sparkle 私钥。安装包不会因为使用自签名证书就获得 Developer ID 签名或 Apple 公证。

## CI 如何使用证书

`.github/workflows/release.yml` 仅在 main 的 push 构建中调用 `release-signing-keychain.py setup`，过程如下：

1. 校验 PKCS#12 中的证书与仓库公开证书一致。
2. 在 runner 创建临时 Keychain，导入身份并允许 `codesign` 使用私钥。
3. 临时加入 Keychain 搜索列表，供 `codesign` 查找签名身份并构建证书链；即使指定 `--keychain`，搜索列表仍会参与。设置 `CODE_SIGN_IDENTITY` 和 `CODE_SIGN_KEYCHAIN`。
4. 分别为 App、驱动签名；验证固定的 Bundle ID 与证书指纹身份规则。
5. setup 结束时立即删除导入用的身份包，并通过 `always()` 尝试恢复搜索列表、删除临时 Keychain。清理失败只记录不含敏感信息的警告，不阻断已经完成的构建；保留清理状态供重试，临时材料最终随 runner 回收。

setup 会拒绝再次初始化已有活动状态，保留原 Keychain 和已写入 `GITHUB_ENV` 的变量，不重复追加。若先前失败尚未创建身份，则允许重用空目录重新尝试。

此流程不调用 `add-trusted-cert` 或修改任何证书信任设置，也不要求用户安装或信任根证书。不要为解决签名查找失败去修改系统信任链。

本地构建若已有可用签名身份，可设置 `CODE_SIGN_IDENTITY` 和 `CODE_SIGN_KEYCHAIN` 使用它；构建脚本本身不会导入或信任证书。无需固定身份的本地构建，使用默认 ad-hoc 即可。

## 验证与排错

`security import` 没有通过标准输入传入导出密码的选项，因此调用 `security import ... -P <password>` 时，密码会短暂出现在该进程的命令行参数中。此 workflow 使用每个 job 独立的临时 GitHub-hosted runner，脚本刻意不打印命令参数或工具输出，以限制暴露范围。不要开启 `set -x`、输出完整进程参数或把含密码的命令复制到日志；不能据此认为可以安全打印参数。其他 `security` 子命令使用的临时 Keychain 密码也按同样原则处理。

构建产物可直接检查：

```bash
codesign --verify --deep --strict 'dist/Remote Buddy.app'
codesign --verify --deep --strict dist/RemoteBuddyMic.driver
codesign --display -r- 'dist/Remote Buddy.app'
codesign --display -r- dist/RemoteBuddyMic.driver
```

固定自签名产物的 designated requirement 应包含各自的 Bundle ID 和 `certificate leaf = H"证书指纹"`，而不是只有 `cdhash`。固定身份构建完成后，执行 `python3 scripts/verify-release-signing.py` 可检查两个产物是否使用仓库固定的身份，验证不需要私钥或签名 Keychain；普通 ad-hoc 构建不应通过这个生产身份检查。

- 缺少 Secrets：核对目标仓库的 `gh secret list`，以及是否在 main 的 push 发布中运行。
- `openssl failed`：检查 PKCS#12 内容、导出密码和文件格式；不要打印 Secret 排查。
- 证书不匹配：核对仓库的公开证书和备份身份包，不能只按证书名称判断。
- `codesign` 找不到身份：检查临时 Keychain 是否已解锁、已加入 runner 搜索列表，以及两个 `CODE_SIGN_*` 变量是否正确；这不是要求信任证书。
- 权限列表有 App 但授权不生效：确认运行的是当前安装副本，并检查实际系统权限。首次改用新的签名身份可能需要重新授权；之后仍需真机验证版本 A → 版本 B 的升级路径。

签名与构建检查不等于驱动加载和权限保留验收。真实验收应安装发布包，检查虚拟麦克风可用、遥控器按键和语音输入正常，再使用同一证书签名的下一版升级复测。
