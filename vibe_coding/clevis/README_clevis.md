# Ubuntu TPM2 LUKS Auto-unlock Scripts

このリポジトリには、Ubuntu 24.04 LTSでTPM2を使用してLUKS暗号化ディスクの自動復号を設定するためのスクリプトが含まれています。

## 概要

これらのスクリプトは、TPM2（Trusted Platform Module 2.0）チップを使用して、起動時にLUKS暗号化ディスクを自動的にアンロックする機能を提供します。Clevisフレームワークを使用し、セキュアブート状態などのPCR（Platform Configuration Register）値に基づいて復号キーを保護します。

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
- TPM2チップが搭載されたハードウェア
- LUKS暗号化されたディスク
- root権限

## スクリプト一覧

### 1. `setup-tpm-luks-unlock_clevis.sh` - TPM自動アンロック設定スクリプト

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
sudo ./setup-tpm-luks-unlock_clevis.sh
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

### LUKSキースロットの確認と管理

**キースロットの詳細確認方法：**
```bash
# すべてのキースロットの状態を表示
sudo cryptsetup luksDump /dev/sda3
```

出力例：
```
Keyslots:
  0: luks2  # 通常のパスワードスロット
  1: luks2  # 通常のパスワードスロット（またはTPM用）
  2: luks2  # 通常のパスワードスロット
  ...
Tokens:
  0: clevis
      Keyslot: 1  # この場合、スロット1がTPM2で使用されている
```

**どのスロットに何のパスワードが入っているか判別する方法：**

1. **TPMスロットの確認**：
```bash
# Clevisが使用しているスロットを確認
sudo clevis luks list -d /dev/sda3
```

2. **各スロットのパスワードをテスト**：
```bash
# ubuntuKey（インストール時のパスワード）でテスト
echo -n "インストール時のパスワード" | sudo cryptsetup luksOpen --test-passphrase /dev/sda3 --key-slot 0
echo -n "インストール時のパスワード" | sudo cryptsetup luksOpen --test-passphrase /dev/sda3 --key-slot 2
echo -n "インストール時のパスワード" | sudo cryptsetup luksOpen --test-passphrase /dev/sda3 --key-slot 3

# 新しいユーザーパスワードでテスト
echo -n "新しいパスワード" | sudo cryptsetup luksOpen --test-passphrase /dev/sda3 --key-slot 0
echo -n "新しいパスワード" | sudo cryptsetup luksOpen --test-passphrase /dev/sda3 --key-slot 2
echo -n "新しいパスワード" | sudo cryptsetup luksOpen --test-passphrase /dev/sda3 --key-slot 3

# リカバリーキーでテスト
RECOVERY_KEY=$(grep "Recovery Key:" /root/.luks-recovery-key-*.txt | tail -1 | cut -d: -f2- | sed 's/^[[:space:]]*//')
echo -n "$RECOVERY_KEY" | sudo cryptsetup luksOpen --test-passphrase /dev/sda3 --key-slot 0
echo -n "$RECOVERY_KEY" | sudo cryptsetup luksOpen --test-passphrase /dev/sda3 --key-slot 2
echo -n "$RECOVERY_KEY" | sudo cryptsetup luksOpen --test-passphrase /dev/sda3 --key-slot 3
```

テスト結果の見方：
- **成功した場合**：何も表示されない（そのスロットに該当パスワードが存在）
- **失敗した場合**：「No key available with this passphrase」というエラーが表示される

**不要なキースロット（ubuntuKeyなど）の削除方法：**

```bash
# 特定のスロットを削除（例：スロット0）
sudo cryptsetup luksKillSlot /dev/sda3 0
# 現在有効なパスワードの入力が必要です

# または、パスワードを指定して該当するスロットを自動削除
echo -n "削除したいパスワード" | sudo cryptsetup luksRemoveKey /dev/sda3
```

**注意事項：**
- 最低でも1つの通常パスワードスロットは残しておくこと
- TPMスロットだけに依存するのは危険
- 削除前に必ず他の認証方法が機能することを確認

### 2. `tpm-status_clevis.sh` - TPM状態表示・デバッグスクリプト

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
sudo ./tpm-status_clevis.sh

# 特定の情報のみ表示
sudo ./tpm-status_clevis.sh tpm      # TPMデバイスと機能
sudo ./tpm-status_clevis.sh pcr      # PCR値
sudo ./tpm-status_clevis.sh luks     # LUKSデバイス情報
sudo ./tpm-status_clevis.sh clevis   # Clevis状態
sudo ./tpm-status_clevis.sh boot     # ブート設定
sudo ./tpm-status_clevis.sh diag     # 簡易診断
```

**root不要の使用：**
一部の情報は一般ユーザーでも確認可能：
```bash
./tpm-status_clevis.sh tpm
./tpm-status_clevis.sh pcr
```

### 3. `check-tpm-health_clevis.sh` - TPMヘルスチェックスクリプト

システム更新前後にTPM自動復号の状態を確認するスクリプトです。

**機能：**
- 更新前のPCR値バックアップ
- 更新後のPCR値比較
- Clevisアンロックのテスト
- リカバリーキーのリマインダー

**使用方法：**
```bash
# システム更新前
sudo ./check-tpm-health_clevis.sh pre

# システム更新後
sudo ./check-tpm-health_clevis.sh post

# 両方を実行
sudo ./check-tpm-health_clevis.sh
```

### 4. `cleanup-tpm-slots_clevis.sh` - 重複TPMスロット削除スクリプト

このスクリプトは、LUKSデバイスから重複したTPMスロットを安全に削除します。ユーザーが保持するスロットを選択できる対話型インターフェースを提供します。

**機能：**
- 全LUKSデバイスの自動スキャン
- TPMスロットの詳細情報表示（スロット番号、PCR値、状態）
- 各スロットの動作テスト
- **対話型選択：どのスロットを保持するか選択可能**
- 重複スロットの安全な削除
- ドライラン機能

**使用方法：**
```bash
# 全デバイスをクリーンアップ（対話式）
sudo ./cleanup-tpm-slots_clevis.sh

# ドライラン（変更なし）
sudo ./cleanup-tpm-slots_clevis.sh --dry-run

# 特定デバイスのクリーンアップ
sudo ./cleanup-tpm-slots_clevis.sh /dev/nvme0n1p3

# ヘルプ表示
./cleanup-tpm-slots_clevis.sh --help
```

**安全機能：**
- 少なくとも1つのTPMバインディングを保持
- 非TPMキースロットには触れない
- 削除前に詳細情報を表示して確認
- ユーザーが保持するスロットを選択
- パスワードとリカバリーキーの確認を促す

**対話例：**
```
╔══════════════════════════════════════════════════════════╗
║ TPM2 Binding Details for /dev/nvme0n1p3                 ║
╠══════════════════════════════════════════════════════════╣
║ Slot   Pin Type   PCRs            Status                ║
║ 1      tpm2       7               Working               ║
║ 2      tpm2       7               Failed/TPM changed    ║
╚══════════════════════════════════════════════════════════╝

Which TPM2 slot do you want to KEEP? (Others will be removed)
Available TPM2 slots: 1 2
Enter slot number to keep: 1
```

### 5. `cleanup-password-duplicates_clevis.sh` - 重複パスワード削除スクリプト

このスクリプトは、LUKSデバイスから重複したパスワードエントリを検出して削除します。

**機能：**
- 指定したパスワードの重複チェック
- 重複しているスロットの詳細表示
- **対話型選択：どのスロットを保持するか選択可能**
- Clevis管理スロットは除外（TPM、Tangなど）
- ドライラン機能

**使用方法：**
```bash
# 全デバイスで重複パスワードをチェック
sudo ./cleanup-password-duplicates_clevis.sh

# 特定デバイスのチェック
sudo ./cleanup-password-duplicates_clevis.sh /dev/nvme0n1p3

# ドライラン
sudo ./cleanup-password-duplicates_clevis.sh --dry-run
```

**対話例：**
```
Enter the password you want to check for duplicates:
Password to check: ********

Password duplicates found!
╔══════════════════════════════════════════════════════════╗
║ Slot Details for /dev/nvme0n1p3                         ║
╠══════════════════════════════════════════════════════════╣
║ All key slots:                                           ║
║   0: luks2                                               ║
║   1: luks2 (Clevis TPM2)                                ║
║   2: luks2                                               ║
║   3: luks2                                               ║
║                                                          ║
║ Password matches found in slots: 0 2 3                  ║
╚══════════════════════════════════════════════════════════╝

Which slot do you want to KEEP? (Others will be removed)
Available slots: 0 2 3
Enter slot number to keep: 0
```

**安全機能：**
- Clevis管理スロット（TPM、Tangなど）は自動的に除外
- 削除前に確認を求める
- 少なくとも1つのパスワードスロットを保持

### 6. `test-idempotency_clevis.sh` - セットアップスクリプトの冪等性テスト

開発者向けのテストスクリプトで、`setup-tpm-luks-unlock_clevis.sh`が複数回実行されても安全であることを確認します。

**使用方法：**
```bash
sudo ./test-idempotency_clevis.sh
```

### 元の3番の続き（cleanup-tpm-slots_clevis.sh）

## スクリプトの実行順序

通常の使用では、以下の順序でスクリプトを実行します：

1. **初期セットアップ**
   ```bash
   sudo ./setup-tpm-luks-unlock_clevis.sh
   ```

2. **状態確認**
   ```bash
   sudo ./tpm-status_clevis.sh
   ```

3. **必要に応じてクリーンアップ**
   ```bash
   # TPMスロットの重複削除
   sudo ./cleanup-tpm-slots_clevis.sh
   
   # パスワードの重複削除
   sudo ./cleanup-password-duplicates_clevis.sh
   ```

4. **システム更新時**
   ```bash
   # 更新前
   sudo ./check-tpm-health_clevis.sh pre
   
   # システム更新実行
   
   # 更新後
   sudo ./check-tpm-health_clevis.sh post
   ```

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
sudo ./check-tpm-health_clevis.sh pre

# BIOS更新前の一時パスワード追加
sudo cryptsetup luksAddKey /dev/nvme0n1p3

# 更新後の動作確認
sudo ./check-tpm-health_clevis.sh post
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
sudo ./tpm-status_clevis.sh diag
```

### PCR値が変更された
```bash
# 現在のPCR値を確認
sudo ./tpm-status_clevis.sh pcr

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
