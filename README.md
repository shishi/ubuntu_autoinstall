# Ubuntu Autoinstall with TPM2 LUKS Encryption

このプロジェクトは、Ubuntu 24.04 LTSのautoinstallを使用して、TPM2による自動復号化を設定するためのスクリプト集です。

## 🚨 重要な警告

**TPM2設定は慎重に行ってください。手順を誤るとシステムがロックアウトされ、データにアクセスできなくなる可能性があります。**

## 📋 前提条件

- Ubuntu 24.04 LTS Desktop
- TPM 2.0対応のハードウェア
- BIOSでTPM 2.0が有効化されていること
- LUKSで暗号化されたディスク
- 初期パスワード: `ubuntuKey`

## 🔧 含まれるスクリプト

### 1. setup-tpm-encryption.sh
TPM2による自動復号化を設定するメインスクリプト

### 2. check-tpm-status.sh
TPMとLUKSの状態を確認するスクリプト

### 3. cleanup-duplicate-slots.sh
重複したキースロットを削除するスクリプト

### 4. fix-recovery-key.sh
リカバリーキーの形式を修正するスクリプト

### 5. pre-install-check.sh
autoinstall設定ファイルの検証スクリプト

## 📖 使用手順

### ステップ1: 初期インストール
```bash
# autoinstallでUbuntuをインストール
# インストール時のLUKS暗号化パスワード: ubuntuKey
```

### ステップ2: TPM2セットアップ（重要：段階的に実行）

#### 2.1 最初の実行（TPM2登録のみ）
```bash
# スクリプトに実行権限を付与
chmod +x *.sh

# TPM2を設定（一時パスワードは削除しない）
sudo ./setup-tpm-encryption.sh ubuntu

# プロンプトが表示されたら:
# "Do you want to remove the temporary password now? (y/N):" → **N を入力**
```

#### 2.2 状態確認
```bash
# TPMとLUKSの状態を確認（ユーザー名を指定して実行）
sudo ./check-tpm-status.sh ubuntu

# Security Assessmentセクションで以下を確認:
# - TPM2 protection enabled ✓
# - Key slotsの状態を確認（一時パスワードがまだ存在することを確認）

# 注意: ユーザー名を指定しない場合、リカバリーキーは"Unknown"と表示されます
```

#### 2.3 再起動してTPM2動作確認
```bash
# システムを再起動
sudo reboot

# 再起動時の動作:
# - 自動的に復号化される → TPM2が正常に動作
# - パスワードを要求される → 「ubuntuKey」を入力
```

#### 2.4 TPM2が動作した場合のみ、一時パスワードを削除
```bash
# TPM2が正常に動作した場合のみ実行
sudo ./cleanup-duplicate-slots.sh ubuntu

# 一時パスワードの削除を確認
# "Do you want to remove the temporary password? (y/N):" → y を入力
```

### ステップ3: 最終確認
```bash
# 最終的な状態を確認（ユーザー名を指定）
sudo ./check-tpm-status.sh ubuntu

# Security Assessmentセクションで理想的な状態を確認:
# - TPM2 protection enabled ✓
# - No temporary passwords found ✓

# Security Assessmentセクションで:
# - Overall Security Score: 5/5 - Excellent
```

## 🔑 リカバリーキーについて

### 保存場所
```
/home/<username>/LUKS-Recovery/recovery-key.txt
```

### 重要な注意事項
- **必ずバックアップを取ってください**
- 安全な場所（USBドライブ、パスワードマネージャー等）に保管
- TPMが故障した場合、このキーが唯一の復旧手段です

### 緊急時の使用方法
```bash
# TPMが動作しない場合の手動復号化
sudo cryptsetup luksOpen /dev/sda3 dm_crypt-main < /home/ubuntu/LUKS-Recovery/recovery-key.txt
```

## 🚨 トラブルシューティング

### ケース1: ロックアウトされた場合

1. **Ubuntuの復旧モードで起動**
2. **ライブUSBから起動**
3. **手動で復号化**:
   ```bash
   # デバイスを特定
   sudo fdisk -l
   
   # LUKSボリュームを開く（リカバリーキーがある場合）
   sudo cryptsetup luksOpen /dev/sda3 recovery < recovery-key.txt
   
   # マウント
   sudo mount /dev/mapper/recovery /mnt
   ```

### ケース2: "Operation not permitted"エラー

```bash
# リカバリーキーを修正
sudo ./fix-recovery-key.sh ubuntu

# 再度セットアップを実行
sudo ./setup-tpm-encryption.sh ubuntu
```

### ケース3: TPM2が認識されない

```bash
# TPM2モジュールを確認
sudo dmesg | grep -i tpm

# TPM2デバイスを確認
sudo systemd-cryptenroll --tpm2-device=list

# BIOSでTPM2.0が有効か確認
```

## ⚡ バリデーション

### autoinstall設定の検証
```bash
# 包括的な検証
./pre-install-check.sh autoinstall-luks.yml

# 個別検証
./validate-autoinstall-strict.py autoinstall-luks.yml
./validate-commands.py autoinstall-luks.yml
```

## 📝 設定ファイル

### autoinstall-luks.yml
LUKSで暗号化されたUbuntuをインストールするための設定ファイル
- 初期パスワード: `ubuntuKey`
- LVM構成
- 必要なパッケージの自動インストール

### /etc/crypttab
```
dm_crypt-main UUID=<your-uuid> none luks,discard,tpm2-device=auto
```
注意: `tpm2-device=auto`は警告が出ますが、正常です。

## ⚠️ セキュリティ上の注意事項

1. **物理的セキュリティ**
   - TPM2は物理アクセスからは保護しません
   - セキュアブートと組み合わせることを推奨

2. **リカバリーキーの管理**
   - 複数の安全な場所にバックアップ
   - 暗号化されたストレージに保管

3. **一時パスワードの削除タイミング**
   - TPM2が確実に動作することを確認してから削除
   - リモートアクセスのみの環境では特に注意

## 🐛 既知の問題

1. **cryptsetup警告**
   - "ignoring unknown option 'tpm2-device'"
   - これは無視して問題ありません

2. **pbkdf2トークン**
   - 直接削除できません
   - キースロットの削除と共に自動削除されます

## 📚 参考資料

- [Ubuntu Autoinstall Reference](https://canonical-subiquity.readthedocs-hosted.com/en/latest/reference/autoinstall-reference.html)
- [systemd-cryptenroll man page](https://www.freedesktop.org/software/systemd/man/systemd-cryptenroll.html)
- [Linux TPM PCR Registry](https://uapi-group.org/specifications/specs/linux_tpm_pcr_registry/)

## 🤝 貢献

問題を発見した場合は、Issueを作成してください。

## ⚖️ ライセンス

MIT License