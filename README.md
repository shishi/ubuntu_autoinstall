# Ubuntu TPM2 LUKS Auto-unlock Scripts

このリポジトリには、Ubuntu 24.04 LTSでTPM2を使用してLUKS暗号化ディスクの自動復号を設定するためのスクリプトが含まれています。

## 概要

これらのスクリプトは、TPM2（Trusted Platform Module 2.0）チップを使用して、起動時にLUKS暗号化ディスクを自動的にアンロックする機能を提供します。Clevisフレームワークを使用し、セキュアブート状態などのPCR（Platform Configuration Register）値に基づいて復号キーを保護します。

## 前提条件

- Ubuntu 24.04 LTS（`autoinstall-luks.yml`でインストール済み）
- TPM2チップが搭載されたハードウェア
- LUKS暗号化されたディスク
- root権限

## スクリプト一覧

### 1. `setup-tpm-luks-unlock.sh` - TPM自動アンロック設定スクリプト

このスクリプトは、TPM2を使用したLUKSの自動復号を設定します。

**機能：**
- 必要なパッケージの自動インストール
- TPM2デバイスの可用性チェック
- LUKS暗号化デバイスの自動検出
- 新しいパスワードとリカバリーキーの生成
- TPM2へのLUKSキーのバインド（Clevis使用）
- インストール時のパスワードの削除（オプション）
- initramfsの自動更新

**重要：パスワードについて**
このスクリプトで設定する「新しいパスワード」は、Ubuntu autoinstallで設定した`ubuntuKey`とは**別のもの**です：

- **`ubuntuKey`（インストール時のパスワード）**：
  - autoinstall設定ファイルで指定した初期パスワード
  - インストール完了後は削除することが推奨される
  - 一時的な目的のパスワード

- **新しいユーザーパスワード（このスクリプトで設定）**：
  - ユーザーが選ぶ日常使用のためのパスワード
  - TPMが使えない時のバックアップ手段として機能
  - 長期的に使用するパスワード

**なぜ3つの認証方法が必要か？**
1. **TPM2自動アンロック**：通常の起動で自動的に使用（パスワード入力不要）
2. **ユーザーパスワード**：TPMが使えない時の代替手段（カーネル更新後など）
3. **リカバリーキー**：緊急時用の長い複雑なパスフレーズ（パスワード忘れ、別PCでの読み取り時など）

この多層防御により、一つの方法が失敗してもデータへのアクセスを失わないようにしています。

**使用方法：**
```bash
sudo ./setup-tpm-luks-unlock.sh
```

**実行時の動作：**
1. TPM2の可用性を確認
2. 必要なパッケージをインストール
3. LUKS暗号化デバイスを検出（複数ある場合は選択）
4. 新しいパスワードの入力を求める
5. ランダムなリカバリーキーを生成
6. 現在のLUKSパスワードを使用してTPM2にバインド
7. 新しいパスワードとリカバリーキーを追加
8. 古いインストールパスワードを削除（確認後）

**「現在のLUKSパスワード」について：**
スクリプト実行中に「Enter current LUKS password」と聞かれた場合、これは**その時点でLUKSデバイスにアクセスできる有効なパスワード**を意味します：

- **初回実行時**：`ubuntuKey`（autoinstallで設定したインストール時のパスワード）を入力
- **2回目以降**：以下のいずれかを入力
  - まだ削除していない場合は`ubuntuKey`
  - 前回設定したユーザーパスワード
  - リカバリーキー

このパスワードは、TPMへのバインディングや新しいキースロットの追加に必要です。どのキースロットのパスワードでも、LUKSデバイスをアンロックできるものであれば使用できます。

**安全性：**
- リカバリーキーは `/root/.luks-recovery-key-YYYYMMDD-HHMMSS.txt` に保存
- 複数回実行しても安全（既存のバインディングを検出）
- 最低2つのキースロットを維持

### 2. `tpm-status.sh` - TPM状態表示・デバッグスクリプト

このスクリプトは、TPM2とLUKSの状態に関する詳細情報を表示します。

**機能：**
- TPM2デバイスの検出と状態表示
- TPM2の機能とプロパティ表示
- PCR値の表示（セキュアブート状態など）
- Clevisバインディングの状態確認
- systemd-cryptenrollの状態確認
- LUKSデバイス情報の表示
- ブート設定の確認
- 簡易診断機能

**使用方法：**
```bash
# フルレポート
sudo ./tpm-status.sh

# 特定の情報のみ表示
sudo ./tpm-status.sh tpm      # TPMデバイスと機能
sudo ./tpm-status.sh pcr      # PCR値
sudo ./tpm-status.sh luks     # LUKSデバイス情報
sudo ./tpm-status.sh clevis   # Clevis状態
sudo ./tpm-status.sh boot     # ブート設定
sudo ./tpm-status.sh diag     # 簡易診断
```

**root不要の使用：**
一部の情報は一般ユーザーでも確認可能：
```bash
./tpm-status.sh tpm
./tpm-status.sh pcr
```

### 3. `cleanup-tpm-slots.sh` - 重複TPMスロット削除スクリプト

このスクリプトは、LUKSデバイスから重複したTPMスロットを安全に削除します。

### 4. `check-tpm-health.sh` - TPMヘルスチェックスクリプト

システム更新前後にTPM自動復号の状態を確認するスクリプトです。

**機能：**
- 更新前のPCR値バックアップ
- 更新後のPCR値比較
- Clevisアンロックのテスト
- リカバリーキーのリマインダー

**使用方法：**
```bash
# システム更新前
sudo ./check-tpm-health.sh pre

# システム更新後
sudo ./check-tpm-health.sh post

# 両方を実行
sudo ./check-tpm-health.sh
```

### 元の3番の続き（cleanup-tpm-slots.sh）

**機能：**
- 全LUKSデバイスの自動スキャン
- TPMスロットの自動検出
- 動作するスロットのテスト
- 重複スロットの安全な削除
- ドライラン機能

**使用方法：**
```bash
# 全デバイスをクリーンアップ（対話式）
sudo ./cleanup-tpm-slots.sh

# ドライラン（変更なし）
sudo ./cleanup-tpm-slots.sh --dry-run

# 特定デバイスのクリーンアップ
sudo ./cleanup-tpm-slots.sh /dev/nvme0n1p3

# ヘルプ表示
./cleanup-tpm-slots.sh --help
```

**安全機能：**
- 少なくとも1つのTPMバインディングを保持
- 非TPMキースロットには触れない
- 変更前に確認を求める
- 動作するスロットを優先的に保持

## Clevis以外の自動復号方法

### systemd-cryptenroll（代替方法）

Ubuntu 24.04では、systemd-cryptenrollも利用可能ですが、いくつかの制限があります：

**利点：**
- systemdに統合されている
- 将来的にはUbuntuのデフォルトになる可能性

**欠点：**
- Ubuntu 24.04のinitramfs-toolsとの互換性問題
- dracutへの切り替えが必要な場合がある
- セットアップがより複雑

**基本的な使用方法：**
```bash
# TPM2にバインド
sudo systemd-cryptenroll /dev/nvme0n1p3 --tpm2-device=auto --tpm2-pcrs=7

# バインディングの確認
sudo systemd-cryptenroll /dev/nvme0n1p3 --tpm2-device=list
```

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
   - カーネル更新後、再バインドが必要な場合がある

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

### 予防措置

```bash
# 大きな更新前の確認
sudo ./check-tpm-health.sh pre

# BIOS更新前の一時パスワード追加
sudo cryptsetup luksAddKey /dev/nvme0n1p3

# 更新後の動作確認
sudo ./check-tpm-health.sh post
```

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
# Clevisサービスの状態確認
systemctl status clevis-luks-askpass.path

# initramfsの再生成
sudo update-initramfs -u -k all

# デバッグ情報の確認
sudo ./tpm-status.sh diag
```

### PCR値が変更された
```bash
# 現在のPCR値を確認
sudo ./tpm-status.sh pcr

# 再バインドが必要
sudo clevis luks unbind -d /dev/nvme0n1p3 -s [slot]
sudo clevis luks bind -d /dev/nvme0n1p3 tpm2 '{"pcr_bank":"sha256","pcr_ids":"7"}'
```

## 注意事項

- すべてのスクリプトはroot権限で実行する必要があります
- リカバリーキーは必ず安全な場所に保管してください
- TPMの状態が変更された場合（BIOSアップデートなど）、再バインドが必要です
- セキュアブートの設定を変更すると、自動アンロックが機能しなくなる可能性があります

## ライセンス

これらのスクリプトはMITライセンスで提供されています。