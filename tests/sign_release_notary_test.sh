#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁覆盖：launchers/macos/sign_release.sh
set -euo pipefail

H=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
bad=0

ck() {
  if eval "$2"; then
    echo "通 $1"
  else
    echo "不通 $1"
    bad=1
  fi
}

make_fixture() {
  local work=$1
  local app=$work/S2Arm.app
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Engine/Binaries/Prepare" "$app/Contents/Resources/Shell/root" "$work/bin" "$work/home/.local/bin"
  printf '\xcf\xfa\xed\xfe-main' > "$app/Contents/MacOS/S2Arm"
  printf '{"source": {}}\n' > "$app/Contents/Resources/Engine/engine.json"
  printf 'shell-payload\n' > "$app/Contents/Resources/Shell/root/dummy"
  python3 -I "$H/pack/shell/manifest.py" seal \
    --root "$app/Contents/Resources/Shell/root" \
    --manifest "$app/Contents/Resources/Shell/manifest.json" > /dev/null

  cat > "$work/bin/security" <<'SH'
#!/bin/bash
if [ "${1:-}" = "find-identity" ]; then
  echo '  1) 0000000000000000000000000000000000000000 "Developer ID Application: Test (TEAM123456)"'
fi
SH
  cat > "$work/bin/xattr" <<'SH'
#!/bin/bash
exit 0
SH
  cat > "$work/bin/codesign" <<'SH'
#!/bin/bash
if [ "${1:-}" = "-d" ]; then
  echo 'designated => identifier "org.s2arm.macos.launcher" and certificate leaf[subject.OU] = TEAM123456'
fi
SH
  cat > "$work/bin/ditto" <<'SH'
#!/bin/bash
touch "${@: -1}"
SH
  cat > "$work/bin/xcrun" <<'SH'
#!/bin/bash
echo "xcrun $*" >> "${MOCK_LOG:?}"
if [ "${1:-}" = "notarytool" ] && [ "${2:-}" = "submit" ]; then
  echo "status: Accepted"
fi
SH
  cat > "$work/bin/spctl" <<'SH'
#!/bin/bash
exit 0
SH
  chmod +x "$work/bin/"*
}

run_case() {
  local name=$1
  local setup_cmd=$2
  local expect_rc=$3
  local check_cmd=$4
  local w=$T/$name
  make_fixture "$w"
  local log=$w/xcrun.log
  local out=$w/out.log
  : > "$log"
  eval "$setup_cmd"
  local rc=0
  (
    unset ASC_KEY_PATH ASC_KEY_ID ASC_ISSUER S2A_NOTARY_PROFILE NOTARY_PROFILE
    export HOME="$w/home"
    export MOCK_LOG="$log"
    export S2A_SIGN_KEYCHAIN="$w/test.keychain-db"
    eval "${CASE_ENV:-true}"
    PATH="$w/bin:/usr/bin:/bin" bash "$H/launchers/macos/sign_release.sh" "$w/S2Arm.app"
  ) > "$out" 2>&1 || rc=$?
  ck "$name (exit=$rc, want=$expect_rc)" "[ '$rc' = '$expect_rc' ]"
  ck "$name (behavior)" "$check_cmd"
}

run_case "helper_on_path" \
  'printf "#!/bin/bash\necho helper-profile\n" > "$w/bin/macos-notary-profile"; chmod +x "$w/bin/macos-notary-profile"; CASE_ENV=""' \
  0 \
  'grep -Fq -- "notarytool submit $w/S2Arm.zip --keychain-profile helper-profile --wait" "$log"'

run_case "helper_in_home_local_bin" \
  'printf "#!/bin/bash\necho localbin-profile\n" > "$w/home/.local/bin/macos-notary-profile"; chmod +x "$w/home/.local/bin/macos-notary-profile"; CASE_ENV=""' \
  0 \
  'grep -Fq -- "notarytool submit $w/S2Arm.zip --keychain-profile localbin-profile --wait" "$log"'

run_case "s2a_notary_profile_overrides_env_and_helper" \
  'printf "#!/bin/bash\necho helper-profile\n" > "$w/bin/macos-notary-profile"; chmod +x "$w/bin/macos-notary-profile"; CASE_ENV="export S2A_NOTARY_PROFILE=s2a-override-profile NOTARY_PROFILE=notary-override-profile"' \
  0 \
  'grep -Fq -- "notarytool submit $w/S2Arm.zip --keychain-profile s2a-override-profile --wait" "$log"'

run_case "notary_profile_overrides_helper" \
  'printf "#!/bin/bash\necho helper-profile\n" > "$w/bin/macos-notary-profile"; chmod +x "$w/bin/macos-notary-profile"; CASE_ENV="export NOTARY_PROFILE=notary-override-profile"' \
  0 \
  'grep -Fq -- "notarytool submit $w/S2Arm.zip --keychain-profile notary-override-profile --wait" "$log"'

run_case "asc_key_ci_compatibility" \
  'printf "#!/bin/bash\necho helper-profile\n" > "$w/bin/macos-notary-profile"; chmod +x "$w/bin/macos-notary-profile"; CASE_ENV="export S2A_NOTARY_PROFILE=ignored-profile ASC_KEY_PATH=\"$w/key.p8\" ASC_KEY_ID=KEY123 ASC_ISSUER=ISSUER456"' \
  0 \
  'grep -Fq -- "notarytool submit $w/S2Arm.zip --key $w/key.p8 --key-id KEY123 --issuer ISSUER456 --wait" "$log"'

run_case "missing_credentials_fails_with_guidance" \
  'CASE_ENV="export ASC_KEY_PATH=\"$w/only-path.p8\""' \
  4 \
  '! grep -q "notarytool submit" "$log" && grep -q "macos-notary-profile" "$out" && grep -q "S2A_NOTARY_PROFILE" "$out" && grep -q "NOTARY_PROFILE" "$out" && grep -q "ASC_KEY_PATH" "$out"'

run_case "notarize_disabled_skips_submit" \
  'CASE_ENV="export S2A_NOTARIZE=0"' \
  0 \
  '! grep -q "notarytool" "$log"'

[ "$bad" = 0 ] && echo "sign_release_notary 单测全过" || echo "sign_release_notary 单测有不通"
exit "$bad"
