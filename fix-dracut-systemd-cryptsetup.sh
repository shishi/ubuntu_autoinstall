#!/usr/bin/env bash

  # 基本的なパッケージ
  sudo apt-get update
  sudo apt-get install -y \
      systemd \
      systemd-boot \
      systemd-boot-efi \
      cryptsetup \
      cryptsetup-bin \
      cryptsetup-initramfs \
      dracut \
      dracut-core \
      dracut-network \
      tpm2-tools

#  systemd-cryptsetupの場所を確認

  # systemd-cryptsetupは独立したパッケージではなく、systemdに含まれています
  dpkg -L systemd | grep systemd-cryptsetup

#  dracut設定の修正

  # dracut設定を作成
  sudo mkdir -p /etc/dracut.conf.d

  cat <<'EOF' | sudo tee /etc/dracut.conf.d/01-systemd-tpm2.conf
  # systemdモジュールを追加
  add_dracutmodules+=" systemd crypt "

  # systemd-cryptsetupのパスを明示的に指定
  install_items+=" /lib/systemd/systemd-cryptsetup "

  # TPM2ドライバー
  add_drivers+=" tpm_tis tpm_tis_core tpm_crb "

  # crypttabを含める
  install_items+=" /etc/crypttab "
  EOF

  # initramfsを再生成
  sudo dracut -f --regenerate-all


