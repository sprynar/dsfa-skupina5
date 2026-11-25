#!/usr/bin/env bash
# Wazuh agent na nixosapache – vše v jednom, bez kompilace.
# Bere oficiální wazuh-agent 4.14.9 .deb (stejný jako zbytek skupiny),
# jen ho upraví pro NixOS (autoPatchelf) a spustí jako systemd službu.
# Spuštění na VM:  sudo bash wazuh-nixos.sh
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Spusť přes sudo: sudo bash $0"; exit 1; }

DIR=/etc/nixos
CONF="$DIR/configuration.nix"
[ -f "$CONF" ] || { echo "Nenašel jsem $CONF"; exit 1; }

# ── 0) Uvolnit místo po nepovedeném buildu (staré generace zůstávají) ──
nix-collect-garbage >/dev/null 2>&1 || true
df -h / /nix 2>/dev/null | awk 'NR==1 || !seen[$0]++'

# ── 1) Modul s agentem ────────────────────────────────────────────────
cat > "$DIR/wazuh.nix" <<'EOF'
# Wazuh agent – skupina4-security-mon (oficiální 4.14.9 .deb, bez kompilace)
{ pkgs, lib, ... }:
let
  manager   = "10.0.0.40";   # WAZUH_MANAGER
  agentName = "Linux2";      # WAZUH_AGENT_NAME
  agentGrp  = "default";     # WAZUH_AGENT_GROUP

  wazuhAgent = pkgs.stdenv.mkDerivation {
    pname = "wazuh-agent-deb";
    version = "4.14.9";
    src = builtins.fetchurl
      "https://packages.wazuh.com/4.x/apt/pool/main/w/wazuh-agent/wazuh-agent_4.14.9-1_amd64.deb";
    dontUnpack = true;
    nativeBuildInputs = [ pkgs.dpkg pkgs.autoPatchelfHook ];
    buildInputs = [ pkgs.stdenv.cc.cc.lib pkgs.zlib ];
    autoPatchelfIgnoreMissingDeps = true;
    installPhase = ''
      dpkg-deb -x $src $out
    '';
  };

  ossecConf = pkgs.writeText "ossec.conf" ''
    <ossec_config>
      <client>
        <server>
          <address>${manager}</address>
          <port>1514</port>
          <protocol>tcp</protocol>
        </server>
        <notify_time>20</notify_time>
        <time-reconnect>60</time-reconnect>
        <auto_restart>yes</auto_restart>
        <crypto_method>aes</crypto_method>
      </client>

      <client_buffer>
        <disabled>no</disabled>
        <queue_size>5000</queue_size>
        <events_per_second>500</events_per_second>
      </client_buffer>

      <syscheck>
        <disabled>no</disabled>
        <frequency>43200</frequency>
        <scan_on_start>yes</scan_on_start>
        <directories>/etc,/boot,/var/www</directories>
      </syscheck>

      <wodle name="syscollector">
        <disabled>no</disabled>
        <interval>1h</interval>
        <scan_on_start>yes</scan_on_start>
        <hardware>yes</hardware>
        <os>yes</os>
        <network>yes</network>
        <packages>yes</packages>
        <ports all="no">yes</ports>
        <processes>yes</processes>
      </wodle>

      <localfile>
        <log_format>apache</log_format>
        <location>/var/log/httpd/*.log</location>
      </localfile>

      <logging>
        <log_format>plain</log_format>
      </logging>
    </ossec_config>
  '';
in
{
  users.groups.wazuh = { };
  users.users.wazuh = {
    isSystemUser = true;
    group = "wazuh";
    home = "/var/ossec";
  };

  systemd.services.wazuh-agent = {
    description = "Wazuh agent";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    path = with pkgs; [ bash coreutils gnugrep gnused gawk findutils procps util-linux nettools which ];

    # Nakopíruje agenta do /var/ossec, nastaví práva a jednou se zaregistruje
    preStart = ''
      set -eu
      if [ "$(cat /var/ossec/.nix-src 2>/dev/null)" != "${wazuhAgent}" ]; then
        keys=""
        if [ -s /var/ossec/etc/client.keys ]; then keys=$(cat /var/ossec/etc/client.keys); fi
        rm -rf /var/ossec
        cp -r ${wazuhAgent}/var/ossec /var/ossec
        chmod -R u+w /var/ossec
        if [ -n "$keys" ]; then printf '%s\n' "$keys" > /var/ossec/etc/client.keys; fi
        echo "${wazuhAgent}" > /var/ossec/.nix-src
      fi

      cp ${ossecConf} /var/ossec/etc/ossec.conf
      mkdir -p /var/ossec/logs
      touch /var/ossec/etc/client.keys /var/ossec/logs/ossec.log

      chown -R root:wazuh /var/ossec
      chmod -R g+rX,o-rwx /var/ossec
      for d in queue var logs tmp; do
        if [ -e /var/ossec/$d ]; then chown -R wazuh:wazuh /var/ossec/$d; fi
      done
      chmod 640 /var/ossec/etc/ossec.conf /var/ossec/etc/client.keys

      if [ ! -s /var/ossec/etc/client.keys ]; then
        /var/ossec/bin/agent-auth -m ${manager} -A ${agentName} -G ${agentGrp}
        chown root:wazuh /var/ossec/etc/client.keys
        chmod 640 /var/ossec/etc/client.keys
      fi
    '';

    serviceConfig = {
      Type = "forking";
      ExecStart = "/var/ossec/bin/wazuh-control start";
      ExecStop = "/var/ossec/bin/wazuh-control stop";
      ExecReload = "/var/ossec/bin/wazuh-control reload";
      KillMode = "process";
      RemainAfterExit = true;
      LimitNOFILE = 65536;
    };
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
    sed -i '0,/\.\/hardware-configuration\.nix/s//.\/wazuh.nix .\/hardware-configuration.nix/' "$CONF"
  elif grep -qE '^\s*imports\s*=\s*\[' "$CONF"; then
    sed -i -E '0,/^(\s*)imports\s*=\s*\[/s//&\n\1  .\/wazuh.nix/' "$CONF"
  elif grep -qE '^\s*imports\b' "$CONF"; then
    echo "✗ imports mají neobvyklý tvar, přidej do nich ./wazuh.nix ručně a spusť skript znovu"
    exit 1
  else
    sed -i -E '0,/^\s*\{\s*$/s//&\n  imports = [ .\/wazuh.nix ];/' "$CONF"
  fi
  grep -q '\./wazuh\.nix' "$CONF" || {
    echo "✗ Nepovedlo se upravit imports, přidej ./wazuh.nix ručně (záloha: $CONF.bak-wazuh)"
    exit 1
  }
  echo "✓ ./wazuh.nix přidán do imports (záloha: $CONF.bak-wazuh)"
fi

# ── 3) Rebuild ────────────────────────────────────────────────────────
if [ -f "$DIR/flake.nix" ]; then
  if [ -d "$DIR/.git" ] && command -v git >/dev/null; then git -C "$DIR" add -A; fi
  nixos-rebuild switch --impure --flake "$DIR#$(hostname)"
else
  nixos-rebuild switch
fi

# ── 4) Kontrola ───────────────────────────────────────────────────────
echo
echo "── stav agenta ──"
systemctl --no-pager --lines=15 status wazuh-agent || true
echo
echo "── log agenta ──"
tail -n 15 /var/ossec/logs/ossec.log 2>/dev/null || true
