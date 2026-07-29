#!/usr/bin/env bash
set -euo pipefail

EXPECTED_BUNDLE_ID="com.end.DesktopVoiceInput"
APP_SOURCE="${1:?Usage: fresh-install-local.sh <GuGuTalk.app>}"
USER_HOME="${HOME:?HOME is required}"
INSTALL_PATH="/Applications/GuGuTalk.app"
TRASH_ROOT="$USER_HOME/.Trash/GuGuTalk-fresh-install-$(date +%Y%m%d-%H%M%S)-$$"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
DRY_RUN="${GUGUTALK_FRESH_INSTALL_DRY_RUN:-0}"

fail() {
    echo "Fresh install failed: $*" >&2
    exit 1
}

[[ -d "$APP_SOURCE" ]] || fail "app not found: $APP_SOURCE"
[[ "$APP_SOURCE" != "$INSTALL_PATH" ]] || fail "source app must not be the installed app"
[[ -w "/Applications" ]] || fail "/Applications is not writable by the current user"

ACTUAL_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_SOURCE/Contents/Info.plist" 2>/dev/null || true)"
[[ "$ACTUAL_BUNDLE_ID" == "$EXPECTED_BUNDLE_ID" ]] || fail "unexpected bundle ID: ${ACTUAL_BUNDLE_ID:-missing}"
/usr/bin/codesign --verify --deep --strict "$APP_SOURCE" || fail "source app signature is invalid"

CLEAN_TARGETS=(
    "/Applications/GuGuTalk.app|applications-GuGuTalk.app"
    "/Applications/DesktopVoiceInput.app|applications-DesktopVoiceInput.app"
    "$USER_HOME/Applications/GuGuTalk.app|user-applications-GuGuTalk.app"
    "$USER_HOME/Applications/DesktopVoiceInput.app|user-applications-DesktopVoiceInput.app"
    "$USER_HOME/Library/Application Support/GuGuTalk|application-support-GuGuTalk"
    "$USER_HOME/Library/Application Support/DesktopVoiceInput|application-support-DesktopVoiceInput"
    "$USER_HOME/Library/Caches/GuGuTalk|caches-GuGuTalk"
    "$USER_HOME/Library/Caches/DesktopVoiceInput|caches-DesktopVoiceInput"
    "$USER_HOME/Library/Caches/$EXPECTED_BUNDLE_ID|caches-$EXPECTED_BUNDLE_ID"
    "$USER_HOME/Library/Logs/GuGuTalk|logs-GuGuTalk"
    "$USER_HOME/Library/Preferences/$EXPECTED_BUNDLE_ID.plist|preferences-$EXPECTED_BUNDLE_ID.plist"
    "$USER_HOME/Library/Saved Application State/$EXPECTED_BUNDLE_ID.savedState|saved-state-$EXPECTED_BUNDLE_ID"
    "$USER_HOME/Library/HTTPStorages/$EXPECTED_BUNDLE_ID|http-storages-$EXPECTED_BUNDLE_ID"
    "$USER_HOME/Library/HTTPStorages/$EXPECTED_BUNDLE_ID.binarycookies|http-storage-cookies-$EXPECTED_BUNDLE_ID"
    "$USER_HOME/Library/Cookies/$EXPECTED_BUNDLE_ID.binarycookies|cookies-$EXPECTED_BUNDLE_ID"
    "$USER_HOME/Library/WebKit/$EXPECTED_BUNDLE_ID|webkit-$EXPECTED_BUNDLE_ID"
    "$USER_HOME/Library/Containers/$EXPECTED_BUNDLE_ID|container-$EXPECTED_BUNDLE_ID"
    "$USER_HOME/Library/Application Scripts/$EXPECTED_BUNDLE_ID|application-scripts-$EXPECTED_BUNDLE_ID"
)

if [[ "$DRY_RUN" == "1" ]]; then
    echo "Fresh-install dry run for $APP_SOURCE"
    echo "Would reset TCC permissions for $EXPECTED_BUNDLE_ID"
    for entry in "${CLEAN_TARGETS[@]}"; do
        path="${entry%%|*}"
        if [[ -e "$path" || -L "$path" ]]; then
            echo "Would move to Trash: $path"
        fi
    done
    echo "Would install to: $INSTALL_PATH"
    exit 0
fi

for process_name in GuGuTalk DesktopVoiceInput; do
    /usr/bin/pkill -TERM -x "$process_name" 2>/dev/null || true
done

for _ in {1..20}; do
    if ! /usr/bin/pgrep -x GuGuTalk >/dev/null 2>&1 && ! /usr/bin/pgrep -x DesktopVoiceInput >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
done

for process_name in GuGuTalk DesktopVoiceInput; do
    /usr/bin/pkill -KILL -x "$process_name" 2>/dev/null || true
done

if [[ -x "$LSREGISTER" ]]; then
    # tccutil resolves a bundle ID through Launch Services. Register the new
    # bundle first so permission reset also works after a previous uninstall.
    "$LSREGISTER" -f "$APP_SOURCE" >/dev/null 2>&1 || true
fi
/usr/bin/tccutil reset All "$EXPECTED_BUNDLE_ID" >/dev/null || fail "could not reset TCC permissions for $EXPECTED_BUNDLE_ID"

for installed_app in "/Applications/GuGuTalk.app" "/Applications/DesktopVoiceInput.app" "$USER_HOME/Applications/GuGuTalk.app" "$USER_HOME/Applications/DesktopVoiceInput.app"; do
    if [[ -x "$LSREGISTER" && -d "$installed_app" ]]; then
        "$LSREGISTER" -u "$installed_app" >/dev/null 2>&1 || true
    fi
done

MOVED_ANY=0
for entry in "${CLEAN_TARGETS[@]}"; do
    path="${entry%%|*}"
    label="${entry#*|}"
    if [[ -e "$path" || -L "$path" ]]; then
        /bin/mkdir -p "$TRASH_ROOT"
        /bin/mv "$path" "$TRASH_ROOT/$label"
        MOVED_ANY=1
    fi
done

/usr/bin/defaults delete "$EXPECTED_BUNDLE_ID" >/dev/null 2>&1 || true

if ! /usr/bin/ditto "$APP_SOURCE" "$INSTALL_PATH"; then
    fail "could not copy the new app to $INSTALL_PATH"
fi

/usr/bin/codesign --verify --deep --strict "$INSTALL_PATH" || fail "installed app signature is invalid"
if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$INSTALL_PATH" >/dev/null 2>&1 || true
fi

/usr/bin/open "$INSTALL_PATH"

echo "Installed: $INSTALL_PATH"
echo "Reset permissions: $EXPECTED_BUNDLE_ID"
if [[ "$MOVED_ANY" == "1" ]]; then
    echo "Previous app and data moved to: $TRASH_ROOT"
else
    echo "No previous app or data was found"
fi
