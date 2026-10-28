#!/bin/sh
# Remove the "No valid subscription" popup from the web UI.
#
# proxmox-widget-toolkit's Proxmox.Utils.checked_command() asks /nodes/localhost/subscription and
# shows the popup before running the wrapped action unless the status is "active". This makes its
# success handler run the action straight away. Nothing else (subscription status display, repo
# warnings) is changed. Fails the image build if the code no longer matches exactly once.
set -eu
JS=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
MARK='/* pbs-arm64: subscription nag disabled */'

grep -qF "$MARK" "$JS" && { echo "no-subscription-nag: $JS is already patched" >&2; exit 1; }

perl -0pi -e '
  $n = s{(checked_command: function \(orig_cmd\) \{\s*Proxmox\.Utils\.API2Request\(\{.*?success: function \(response, opts\) \{)}
        {$1 '"$MARK"' orig_cmd(); return;}s;
  die "no-subscription-nag: expected exactly one checked_command success handler, patched $n\n" unless $n == 1;
' "$JS"

test "$(grep -oF "$MARK" "$JS" | wc -l)" -eq 1
echo "no-subscription-nag: patched $JS"
