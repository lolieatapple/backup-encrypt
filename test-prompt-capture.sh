#!/usr/bin/env bash
# 端到端测试：验证 prompt_password_into 不会污染密码字节，
# 并且通过 --pinentry-mode loopback 可以正常加密/解密。
set -euo pipefail

cd "$(dirname "$0")"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# install 脚本在尾部用 BASH_SOURCE 守卫，source 时不会触发 main
# shellcheck disable=SC1091
source ./install-backup-encrypt.sh

# 模拟用户输入 "TestPass123" 两次。函数把密码直接写到目标文件。
PASS_FILE="$TMPDIR/pass"
prompt_password_to_file "$PASS_FILE" 2>/dev/null <<EOF
TestPass123
TestPass123
EOF

SIZE=$(wc -c < "$PASS_FILE" | tr -d ' ')
echo "--- pass file bytes ---"
xxd "$PASS_FILE" | head -3
echo "--- byte count: $SIZE (expect 11) ---"

GOT=$(cat "$PASS_FILE")
if [[ "$GOT" != "TestPass123" ]]; then
    echo "FAIL: password file content mismatch"
    echo "  got:      $(printf '%q' "$GOT")"
    echo "  expected: 'TestPass123'"
    exit 1
fi
echo "✓ password written cleanly (no leading/trailing junk)"

CIPHER="$TMPDIR/probe.gpg"
if ! printf 'hello-world' \
        | gpg --batch --yes --quiet --no-tty \
              --pinentry-mode loopback \
              --symmetric --cipher-algo AES256 \
              --compress-algo none \
              --passphrase-file "$PASS_FILE" \
              --output "$CIPHER" 2>&1; then
    echo "FAIL: gpg encryption probe"
    exit 1
fi

DEC=$(gpg --batch --yes --quiet --no-tty \
          --pinentry-mode loopback \
          --decrypt \
          --passphrase-file "$PASS_FILE" \
          "$CIPHER" 2>/dev/null)

[[ "$DEC" == "hello-world" ]] || { echo "FAIL: decrypt mismatch ($DEC)"; exit 1; }
echo "✓ gpg roundtrip OK"
echo
echo "ALL TESTS PASSED"
