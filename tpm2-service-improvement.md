# TPM2サービスの実行保証を強化する方法

## 現在の問題点
- サービスが失敗した場合、次回起動時に再試行されない
- TPMが一時的に利用不可の場合でも、一度失敗すると終了

## 改善案

### 1. Restart設定の追加
```ini
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/tpm2-enroll-installer.sh
Restart=on-failure
RestartSec=30
StartLimitBurst=5
StartLimitIntervalSec=600
```

### 2. より賢い条件チェック
```ini
# 成功マーカーファイルの存在確認に加えて、実際にTPM登録されているかチェック
ConditionPathExists=!/var/lib/tpm2-luks-enrolled
ExecStartPre=/bin/sh -c 'cryptsetup luksDump $(blkid -t TYPE="crypto_LUKS" -o device | head -n 1) | grep -q "tpm2" && exit 1 || exit 0'
```

### 3. タイマーベースの再試行
別途タイマーユニットを作成：
```ini
# /etc/systemd/system/tpm2-luks-enroll.timer
[Unit]
Description=Retry TPM2 LUKS Enrollment
ConditionPathExists=!/var/lib/tpm2-luks-enrolled

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Unit=tpm2-luks-enroll.service

[Install]
WantedBy=timers.target
```

### 4. スクリプト側の改善
```bash
#!/bin/bash
set -euo pipefail

# 最大試行回数
MAX_ATTEMPTS=10
ATTEMPT=0

# 既に登録済みかチェック
if [ -f /var/lib/tpm2-luks-enrolled ]; then
    exit 0
fi

# LUKS デバイスの検出
LUKS_DEV=$(blkid -t TYPE="crypto_LUKS" -o device | head -n 1)
if [ -z "$LUKS_DEV" ]; then
    echo "No LUKS device found"
    exit 1
fi

# 既にTPM登録されているかチェック
if cryptsetup luksDump "$LUKS_DEV" | grep -q "tpm2"; then
    touch /var/lib/tpm2-luks-enrolled
    echo "TPM2 already enrolled"
    exit 0
fi

# TPMデバイスの待機（より長く）
while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    if [ -e /dev/tpm0 ] || [ -e /dev/tpmrm0 ]; then
        if systemd-cryptenroll --tpm2-device=list >/dev/null 2>&1; then
            break
        fi
    fi
    ATTEMPT=$((ATTEMPT + 1))
    sleep 6
done

# 以下、既存の登録処理...
```

## 推奨される実装

最も簡単で効果的なのは、サービスファイルにRestart設定を追加することです：

```yaml
# autoinstall内で修正
cat > /etc/systemd/system/tpm2-luks-enroll.service << "SERVICE_END"
[Unit]
Description=TPM2 LUKS Enrollment
DefaultDependencies=no
Before=sysinit.target
After=systemd-modules-load.service
ConditionPathExists=!/var/lib/tpm2-luks-enrolled

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/tpm2-enroll-installer.sh
# 失敗時の再試行設定
Restart=on-failure
RestartSec=30
StartLimitBurst=5
StartLimitIntervalSec=600

[Install]
WantedBy=sysinit.target
SERVICE_END
```

これにより：
- 失敗時は30秒後に再試行
- 10分間に最大5回まで試行
- TPMが後から利用可能になった場合も対応可能