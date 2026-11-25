#!/usr/bin/env bash
# Wazuh agent na nixosapache – vše v jednom.
# Spuštění na VM:  sudo bash wazuh-nixos.sh
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Spusť přes sudo: sudo bash $0"; exit 1; }

DIR=/etc/nixos
CONF="$DIR/configuration.nix"
[ -f "$CONF" ] || { echo "Nenašel jsem $CONF"; exit 1; }

# ── 1) Modul s agentem ────────────────────────────────────────────────
cat > "$DIR/wazuh.nix" <<'EOF'
# Wazuh agent – skupina4-security-mon
{ pkgs, ... }:
let
  # Komunitní NixOS modul, zafixovaný na agenta 4.14.8
  # (manažer je 4.14.9 a novějšího agenta by odmítl)
  wazuh = builtins.fetchGit {
    url = "https://github.com/nealfennimore/wazuh-agent-nixos";
    ref = "main";
    rev = "43598b61d5d277db9f0c047c934875e20641b2cf";
  };
in
{
  imports = [ "${wazuh}/nixos/wazuh-agent" ];

  services.wazuh-agent = {
    enable = true;
    package = pkgs.callPackage "${wazuh}/pkgs/wazuh-agent.nix" { };

    manager.host = "10.0.0.40";      # WAZUH_MANAGER

    registration = {
      agentName = "Linux2";          # WAZUH_AGENT_NAME
      groups = [ "default" ];        # WAZUH_AGENT_GROUP
    };

    # Hlídání změn souborů: /etc, /boot + web se sqli stránkou
    syscheck.directories = [ "/etc" "/boot" "/var/www" ];
  };

  # Hotový build z Cachix, ať se agent nekompiluje ze zdrojáků
  nix.settings = {
    extra-substituters = [ "https://wazuh.cachix.org" ];
    extra-trusted-public-keys = [
      "wazuh.cachix.org-1:NflEnqc62gXNPSzRtdOmuzDyfGK7yrTc6C2znraX3B8="
    ];
  };
}
EOF
echo "✓ zapsán $DIR/wazuh.nix"

# ── 2) Přidání do imports v configuration.nix ─────────────────────────
if grep -q '\./wazuh\.nix' "$CONF"; then
  echo "✓ ./wazuh.nix už v imports je"
else
  cp "$CONF" "$CONF.bak-wazuh"
  if grep -q '\./hardware-configuration\.nix' "$CONF"; then
    # vložit vedle hardware-configuration.nix (funguje pro jakékoli formátování)
    sed -i '0,/\.\/hardware-configuration\.nix/s//.\/wazuh.nix .\/hardware-configuration.nix/' "$CONF"
  elif grep -qE '^\s*imports\s*=\s*\[' "$CONF"; then
    sed -i -E '0,/^(\s*)imports\s*=\s*\[/s//&\n\1  .\/wazuh.nix/' "$CONF"
  elif grep -qE '^\s*imports\b' "$CONF"; then
    echo "✗ imports mají neobvyklý tvar, přidej do nich ./wazuh.nix ručně a spusť skript znovu"
    exit 1
  else
    # žádné imports – vložit hned za první otevírací { modulu
    sed -i -E '0,/^\s*\{\s*$/s//&\n  imports = [ .\/wazuh.nix ];/' "$CONF"
  fi
  grep -q '\./wazuh\.nix' "$CONF" || {
    echo "✗ Nepovedlo se upravit imports, přidej ./wazuh.nix ručně (záloha: $CONF.bak-wazuh)"
    exit 1
  }
  echo "✓ ./wazuh.nix přidán do imports (záloha: $CONF.bak-wazuh)"
fi

# ── 3) Rebuild (cache povolená už pro první build) ────────────────────
OPTS=(--option extra-substituters https://wazuh.cachix.org
      --option extra-trusted-public-keys "wazuh.cachix.org-1:NflEnqc62gXNPSzRtdOmuzDyfGK7yrTc6C2znraX3B8=")

if [ -f "$DIR/flake.nix" ]; then
  [ -d "$DIR/.git" ] && git -C "$DIR" add -A
  nixos-rebuild switch --flake "$DIR#$(hostname)" "${OPTS[@]}"
else
  nixos-rebuild switch "${OPTS[@]}"
fi

# ── 4) Kontrola ───────────────────────────────────────────────────────
echo
echo "── stav agenta ──"
systemctl --no-pager --lines=0 status wazuh.target wazuh-agentd || true
echo
echo "── registrace u manažera ──"
journalctl -u wazuh-agent-auth -b --no-pager | tail -n 10 || true
