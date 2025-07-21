# Ubuntu 24.04 自動インストール with TPM2暗号化 & Nix

このプロジェクトは、Ubuntu 24.04 ServerをTPM2ベースのディスク暗号化とNixパッケージマネージャーを含む構成で自動インストールするための設定を提供します。

## 📋 主な機能

- **TPM2による自動ディスク解除** - 起動時にパスワード入力不要
- **LVM on LUKS暗号化** - ディスク全体を暗号化
- **Nixパッケージマネージャー** - 宣言的パッケージ管理
- **セキュリティ強化** - TPM2互換性チェック、詳細なエラーメッセージ
- **リカバリーキー自動生成** - 緊急時のアクセス確保
- **自動リトライ機能** - ネットワーク障害時の復元力
- **動的スワップサイズ推奨** - ディスクサイズに基づく最適化提案

## 🚀 クイックスタート

### 方法1: GitHubから直接取得（最も簡単）

#### インストーラーのプロンプトで入力

Ubuntu のインストール中に、autoinstall設定の場所を尋ねられたら、以下のURLを入力：

```
https://raw.githubusercontent.com/shishi/ubuntu_autoinstall/main/autoinstall.yml
```

### 方法2: インタラクティブインストーラーでの入力

Ubuntu 24.04のインストーラーでは、以下のタイミングでautoinstall設定を指定できます：

1. **言語選択後の画面**で、`Tab`キーまたは`F6`キーを押す
2. **「Enter an autoinstall config location」**のプロンプトが表示される
3. 以下のいずれかを入力：
   - GitHubのraw URL: `https://raw.githubusercontent.com/shishi/ubuntu_autoinstall/main/autoinstall.yml`

### 方法3: USBメディアへの配置

#### 1. インストールメディアの準備

```bash
# このリポジトリをクローン
git clone https://github.com/StudistCorporation/ubuntu_setup.git
cd ubuntu_setup

# Ubuntu 24.04 Server ISOをダウンロード
wget https://releases.ubuntu.com/24.04/ubuntu-24.04-live-server-amd64.iso

# USBメディアに書き込み（例：/dev/sdX）
sudo dd if=ubuntu-24.04-live-server-amd64.iso of=/dev/sdX bs=4M status=progress
```

#### 2. autoinstall設定の配置

USBメディアをマウントして設定ファイルを配置：

```bash
# USBをマウント
sudo mkdir -p /mnt/usb
sudo mount /dev/sdX1 /mnt/usb

# autoinstall設定をコピー
sudo mkdir -p /mnt/usb/autoinstall
sudo cp autoinstall.yml /mnt/usb/autoinstall/

# アンマウント
sudo umount /mnt/usb
```

### 3. インストール実行

1. **UEFI/BIOSでTPM2を有効化**
2. **セキュアブートを有効化**（推奨）
3. **USBから起動**
4. **GRUBメニューで自動インストールを選択**：
   ```
   Install Ubuntu Server (autoinstall)
   ```
5. **ホスト名、ユーザー名、パスワードを入力**
6. **インストール完了を待つ**（約10-15分）

## 🔧 詳細な機能説明

### ディスク構成

```
/dev/sda
├── /dev/sda1 (1GB)   - EFI System Partition
├── /dev/sda2 (2GB)   - /boot (暗号化されない)
└── /dev/sda3 (残り)  - LUKS暗号化パーティション
    └── ubuntu-vg (LVM)
        ├── root (90%) - / (ルートファイルシステム)
        └── swap (10%) - スワップ領域
```

### TPM2暗号化の仕組み

1. **PCR (Platform Configuration Register) 使用**
   - PCR 0: UEFI ファームウェア測定値
   - PCR 7: セキュアブート状態
   
   ※ PCR 0+7のみを使用することで、日常的な設定変更による再登録を最小限に抑えています

2. **自動解除の条件**
   - ハードウェア構成が変更されていない
   - セキュアブート設定が変更されていない
   - TPM2が有効で正常動作している

### セキュリティ機能

1. **強化されたTPM2サポート**
   - インストール前のTPM2互換性チェック
   - TPM 1.2との区別
   - TPM非対応環境での安全なフォールバック

2. **改善されたエラーハンドリング**
   - 詳細なトラブルシューティング手順
   - ネットワーク障害時の自動リトライ（最大3回）
   - 各エラーに対する具体的な解決方法の提示

3. **進捗表示**
   - 初回起動時のセットアップ進捗表示
   - すべてのユーザーへの通知（wall コマンド）
   - タイムアウト時間の延長（600秒）

## 🔐 暗号化ディスクの復旧方法

### ⚠️ 重要: リカバリーキーのバックアップ

**LUKS暗号化を使用する場合（step10以降）、インストール後すぐにリカバリーキーをバックアップしてください。**

#### リカバリーキーの場所
```bash
# step10設定使用時（ユーザーのホームディレクトリ内）
ls ~/LUKS-Recovery/recovery-key.txt

# または既存の場所を検索
find /home -name "recovery-key.txt" -path "*/LUKS-Recovery/*" 2>/dev/null
```

#### バックアップ方法

1. **USBドライブへのコピー**（推奨）
   ```bash
   # USBドライブを挿入してから実行
   cp ~/LUKS-Recovery/recovery-key.txt /media/$USER/USB_NAME/luks-recovery-$(hostname)-$(date +%Y%m%d).txt
   ```

2. **パスワードマネージャーへの保存**
   - キーの内容をコピーしてパスワードマネージャーに保存
   - コンピュータ名と日付を明記

3. **印刷して保管**
   - キーを印刷して安全な場所に保管
   - コンピュータとは別の場所に保管

#### なぜ重要か

- **このキーがないと、パスワードを忘れた場合にデータを復旧できません**
- BIOSアップデートやハードウェア変更後にTPM2自動解除が失敗する可能性があります
- キーは唯一のデータ復旧手段です

#### 初期パスワード

デフォルトのLUKSパスワード: 
- step9まで: `TemporaryInsecurePassword2024!`
- step10以降: `temporaryPassword!`

**注意**: step10設定では、TPM登録成功後に自動的に削除されます。

### 復旧が必要な状況

1. **TPM2エラー**
   - UEFI/BIOSアップデート後
   - マザーボード交換後
   - セキュアブート設定変更後

2. **ハードウェア変更**
   - 別のPCへのディスク移動
   - TPMチップの故障

### 復旧手順

#### 方法1: 起動時の手動解除

```bash
# initramfsプロンプトが表示されたら
cryptsetup open /dev/disk/by-partlabel/partition-luks luks-root
# リカバリーキーを入力
exit
```

#### 方法2: Live USBからの修復

```bash
# Ubuntu Live USBで起動

# 1. 暗号化ディスクを解除
sudo cryptsetup open /dev/sda3 luks-root
# リカバリーキーを入力

# 2. システムをマウント
sudo mount /dev/mapper/ubuntu--vg-root /mnt
sudo mount /dev/sda2 /mnt/boot
sudo mount /dev/sda1 /mnt/boot/efi

# 3. chroot環境で修復
sudo mount --bind /dev /mnt/dev
sudo mount --bind /proc /mnt/proc
sudo mount --bind /sys /mnt/sys
sudo chroot /mnt

# 4. TPM2を再登録
systemd-cryptenroll --wipe-slot=tpm2 /dev/disk/by-partlabel/partition-luks
systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7 /dev/disk/by-partlabel/partition-luks

# 5. 再起動
exit
sudo umount -R /mnt
sudo reboot
```

## 📦 Nixパッケージマネージャー

### 基本的な使い方

```bash
# パッケージ検索
nix search nixpkgs firefox

# パッケージインストール
nix profile install nixpkgs#firefox

# インストール済みパッケージの一覧
nix profile list

# パッケージの更新
nix profile upgrade '.*'

# 特定のパッケージを更新
nix profile upgrade firefox

# 手動でガベージコレクション
nix store gc --max 30d
```

### 開発環境の使い方

```bash
# 一時的な開発環境 (このシェルをとじるまで有効な環境を作成できる)
nix shell nixpkgs#python3 nixpkgs#python3Packages.pip nixpkgs#python3Packages.requests
nix shell nixpkgs#nodejs_20 nixpkgs#yarn nixpkgs#nodePackages.typescript
nix shell nixpkgs#go nixpkgs#rustc nixpkgs#cargo
```

### 初回ログイン時の注意

初回起動時に以下のセットアップが自動実行されます：

1. **進捗表示**
   ```
   [1/3] Starting first boot setup...
   [2/3] Enrolling TPM2 for disk encryption...
   [3/3] Installing Nix package manager...
   ```

2. **所要時間**
   - TPM2登録: 約30秒
   - Nixインストール: 約2-3分（ネットワーク速度による）

3. **ログの確認**
   ```bash
   # セットアップの進捗を確認
   sudo journalctl -u first-boot-setup -f
   ```

インストール完了後、一度ログアウトして再ログインすることで、Nixコマンドが使用可能になります。

## 🛠️ トラブルシューティング

### TPM2自動解除が機能しない

1. **TPM2の状態確認**
   ```bash
   sudo systemd-cryptenroll /dev/disk/by-partlabel/partition-luks
   ```

2. **TPM2の再登録**
   ```bash
   sudo systemd-cryptenroll --wipe-slot=tpm2 /dev/disk/by-partlabel/partition-luks
   sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7 /dev/disk/by-partlabel/partition-luks
   ```

3. **TPM2が利用できない場合**
   ```bash
   # TPM2の状態を確認
   sudo tpm2_getcap properties-fixed | grep TPM2_PT_FAMILY_INDICATOR
   
   # TPMデバイスの確認
   ls -la /dev/tpm*
   ```

### Nixコマンドが見つからない

```bash
# 手動でパスを通す
source /etc/profile.d/nix.sh

# または再ログイン
exit
```

### ディスクサイズの推奨事項

システムは自動的にディスクサイズに基づくスワップサイズの推奨を行います：

```bash
# 推奨事項の確認（初回起動後）
cat /root/swap-recommendation.txt
```

推奨スワップサイズ：
- 32GB未満のディスク: 4GB
- 32-128GBのディスク: 8GB
- 128-512GBのディスク: 16GB
- 512GB以上のディスク: 32GB

## 📄 設定のカスタマイズ

### autoinstall.ymlの主要セクション

1. **storage** - ディスクパーティション設定
2. **packages** - インストールするパッケージ
3. **write_files** - 作成するファイルとスクリプト
4. **runcmd** - 初回起動時に実行するコマンド
5. **late-commands** - インストール完了直前のコマンド

### カスタマイズ例

#### パーティションサイズの変更

```yaml
# root: 80%, swap: 20%に変更
- id: lv-root
  type: lvm_volgroup
  name: root
  size: 80%
  
- id: lv-swap
  type: lvm_volgroup
  name: swap
  size: 20%
```

#### 追加パッケージのインストール (Ubuntuのapt)

```yaml
packages:
  - vim
  - htop
  - your-package-here
```

## 🔍 検証ツール

設定の妥当性を確認：

```bash
python3 validate-autoinstall.py
```

## 📝 ライセンス

MIT License - 詳細は[LICENSE](LICENSE)ファイルを参照してください。

## 🤝 貢献

Issues、Pull Requestsは歓迎します。大きな変更を行う場合は、事前にIssueで議論してください。

## ⚠️ 注意事項

- **TPM2について**
  - TPM 2.0が必要です（TPM 1.2は非対応）
  - TPM非対応環境では、パスワードベースの起動になります
  - BIOSでTPMが無効になっていないか確認してください

- **LUKS暗号化パスワード**
  - 初期パスワード: `TemporaryInsecurePassword2024!`
  - インストール後すぐに変更してください
  - TPM2登録後も、このパスワードは緊急時のために残ります

- **リカバリーキー**
  - **必ず安全な場所にバックアップしてください**
  - 場所: `~/LUKS-Recovery/recovery-key.txt` (インストール時に作成したユーザーのホームディレクトリ内)
  - このキーがないとデータ復旧が不可能になります

## LUKS Recovery Key Regeneration

リカバリーキーを再生成する必要がある場合（紛失や漏洩の場合）：

```bash
# このリポジトリのスクリプトを使用
sudo ./scripts/regenerate-luks-recovery-key.sh
```

### 手動でのリカバリーキー再生成

```bash
# 1. LUKSデバイスを確認
sudo blkid -t TYPE="crypto_LUKS" -o device

# 2. 新しいリカバリーキーを生成
openssl rand -base64 48 > ~/new-recovery-key.txt

# 3. 新しいキーを追加（既存のキー/パスワードが必要）
sudo cryptsetup luksAddKey /dev/[your-luks-device] ~/new-recovery-key.txt

# 4. 新しいキーをテスト
sudo cryptsetup luksOpen --test-passphrase --key-file ~/new-recovery-key.txt /dev/[your-luks-device]

# 5. 古いリカバリーキーを削除
sudo cryptsetup luksRemoveKey /dev/[your-luks-device]
# (古いリカバリーキーを入力)

# 6. 新しいキーを適切な場所に移動
mv ~/new-recovery-key.txt ~/LUKS-Recovery/recovery-key.txt
chmod 600 ~/LUKS-Recovery/recovery-key.txt

# 7. キースロットを確認
sudo cryptsetup luksDump /dev/[your-luks-device]
```

## TPM Enrollment Failed

### 症状
ログイン時に以下の警告が表示される場合：
```
WARNING: TPM ENROLLMENT FAILED!
Your disk encryption is currently using a TEMPORARY PASSWORD.
```

### 原因と対処法

#### 1. 状態確認
```bash
sudo tpm-status
```

#### 2. TPMサービスの状態確認

**基本的な確認コマンド**
```bash
# カスタムTPM状態確認（推奨）
sudo tpm-status

# systemdサービスの状態
sudo systemctl status tpm-enroll.service

# サービスの詳細ログ
sudo journalctl -u tpm-enroll.service -b

# リアルタイムログ監視
sudo journalctl -u tpm-enroll.service -f
```

**ハードウェアレベルの確認**
```bash
# TPMデバイスの存在確認
ls -la /dev/tpm*

# TPM2チップの詳細情報
sudo tpm2_getcap properties-fixed

# TPM2が利用可能か確認
sudo systemd-cryptenroll --tpm2-device=list
```

**LUKS暗号化の状態確認**
```bash
# LUKSデバイスを特定
LUKS_DEV=$(sudo blkid -t TYPE="crypto_LUKS" -o device | head -n 1)

# TPM2トークンの確認
sudo cryptsetup luksDump "$LUKS_DEV" | grep -A10 "Tokens:"

# 使用中のキースロット
sudo cryptsetup luksDump "$LUKS_DEV" | grep "Key Slot"
```

**状態ファイルの確認**
```bash
# TPM登録状態
ls -la /var/lib/tpm-luks/

# 登録日時
cat /var/lib/tpm-luks/enrolled-date

# 失敗情報
cat /var/lib/tpm-luks/failed

# ログファイル
tail -50 /var/log/tpm-luks/enrollment.log
```

**起動時の動作確認**
```bash
# TPM関連のカーネルメッセージ
sudo dmesg | grep -i tpm

# 暗号化デバイスのアンロック状態
sudo systemctl list-units --type=device | grep crypt

# crypttab設定
sudo cat /etc/crypttab
```

**包括的な状態確認スクリプト**
```bash
# すべての状態を一度に確認
cat << 'EOF' > /tmp/check-tpm-all.sh
#!/bin/bash
echo "=== TPM Service Status ==="
sudo systemctl status tpm-enroll.service --no-pager

echo -e "\n=== TPM State Files ==="
ls -la /var/lib/tpm-luks/

echo -e "\n=== Recent TPM Logs ==="
sudo tail -20 /var/log/tpm-luks/enrollment.log 2>/dev/null || echo "No logs found"

echo -e "\n=== LUKS TPM Tokens ==="
LUKS_DEV=$(sudo blkid -t TYPE="crypto_LUKS" -o device | head -n 1)
[ -n "$LUKS_DEV" ] && sudo cryptsetup luksDump "$LUKS_DEV" | grep -A10 "Tokens:" || echo "No LUKS device found"

echo -e "\n=== TPM Hardware Status ==="
sudo tpm2_getcap properties-fixed | head -20 || echo "TPM2 tools not available"
EOF

chmod +x /tmp/check-tpm-all.sh
/tmp/check-tpm-all.sh
```

#### 3. よくある原因と解決方法

**A. TPMがBIOSで無効になっている**
1. PCを再起動してBIOS/UEFI設定に入る
2. "Security"または"TPM"セクションを探す
3. TPM 2.0を有効化（TPM 1.2ではダメ）
4. 保存して再起動

**B. セキュアブートの問題**
- BIOSでセキュアブートを有効化、または
- 異なるPCRで再登録：
```bash
sudo systemd-cryptenroll --wipe-slot=tpm2 $(blkid -t TYPE="crypto_LUKS" -o device | head -1)
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 $(blkid -t TYPE="crypto_LUKS" -o device | head -1)
```

**C. 手動で再試行**
```bash
sudo tpm-enroll
```

#### 3. 重要な警告
⚠️ **TPM登録が完了するまで、ディスクは一時パスワード `temporaryPassword!` で保護されています。これはセキュリティリスクです！**

#### 4. 問題解決後
```bash
# 警告を削除
sudo rm /etc/tpm-enrollment-warning

# 状態を再確認
sudo tpm-status
```

#### 5. それでも解決しない場合

**TPMが利用できない環境の場合**：
1. リカバリーキーでの運用を継続
2. 一時パスワードを強力なものに変更：
```bash
sudo cryptsetup luksChangeKey $(blkid -t TYPE="crypto_LUKS" -o device | head -1)
# 現在のパスワード: temporaryPassword!
# 新しい強力なパスワードを設定
```

**ハードウェアの問題**：
- TPM 2.0チップが搭載されていない
- TPMチップの故障
- 仮想マシンでTPMパススルーが設定されていない

## 🔗 関連リンク

- [Ubuntu Autoinstall Documentation](https://ubuntu.com/server/docs/install/autoinstall)
- [systemd-cryptenroll Manual](https://www.freedesktop.org/software/systemd/man/systemd-cryptenroll.html)
- [Nix Package Manager](https://nixos.org/)
