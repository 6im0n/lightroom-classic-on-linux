#!/usr/bin/env bash
# disable-tips.sh PREFS — keep Lightroom Classic's tips, walkthroughs and
# feature onboarding turned off.
#
# PREFS is "Lightroom Classic CC 7 Preferences.agprefs", a Lua table that
# Lightroom rewrites (with CRLF line endings) every time it exits:
#
#   prefs = {
#       AgTipsDlg_TurnOffTips = true,
#       ["com.adobe.ag.develop_Showed_Walkthroughs"] = true,
#       generativeRemoveOnboardingShown = true,
#       ...
#   }
#
# Two passes, both idempotent:
#   1. Every existing key whose name contains "onboard"/"onborad" (Lightroom
#      misspells one as AgDevelop_hdroOnborading) or "walkthrough", any case,
#      and is set to false becomes true. This covers keys added by future
#      Lightroom versions. Keys that also contain "always", "should", "enable"
#      or "force" are skipped: for those, true would turn onboarding ON
#      (alwaysShowOnboarding, shouldShowOnboarding, ...).
#   2. Keys Lightroom writes when you tick "Turn off tips" or finish a
#      walkthrough are added as true when missing, so a fresh preferences file
#      starts with tips off.
#
# Only POSIX awk is used (works with gawk, mawk and busybox awk). The file is
# rewritten only when something changed; line endings and every other line
# are kept as they are. Run it while Lightroom is closed.

set -euo pipefail

prefs=${1:?usage: disable-tips.sh PREFS}
[ -f "$prefs" ] || exit 0

KNOWN_KEYS='AgTipsDlg_TurnOffTips
AIEditStatusWalkthroughShown
["com.adobe.ag.develop_Showed_Walkthroughs"]
["com.adobe.ag.library_Showed_Walkthroughs"]
["com.adobe.ag.location_Showed_Walkthroughs"]
["com.adobe.ag.wpg_Showed_Walkthroughs"]
develop_Walkthroughs_Closed
library_Walkthroughs_Closed
wpg_Walkthroughs_Closed
aiEditStatus_Walkthroughs_Closed
hdrWalkthrough_Walkthroughs_Closed
lensblur_Walkthroughs_Closed
maskingSS_Walkthroughs_Closed
lensBlurGAOnboardingShown
AgDevelop_hdroOnborading
AgDevelop_maskingLandscapeWalkthroughPlayed
Showed_Sync_Walkthrough
generativeRemoveOnboardingShown
onboardingShownInRemoveTool
distractingPeopleRemovalOnboardingShown
reflectionRemovalOnboardingShown
sensorDustSpotsRemovalOnboardingShown'

tmp=$(mktemp "${prefs}.XXXXXX")
trap 'rm -f "$tmp"' EXIT

# awk exits 0 when it wrote a changed file, 3 when there was nothing to do,
# 4 when the file doesn't look like Lightroom preferences.
set +e
awk -v known="$KNOWN_KEYS" '
    NR == 1 {
        cr = ($0 ~ /\r$/) ? "\r" : ""
        if ($0 != "prefs = {" cr) exit 4
        head = $0
        next
    }
    {
        line[++n] = $0
        # "<indent>key = true|false,[CR]" with key bare or ["quoted"]
        if ($0 ~ /^[ \t]*(\["[^"]*"\]|[A-Za-z_][A-Za-z0-9_]*) = (true|false),\r?$/) {
            key = $0
            sub(/^[ \t]*/, "", key)
            sub(/ = (true|false),\r?$/, "", key)
            present[key] = 1
            lk = tolower(key)
            if ($0 ~ / = false,\r?$/ && lk ~ /onboard|onborad|walkthrough/ &&
                lk !~ /always|should|enable|force/) {
                sub(/ = false,/, " = true,", line[n])
                changed++
            }
        }
    }
    END {
        if (head == "") exit 4
        nk = split(known, keys, "\n")
        for (i = 1; i <= nk; i++)
            if (!(keys[i] in present)) add[++na] = "\t" keys[i] " = true," cr
        if (!changed && !na) exit 3
        print head
        for (i = 1; i <= na; i++) print add[i]
        for (i = 1; i <= n; i++) print line[i]
        printf "disable-tips: %d set to true, %d added\n", changed, na > "/dev/stderr"
    }
' "$prefs" > "$tmp"
rc=$?
set -e

if [ "$rc" -eq 0 ]; then
  cat "$tmp" > "$prefs"   # keep the original file (owner, mode, inode)
fi
[ "$rc" -eq 3 ] || [ "$rc" -eq 4 ] || [ "$rc" -eq 0 ] || exit "$rc"
exit 0
