# Ubuntu TPM2 LUKS Auto-unlock Scripts (systemd-cryptenroll版)

このスクリプトではbootの設定が不完全です。動作にはsystemd-bootとdracut、それに合わせた設定が必要です。GRUBでは`tpm2-device=auto`はサポートされていません。Ubuntu 25.10以降でサポート状況が変わる予定です。特にubuntuのdracutはまだこのまわりが不完全な様子であるため、起動できる設定まではつくりませんでした。状況が変わったらまた試そうかと思います。とりあえず必要そうなことを末尾近くに書いておいたので、またやってみたくなった時に確認する。いろいろやってみたが結局systemd-bootでも tpm2-device=autoが認識させられなかった。

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

**root不要の使用：**
一部の情報は一般ユーザーでも確認可能：
```bash
./tpm-status_systemd.sh tpm
./tpm-status_systemd.sh pcr
```

### 3. `check-tpm-health_systemd.sh` - TPMヘルスチェックスクリプト

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

### 4. `cleanup-tpm-slots_systemd.sh` - 重複TPMスロット削除スクリプト

このスクリプトは、LUKSデバイスから重複したTPM2登録を安全に削除します。ユーザーが保持するスロットを選択できる対話型インターフェースを提供します。

**機能：**
- 全LUKSデバイスの自動スキャン
- TPM2トークンの詳細情報表示（スロット番号、トークンID、PCR値、優先度）
- **対話型選択：どのスロットを保持するか選択可能**
- 現在のPCR値との比較表示
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

**安全機能：**
- 少なくとも1つのTPMバインディングを保持
- 非TPMキースロットには触れない
- 削除前に詳細情報を表示して確認
- ユーザーが保持するスロットを選択
- パスワードとリカバリーキーの確認を促す
- スロット削除時にパスワード入力が必要

**対話例：**
```
╔══════════════════════════════════════════════════════════╗
║ TPM2 Enrollment Details for /dev/nvme0n1p3              ║
╠══════════════════════════════════════════════════════════╣
║ Slot  Token    Priority   PCRs            Status        ║
║ 2     #0       normal     7               Active        ║
║ 3     #1       normal     7               Active        ║
╚══════════════════════════════════════════════════════════╝

Which TPM2 slot do you want to KEEP? (Others will be removed)
Available TPM2 slots: 2 3
Enter slot number to keep: 3
```

**注意：** systemd-cryptenrollではスロットの個別テストができないため、ステータスは「Active」または「Active (device unlocked)」と表示されます。

### 5. `cleanup-password-duplicates_systemd.sh` - 重複パスワード削除スクリプト

このスクリプトは、LUKSデバイスから重複したパスワードエントリを検出して削除します。

**機能：**
- 指定したパスワードの重複チェック
- 重複しているスロットの詳細表示
- **対話型選択：どのスロットを保持するか選択可能**
- systemd管理スロットは除外（TPM2、FIDO2、PKCS#11）
- ドライラン機能

**使用方法：**
```bash
# 全デバイスで重複パスワードをチェック
sudo ./cleanup-password-duplicates_systemd.sh

# 特定デバイスのチェック
sudo ./cleanup-password-duplicates_systemd.sh /dev/nvme0n1p3

# ドライラン
sudo ./cleanup-password-duplicates_systemd.sh --dry-run
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
║   1: luks2                                               ║
║   2: luks2 (systemd-tpm2 token)                         ║
║   3: luks2                                               ║
║                                                          ║
║ Password matches found in slots: 0 1 3                  ║
╚══════════════════════════════════════════════════════════╝

Which slot do you want to KEEP? (Others will be removed)
Available slots: 0 1 3
Enter slot number to keep: 0
```

**安全機能：**
- systemd管理スロット（TPM2、FIDO2、PKCS#11）は自動的に除外
- 削除前に確認を求める
- 少なくとも1つのパスワードスロットを保持

### 6. `test-idempotency_systemd.sh` - セットアップスクリプトの冪等性テスト

開発者向けのテストスクリプトで、`setup-tpm-luks-unlock_systemd.sh`が複数回実行されても安全であることを確認します。

**使用方法：**
```bash
sudo ./test-idempotency_systemd.sh
```

### 5. `test-idempotency_systemd.sh` - 冪等性テストスクリプト

セットアップスクリプトの冪等性（複数回実行しても安全）を確認するためのヘルパースクリプトです。

## LUKSキースロットの確認と管理

### systemd-cryptenrollでの確認方法

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
  0: systemd-recovery
      Keyslot: 1
  1: systemd-tpm2
      Keyslot: 2   # TPM2トークンがスロット2を使用
```

**どのスロットに何のパスワードが入っているか判別する方法：**

1. **TPMスロットの確認**：
```bash
# systemd-cryptenrollで確認
sudo systemd-cryptenroll /dev/sda3 --tpm2-device=list

# cryptsetup luksDumpでトークン確認
sudo cryptsetup luksDump /dev/sda3 | grep -A10 "Tokens:"
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

## スクリプトの実行順序

通常の使用では、以下の順序でスクリプトを実行します：

1. **初期セットアップ**
   ```bash
   sudo ./setup-tpm-luks-unlock_systemd.sh
   ```

2. **状態確認**
   ```bash
   sudo ./tpm-status_systemd.sh
   ```

3. **必要に応じてクリーンアップ**
   ```bash
   # TPMスロットの重複削除
   sudo ./cleanup-tpm-slots_systemd.sh
   
   # パスワードの重複削除
   sudo ./cleanup-password-duplicates_systemd.sh
   ```

4. **システム更新時**
   ```bash
   # 更新前
   sudo ./check-tpm-health_systemd.sh pre
   
   # システム更新実行
   
   # 更新後
   sudo ./check-tpm-health_systemd.sh post
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

### 予防措置

```bash
# 大きな更新前の確認
sudo ./check-tpm-health_systemd.sh pre

# BIOS更新前の一時パスワード追加
sudo cryptsetup luksAddKey /dev/nvme0n1p3

# 更新後の動作確認
sudo ./check-tpm-health_systemd.sh post
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
# crypttabの確認
grep tpm2-device /etc/crypttab

# initramfsの再生成
sudo update-initramfs -u -k all

# デバッグ情報の確認
sudo ./tpm-status_systemd.sh diag
```

### PCR値が変更された
```bash
# 現在のPCR値を確認
sudo ./tpm-status_systemd.sh pcr

# 再登録が必要
sudo systemd-cryptenroll /dev/nvme0n1p3 --wipe-slot=tpm2
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

## このスクリプト以外に必要そうなこと

必要な作業リスト

1. dracutのインストール

sudo apt-get update
sudo apt-get install -y dracut dracut-network

2. dracutの設定

# TPM2サポートを有効化
sudo mkdir -p /etc/dracut.conf.d
echo 'add_dracutmodules+=" systemd systemd-cryptsetup tpm2-tss "' | sudo tee /etc/dracut.conf.d/tpm2.conf

3. crypttabの設定

# tpm2-device=autoを追加（dracutなら認識される）
# 例: dm_crypt-0 UUID=xxx none luks,discard,tpm2-device=auto
sudo nano /etc/crypttab

4. 既存のinitramfs-toolsを無効化

# 古いinitramfsを削除
sudo update-initramfs -d -k all

5. dracutでinitramfsを生成

sudo dracut -f --regenerate-all

6. GRUBの更新

sudo update-grub

7. 確認

# 生成されたinitramfsを確認
ls -la /boot/initramfs* /boot/initrd*

# systemd-cryptsetupが含まれているか確認
lsinitramfs /boot/initramfs-$(uname -r).img | grep systemd-cryptsetup

8. 再起動

sudo reboot

重要な注意点

- Ubuntu標準のinitramfs-toolsではtpm2-device=autoは動作しません
- dracutへの切り替えが必須
- この変更は大きな変更なので、バックアップを推奨
- Ubuntu 25.10からdracutがデフォルトになる予定


## 注意事項

- すべてのスクリプトはroot権限で実行する必要があります
- LUKS2フォーマットが必要です（LUKS1は非対応）
- systemd 248以上が必要です（Ubuntu 22.04以降）
- リカバリーキーは必ず安全な場所に保管してください
- initramfs更新時の警告は無視して構いません

## ライセンス

これらのスクリプトはMITライセンスで提供されています。
