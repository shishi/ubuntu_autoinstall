# Ubuntu TPM2 LUKS Auto-unlock Scripts (systemd-cryptenroll版)

このドキュメントは、Ubuntu 24.04 LTSで**systemd-cryptenroll**を使用してTPM2を利用したLUKS暗号化ディスクの自動復号を設定するためのスクリプトについて説明します。

## 概要

これらのスクリプトは、TPM2（Trusted Platform Module 2.0）チップを使用して、起動時にLUKS暗号化ディスクを自動的にアンロックする機能を提供します。systemd-cryptenrollを使用し、セキュアブート状態などのPCR（Platform Configuration Register）値に基づいて復号キーを保護します。

## clevis版との違い

### 主な違い
- **フレームワーク**: Clevisの代わりにsystemd-cryptenrollを使用
- **統合性**: systemdに完全統合されており、追加サービスが不要
- **要件**: systemd 248以上が必要（Ubuntu 22.04以降）
- **設定**: `/etc/crypttab`に`tpm2-device=auto`の追加が必要

### 機能の違い
- **スロットテスト**: systemd-cryptenrollは個別スロットのテストができない
- **メタデータ**: LUKS2ヘッダーに`systemd-tpm2`トークンとして保存
- **削除方法**: `--wipe-slot=tpm2`オプションを使用

## パスワード・認証方法の種類

このセットアップで使用される認証方法の一覧：

### 1. **ubuntuKey（インストールパスワード）**
- **用途**: Ubuntu autoinstallでの初期設定
- **いつ使う**: 初回のTPMセットアップ時のみ
- **推奨**: セットアップ後は削除

### 2. **ユーザーパスワード**
- **用途**: 日常的な手動復号用
- **いつ使う**: TPMが使えない時（BIOS更新後など）
- **特徴**: ユーザーが覚えやすい8文字以上のパスワード

### 3. **リカバリーキー**
- **用途**: 緊急時のアクセス用
- **いつ使う**: パスワードを忘れた時、別PCでディスクを読む時
- **特徴**: 自動生成される64文字のランダム文字列（URL-safe Base64）
- **保管場所**: `/root/.luks-recovery-key-*.txt`

### 4. **TPM2自動アンロック**
- **用途**: 通常起動時の自動復号
- **いつ使う**: 毎回の起動時（自動）
- **特徴**: パスワード入力不要、PCR7（セキュアブート）で保護

## 前提条件

- Ubuntu 24.04 LTS（`autoinstall-luks.yml`でインストール済み）
- systemd 248以上（Ubuntu 22.04以降に含まれる）
- TPM2チップが搭載されたハードウェア
- LUKS2暗号化されたディスク（LUKS1は非対応）
- root権限

## スクリプト一覧

### 1. `setup-tpm-luks-unlock_systemd.sh` - TPM自動アンロック設定スクリプト

このスクリプトは、systemd-cryptenrollを使用してTPM2によるLUKSの自動復号を設定します。

**機能：**
- systemdバージョンの確認（248以上）
- 必要なパッケージの自動インストール
- TPM2デバイスの可用性チェック
- LUKS暗号化デバイスの自動検出
- 新しいパスワードとリカバリーキーの生成
- TPM2へのLUKSキーの登録（systemd-cryptenroll使用）
- インストール時のパスワードの削除（オプション）
- initramfsの自動更新

**使用方法：**
```bash
sudo ./setup-tpm-luks-unlock_systemd.sh
```

**実行時の動作：**
1. systemdバージョンとTPM2の可用性を確認
2. 必要なパッケージをインストール
3. LUKS暗号化デバイスを検出（複数ある場合は選択）
4. 新しいパスワードの入力を求める
5. ランダムなリカバリーキーを生成
6. 現在のLUKSパスワードを使用してTPM2に登録
7. 新しいパスワードとリカバリーキーを追加
8. 古いインストールパスワードを削除（確認後）

**systemd-cryptenrollの使用例：**
```bash
# TPM2への登録（内部で実行される）
systemd-cryptenroll /dev/sda3 --tpm2-device=auto --tpm2-pcrs=7 --tpm2-with-pin=no

# 既存のTPM2登録を削除
systemd-cryptenroll /dev/sda3 --wipe-slot=tpm2

# 登録状況の確認
systemd-cryptenroll /dev/sda3 --tpm2-device=list
```

### 2. `tpm-status_systemd.sh` - TPM状態表示・デバッグスクリプト

このスクリプトは、TPM2とLUKSの状態に関する詳細情報を表示します。

**機能：**
- TPM2デバイスの検出と状態表示
- TPM2の機能とプロパティ表示
- PCR値の表示（セキュアブート状態など）
- systemd-cryptenroll登録の状態確認
- LUKSデバイス情報とTPM2トークンの表示
- ブート設定の確認
- 簡易診断機能

**使用方法：**
```bash
# フルレポート
sudo ./tpm-status_systemd.sh

# 特定の情報のみ表示
sudo ./tpm-status_systemd.sh tpm      # TPMデバイスと機能
sudo ./tpm-status_systemd.sh pcr      # PCR値
sudo ./tpm-status_systemd.sh luks     # LUKSデバイス情報
sudo ./tpm-status_systemd.sh systemd  # systemd-cryptenroll状態
sudo ./tpm-status_systemd.sh boot     # ブート設定
sudo ./tpm-status_systemd.sh diag     # 簡易診断
```

### 3. `cleanup-tpm-slots_systemd.sh` - 重複TPMスロット削除スクリプト

このスクリプトは、LUKSデバイスから重複したTPM2登録を安全に削除します。

**機能：**
- 全LUKSデバイスの自動スキャン
- TPM2トークンの自動検出
- 最新の登録を保持（最高スロット番号）
- 重複登録の安全な削除
- ドライラン機能

**使用方法：**
```bash
# 全デバイスをクリーンアップ（対話式）
sudo ./cleanup-tpm-slots_systemd.sh

# ドライラン（変更なし）
sudo ./cleanup-tpm-slots_systemd.sh --dry-run

# 特定デバイスのクリーンアップ
sudo ./cleanup-tpm-slots_systemd.sh /dev/nvme0n1p3
```

**注意：** systemd-cryptenrollではスロットの個別テストができないため、最新の登録（最高スロット番号）を保持する方式を採用しています。

### 4. `check-tpm-health_systemd.sh` - TPMヘルスチェックスクリプト

システム更新前後にTPM自動復号の状態を確認するスクリプトです。

**機能：**
- 更新前のPCR値バックアップ
- 更新後のPCR値比較
- TPM2登録状態の確認
- crypttab設定の確認
- リカバリーキーのリマインダー

**使用方法：**
```bash
# システム更新前
sudo ./check-tpm-health_systemd.sh pre

# システム更新後
sudo ./check-tpm-health_systemd.sh post

# 両方を実行
sudo ./check-tpm-health_systemd.sh
```

### 5. `test-idempotency_systemd.sh` - 冪等性テストスクリプト

セットアップスクリプトの冪等性（複数回実行しても安全）を確認するためのヘルパースクリプトです。

## LUKSキースロットの確認と管理

### systemd-cryptenrollでの確認方法

**TPM2登録の確認：**
```bash
# systemd-cryptenrollで確認
sudo systemd-cryptenroll /dev/sda3 --tpm2-device=list

# cryptsetup luksDumpで詳細確認
sudo cryptsetup luksDump /dev/sda3
```

**LUKS2ヘッダーの構造（systemd-tpm2使用時）：**
```
Keyslots:
  0: luks2      # 通常のパスワードスロット
  1: luks2      # 通常のパスワードスロット
  2: luks2      # TPM2用スロット
  ...
Tokens:
  0: systemd-recovery
      Keyslot: 1
  1: systemd-tpm2
      Keyslot: 2   # TPM2トークンがスロット2を使用
```

**不要なキースロット（ubuntuKeyなど）の削除方法：**

手動でのスロット削除：
```bash
# 特定のスロットを削除（例：スロット0）
sudo cryptsetup luksKillSlot /dev/sda3 0
# 現在有効なパスワードの入力が必要です
```

## /etc/crypttabの設定

systemd-cryptenrollを使用する場合、`/etc/crypttab`の設定が必要です：

```bash
# /etc/crypttabの例
dm_crypt-0 UUID=your-uuid-here none luks,discard,tpm2-device=auto
```

**重要：** `tpm2-device=auto`オプションを追加する必要があります。

## Ubuntu 24.04での既知の問題と対処

### initramfs-tools警告について

Ubuntu 24.04でsystemd-cryptenrollを使用すると、`update-initramfs`実行時に以下の警告が表示されることがあります：

```
W: initramfs-tools configuration sets MODULES=dep but crypttab contains systemd-tpm2 requirements
```

**この警告は無害です。理由：**

1. **機能への影響なし**: TPM2による自動復号は正常に動作します
2. **単なる設定の不整合**: initramfs-toolsがsystemd-cryptenrollの新機能に完全対応していないだけ
3. **initramfsは正しく生成**: 警告は出ますが、必要なモジュールは含まれます
4. **将来のアップデートで解消予定**: Ubuntu/Debianの既知の問題（Bug #1969375）

**証拠となるソース：**
- [Ubuntu Bug #1969375](https://bugs.launchpad.net/bugs/1969375) - systemd-cryptenrollのTPM2サポートに関する公式バグレポート
- 多数のユーザーが同じ警告を報告しているが、実際の動作には影響がないことが確認されている
- systemdとinitramfs-toolsの統合が進行中で、将来のバージョンで改善される予定

**対処法（オプション）：**
警告を消したい場合のみ：
```bash
# /etc/initramfs-tools/conf.d/cryptroot を作成
echo "MODULES=most" | sudo tee /etc/initramfs-tools/conf.d/cryptroot
```

ただし、これによりinitramfsのサイズが増加するため、通常は推奨されません。

## セキュリティに関する考慮事項

1. **PCR選択**
   - PCR 7（セキュアブート状態）がデフォルト
   - より強固なセキュリティには PCR 0,1,4,7 を使用
   - PCR 8,9 は頻繁に変更されるため避ける

2. **リカバリーキー**
   - 生成されたリカバリーキーは安全な場所に保管
   - ファイルからコピー後、元のファイルを削除
   - 最低2つの認証方法を維持

3. **制限事項**
   - TPM2バインディングはオフライン攻撃からのみ保護
   - 物理アクセスを持つ攻撃者からは保護されない
   - カーネル更新後も、PCR7使用なら再登録は不要

## リカバリーキーが必要になる状況

### 日常的に起こりうる状況

1. **セキュアブート設定の変更**
   - BIOSでセキュアブートを有効/無効にした時
   - PCR 7が変更されるため

2. **BIOS/UEFIファームウェア更新**
   - メーカーからのBIOSアップデート適用後
   - TPMがクリアされる場合がある

3. **ブートローダーの大規模更新**
   - GRUBのメジャーアップデート時（まれ）
   - 通常の`apt upgrade`では問題なし

4. **ハードウェア変更**
   - マザーボード交換（修理時など）
   - 別のPCへのディスク移動

### カーネル更新について

**通常のカーネル更新は問題ありません**：
- PCR 7（セキュアブート）を使用しているため安全
- PCR 8,9（カーネル/initrd）は使用していない
- 日常の`apt update && apt upgrade`は影響なし

## トラブルシューティング

### TPM2が検出されない
```bash
# TPMモジュールの確認
lsmod | grep tpm

# TPMデバイスの確認
ls -la /dev/tpm*

# BIOS/UEFIでTPMが有効になっているか確認
```

### 自動アンロックが機能しない
```bash
# crypttabの確認
grep tpm2-device /etc/crypttab

# initramfsの再生成
sudo update-initramfs -u -k all

# デバッグ情報の確認
sudo ./tpm-status_systemd.sh diag
```

### TPM2登録の再実行
```bash
# 既存の登録を削除
sudo systemd-cryptenroll /dev/nvme0n1p3 --wipe-slot=tpm2

# 再登録
sudo systemd-cryptenroll /dev/nvme0n1p3 --tpm2-device=auto --tpm2-pcrs=7
```

## clevis版からの移行

既にclevis版を使用している場合の移行手順：

1. **現在の状態を確認**
   ```bash
   sudo clevis luks list -d /dev/sda3
   ```

2. **clevisバインディングを削除**
   ```bash
   sudo clevis luks unbind -d /dev/sda3 -s [slot番号]
   ```

3. **systemd-cryptenrollで再登録**
   ```bash
   sudo ./setup-tpm-luks-unlock_systemd.sh
   ```

4. **crypttabを更新**
   ```bash
   # tpm2-device=auto を追加
   sudo nano /etc/crypttab
   ```

## 注意事項

- すべてのスクリプトはroot権限で実行する必要があります
- LUKS2フォーマットが必要です（LUKS1は非対応）
- systemd 248以上が必要です（Ubuntu 22.04以降）
- リカバリーキーは必ず安全な場所に保管してください
- initramfs更新時の警告は無視して構いません

## ライセンス

これらのスクリプトはMITライセンスで提供されています。