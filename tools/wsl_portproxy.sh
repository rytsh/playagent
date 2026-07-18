#!/usr/bin/env bash
# Forward a Windows port to WSL so the Playdate can reach servers running
# inside WSL (provisioning on 9393, opencode on 4096, ...).
#
# WSL2 uses a NAT network: the Playdate can reach the Windows LAN IP but not
# the WSL IP. This script sets up `netsh interface portproxy` + a firewall
# rule on the Windows side (asks for UAC elevation once).
#
# Usage:
#   tools/wsl_portproxy.sh [PORT]           add/refresh forwarding (default 9393)
#   tools/wsl_portproxy.sh [PORT] remove    remove forwarding + firewall rule
#   tools/wsl_portproxy.sh status           show current portproxy table
#   tools/wsl_portproxy.sh [PORT] --dry-run print what would be run
#
# Note: the WSL IP changes across reboots; re-run this script after a reboot
# (it deletes and re-adds the rule, so it is idempotent).

set -euo pipefail

if [ ! -e /mnt/c/Windows/System32/netsh.exe ]; then
    echo "error: this does not look like WSL (no /mnt/c/Windows)." >&2
    exit 1
fi

PORT="${1:-9393}"
ACTION="${2:-add}"

if [ "$PORT" = "status" ]; then
    exec netsh.exe interface portproxy show v4tov4
fi

if [ "$ACTION" = "--dry-run" ]; then
    DRY=1
    ACTION="add"
else
    DRY=0
fi

WSL_IP="$(hostname -I | awk '{print $1}')"
RULE_NAME="PlayAgent WSL $PORT"

if [ "$ACTION" = "remove" ]; then
    PS_BODY="netsh interface portproxy delete v4tov4 listenport=$PORT listenaddress=0.0.0.0; netsh advfirewall firewall delete rule name=\"$RULE_NAME\""
else
    PS_BODY="netsh interface portproxy delete v4tov4 listenport=$PORT listenaddress=0.0.0.0 2>\$null; netsh interface portproxy add v4tov4 listenport=$PORT listenaddress=0.0.0.0 connectport=$PORT connectaddress=$WSL_IP; netsh advfirewall firewall delete rule name=\"$RULE_NAME\" 2>\$null; netsh advfirewall firewall add rule name=\"$RULE_NAME\" dir=in action=allow protocol=TCP localport=$PORT"
fi

if [ "$DRY" = "1" ]; then
    echo "WSL IP : $WSL_IP"
    echo "Would run (elevated on Windows):"
    echo "  $PS_BODY"
    exit 0
fi

# Write the commands to a .ps1 in the Windows temp dir and run it elevated
# (a single UAC prompt).
WIN_TEMP="$(powershell.exe -NoProfile -Command '$env:TEMP' | tr -d '\r')"
PS1_WIN="$WIN_TEMP\\playagent_portproxy.ps1"
PS1_WSL="$(wslpath "$WIN_TEMP")/playagent_portproxy.ps1"

{
    echo "$PS_BODY"
    echo "netsh interface portproxy show v4tov4"
    echo "Write-Host ''; Write-Host 'Done. You can close this window.' -ForegroundColor Green"
    echo "Start-Sleep -Seconds 4"
} > "$PS1_WSL"

echo "WSL IP: $WSL_IP  ->  forwarding Windows :$PORT to WSL :$PORT"
echo "Requesting UAC elevation on Windows..."
powershell.exe -NoProfile -Command \
    "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','$PS1_WIN'"

echo
echo "After accepting the UAC prompt, verify with:"
echo "  tools/wsl_portproxy.sh status"
echo
echo "The Playdate should use the Windows LAN IP:"
powershell.exe -NoProfile -Command \
    "(Get-NetIPConfiguration | Where-Object {\$_.IPv4DefaultGateway -ne \$null}).IPv4Address.IPAddress" \
    2>/dev/null | tr -d '\r' | sed 's/^/  /'
