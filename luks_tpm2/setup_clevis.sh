#!/bin/bash
set -euo pipefail

# 設定
LUKS_DEVICE="/dev/nvme0n1p3"     # LUKSデバイスを適切に変更してください
MAPPING_NAME="dm-encrypted-main" # マッピング名（autoinstall.ymlと一致）

add_or_change_luks_key() {
  local slot=$1
  if [ -n "$2" ]; then
    local NEW_PASSWORD=$2
  fi
  応

  if cryptsetup luksDump $LUKS_DEVICE | grep -qE "($slot: luks2|Key Slot $slot: ENABLED)"; then
    echo "スロット $slot は使用中。変更します..."
    printf '%s' "$CURRENT_PASSWORD" | cryptsetup luksChangeKey "$LUKS_DEVICE" --key-slot "$slot" <(printf '%s' "$NEW_PASSWORD")
  else
    echo "スロット $slot は空。新規追加します..."
    printf '%s' "$CURRENT_PASSWORD" | cryptsetup luksAddKey "$LUKS_DEVICE" --key-slot "$slot" <(printf '%s' "$NEW_PASSWORD")
  fi
}

# ルート権限の確認
if [ "$EUID" -ne 0 ]; then
  echo "このスクリプトはroot権限で実行する必要があります"
  exit 1
fi

# TPM2の確認
if ! tpm2_getcap properties-fixed | grep -q "TPM2_PT_FIRMWARE_VERSION"; then
  echo "エラー: TPM2が検出されません"
  exit 1
fi

# 既存のパスワード
echo "現在のディスク暗号化パスワードを入力してください："
read -s CURRENT_PASSWORD
echo

# 新しいパスワードの設定
echo "新しいパスワードを入力してください："
read -s NEW_PASSWORD
echo
echo "新しいパスワードを再入力してください："
read -s NEW_PASSWORD_CONFIRM
echo

if [ "$NEW_PASS" != "$NEW_PASS_CONFIRM" ]; then
  echo "エラー: パスワードが一致しません"
  exit 1
fi

# リカバリーキーの生成
RECOVERY_KEY=$(dd if=/dev/urandom bs=1 count=32 2>/dev/null | base64)
echo "リカバリーキー: $RECOVERY_KEY" >~/luks-recovery-key.txt
chmod 600 ~/luks-recovery-key.txt

echo "=== Clevis TPM2 LUKS自動アンロックセットアップ ==="

# 前提条件のインストール
echo "必要なパッケージをインストール中..."
apt-get update
apt-get install -y tpm2-tools clevis clevis-tpm2 clevis-luks clevis-initramfs clevis-systemd clevis-udisks2 libtss2-dev cryptsetup cryptsetup-initramfs

# スロット2のパスワードを変更
echo "スロット0に新しいパスワードを設定中..."
add_or_change_luks_key 0

# リカバリーキーをスロット1に追加
echo "スロット1にリカバリーキーを追加中..."
add_or_change_luks_key 1 "$RECOVERY_KEY"

# Clevisを使用してTPM2バインディングを設定
# ここのgrep検査
if clevis luks list -d "$LUKS_DEVICE" 2>/dev/null | grep -q "2: tpm2"; then
  echo "スロット 2 は既にバインドされています。解除します..."
  clevis luks unbind -d "$LUKS_DEVICE" -s 2 -f
fi
echo "スロット2にClevisでTPM2バインディングを設定中..."
clevis luks bind -d "$LUKS_DEVICE" tpm2 '{"pcr_bank":"sha256","pcr_ids":"7"}' -s 2

# たぶんここはautoisntallの次点でできてる
# # crypttabの更新（clevis用）
# echo "crypttabを更新中..."
# LUKS_UUID=$(cryptsetup luksUUID "$LUKS_DEVICE")
# cp /etc/crypttab /etc/crypttab.bak
#
# if grep -q "$LUKS_UUID" /etc/crypttab; then
#   sed -i "s|^.*$LUKS_UUID.*|$MAPPING_NAME UUID=$LUKS_UUID none luks,discard,_netdev,clevis|" /etc/crypttab
#
# else
#   echo "$MAPPING_NAME UUID=$LUKS_UUID none luks,discard,_netdev,clevis" >>/etc/crypttab
# fi

# dracut/initramfsの更新
echo "initramfsを更新中..."
if command -v dracut >/dev/null 2>&1; then
  dracut -f --regenerate-all
else
  update-initramfs -u -k all
fi

# clevisの自動アンロックサービスを有効化
echo "clevisサービスを有効化中..."
systemctl enable clevis-luks-askpass.path
systemctl enable clevis-luks-askpass.service

# 古いキースロットのクリーンアップ（オプション）
echo "このスクリプトで使用していないスロットをクリーンアップしますか？ (y/N)"
read -r CLEANUP
if [[ "$CLEANUP" =~ ^[Yy]$ ]]; then
  # 使用中のスロットを確認
  echo "使用中のキースロット:"
  cryptsetup luksDump "$LUKS_DEVICE" | grep -E "^Key Slot [0-9]:" | grep ENABLED

  for slot in 3 4 5 6 7; do
    # スロットが使用中かチェック
    # if cryptsetup luksDump "$LUKS_DEVICE" | grep -q "Key Slot $slot: ENABLED"; then
    echo "スロット $slot を削除中..."
    printf '%s' "$NEW_PASSWORD" | cryptsetup luksKillSlot "$LUKS_DEVICE" $slot 2>/dev/null ||
      echo "スロット $slot の削除をスキップ（使用されていないか、エラー）"
    # fi
  done
fi

# バインディングの確認
echo "Clevisバインディングを確認中..."
clevis luks list -d "$LUKS_DEVICE"

echo "=== セットアップ完了 ==="
echo "リカバリーキーは ~/luks-recovery-key.txt に保存されました"
echo "安全な場所に保管してください"
echo ""
echo "次回の起動時から、ログインするだけで自動的にディスクがアンロックされます"
echo "問題が発生した場合は、通常のパスワードまたはリカバリーキーを使用してください"
