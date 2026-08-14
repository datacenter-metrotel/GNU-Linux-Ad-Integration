#!/usr/bin/env bash
#
# ad-join-linux-ubuntu.sh — Une un Ubuntu (22.04/24.04 LTS) a un dominio Active
# Directory y habilita el acceso de los usuarios del dominio por SSH y RDP.
#
# Adaptado de la versión para Debian 13. Diferencias principales frente al
# original (ver comentarios "# [Ubuntu]" a lo largo del script):
#   · Se habilita el repositorio 'universe' (ahí viven sssd, adcli, oddjob,
#     xrdp, pamtester, etc. en Ubuntu).
#   · La persistencia del DNS se hace vía Netplan en vez de /etc/network/
#     interfaces (Ubuntu usa Netplan por defecto, con backend networkd o
#     NetworkManager según sea Server o Desktop).
#   · os-name/os-version que se registran en AD dicen "Ubuntu".
#   · La regla de polkit para colord se genera en el formato nuevo
#     (/etc/polkit-1/rules.d/*.rules) en Ubuntu 23.04+/24.04, donde el
#     formato .pkla ya no se lee; en 22.04 se sigue usando .pkla.
#
# Pregunta siempre por: dominio, usuario y contraseña.
# Deja todo persistente tras reiniciar.
#
# Uso:   sudo ./ad-join-linux-ubuntu.sh
#        sudo ./ad-join-linux-ubuntu.sh --no-rdp     (omitir escritorio + xrdp)
#
set -euo pipefail
# ---------------------------------------------------------------- constantes
DOMAIN_DEFAULT="metrotel.local"
LOG="/var/log/ad-join-linux.log"
INSTALL_RDP=1
# Servidores corporativos OBLIGATORIOS de DNS y NTP (requisito de infraestructura).
# Son la única fuente válida de resolución y de hora para los equipos del dominio.
CORP_DNS=(172.18.194.36 172.18.194.37)
CORP_NTP=(172.18.194.36 172.18.194.37)
# Nombres que delatan una VM clonada de plantilla y que NUNCA deben unirse a AD.
# TPL_SUBSTR: palabras propias de plantillas — se buscan en cualquier posición.
# TPL_EXACT : nombres genéricos — sólo bloquean si son el nombre COMPLETO, para
#             no rechazar hostnames legítimos como 'ubuntu-prod-db'.
TPL_SUBSTR='template|plantilla|changeme|golden|sin-?nombre|untitled'
TPL_EXACT='template|plantilla|debian|debian1[0-9]?|ubuntu|ubuntu2[0-9]\.[0-9]{2}|linux|localhost|localhost\.localdomain|generic|base|golden|clone|vm|new-?vm|newhost|host|server|srv|test|prueba|default|image|snapshot|master|gold'

for arg in "$@"; do
  case "$arg" in
    --no-rdp) INSTALL_RDP=0 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Opción desconocida: $arg" >&2; exit 2 ;;
  esac
done

# ------------------------------------------------------------------ utilidades
c_red=$'\e[31m'; c_grn=$'\e[32m'; c_yel=$'\e[33m'; c_blu=$'\e[36m'; c_bld=$'\e[1m'; c_rst=$'\e[0m'
step()  { echo -e "\n${c_blu}${c_bld}==> $*${c_rst}"; }
ok()    { echo -e "  ${c_grn}[ok]${c_rst} $*"; }
warn()  { echo -e "  ${c_yel}[!]${c_rst}  $*"; }
die()   { echo -e "\n${c_red}${c_bld}[ERROR]${c_rst} $*\n" >&2; exit 1; }

# Copia de seguridad de un fichero antes de modificarlo (una sola vez).
backup() {
  [[ -f "$1" && ! -f "$1.pre-adjoin" ]] && cp -a "$1" "$1.pre-adjoin" && ok "backup: $1.pre-adjoin"
  return 0
}

trap 'echo -e "\n${c_red}Script interrumpido.${c_rst} Revisa $LOG" >&2' INT TERM
[[ $EUID -eq 0 ]] || die "Este script debe ejecutarse como root (usa sudo)."
exec > >(tee -a "$LOG") 2>&1
echo "===== ad-join-linux-ubuntu.sh — $(date -Is) ====="

# ============================================================================
# 1. DATOS DEL DOMINIO (siempre se preguntan)
# ============================================================================
step "Datos del dominio"
read -rp "  Dominio AD [${DOMAIN_DEFAULT}]: " DOMAIN
DOMAIN="${DOMAIN:-$DOMAIN_DEFAULT}"
DOMAIN="${DOMAIN,,}"                      # a minúsculas
REALM="${DOMAIN^^}"                       # el realm Kerberos va en MAYÚSCULAS
[[ "$DOMAIN" == *.* ]] || die "'$DOMAIN' no parece un dominio válido (falta el sufijo, p.ej. .local)."

while :; do
  read -rp "  Usuario con permisos para unir al dominio: " AD_USER
  AD_USER="${AD_USER%%@*}"                # acepta 'juan' o 'juan@dominio'
  [[ -n "$AD_USER" ]] && break
  warn "El usuario no puede estar vacío."
done

while :; do
  read -rsp "  Contraseña de ${AD_USER}@${DOMAIN}: " AD_PASS; echo
  [[ -n "$AD_PASS" ]] && break
  warn "La contraseña no puede estar vacía."
done
# La contraseña nunca se escribe a disco: se pasa al proceso por stdin.
unset HISTFILE

read -rp "  OU para el objeto de equipo (Enter = la que asigne AD): " AD_OU
read -rp "  Grupo AD autorizado a entrar (Enter = todos los del dominio): " AD_GROUP
read -rp "  ¿Ese grupo debe tener sudo? [s/N]: " AD_SUDO
echo
echo "  Dominio : $DOMAIN   (realm $REALM)"
echo "  Usuario : $AD_USER"
echo "  OU      : ${AD_OU:-<por defecto>}"
echo "  Acceso  : ${AD_GROUP:-<todos los usuarios del dominio>}"
echo "  RDP     : $( ((INSTALL_RDP)) && echo "sí (XFCE + xrdp)" || echo no )"
read -rp $'\n  ¿Continuar? [s/N]: ' GO
[[ "${GO,,}" == s* ]] || die "Cancelado por el usuario."

# ============================================================================
# 2. HOSTNAME — nunca el de la plantilla; debe coincidir con DNS/administrador
# ============================================================================
step "Verificando identidad del host (hostname / DNS)"
CUR_SHORT="$(hostname -s 2>/dev/null || cat /etc/hostname)"
PRIMARY_IF="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"
[[ -n "$PRIMARY_IF" ]] || PRIMARY_IF="$(ip -4 -br addr show scope global | awk '{print $1; exit}')"
IP_ADDR="$(ip -4 -o addr show dev "$PRIMARY_IF" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
[[ -n "$IP_ADDR" ]] || die "No se pudo determinar la IP de este host."
ok "interfaz $PRIMARY_IF — IP $IP_ADDR"

# ¿El hostname actual es el de una plantilla / genérico?
is_template() {
  local n="${1,,}"
  n="${n%%.*}"                        # comparar sólo el nombre corto
  [[ -z "$n" ]] && return 0
  [[ "$n" =~ $TPL_SUBSTR ]] && return 0
  [[ "$n" =~ ^($TPL_EXACT)$ ]] && return 0
  return 1
}

# Límites reales de AD para el nombre de equipo:
#
#   · El clásico "15 caracteres" es el límite NetBIOS, heredado y ya NO aplicable.
#     Los AD modernos aceptan nombres más largos y los usan por DNS/LDAP/Kerberos.
#     El hostname y el FQDN se conservan SIEMPRE completos, sin truncar.
#
#   · El único límite duro que queda es el atributo sAMAccountName: para cuentas
#     de equipo es '<nombre>$' y admite 20 caracteres en total (rangeUpper=20 en
#     el esquema; ver `man adcli`). Eso deja 19 caracteres de nombre. Es un límite
#     del esquema de AD, independiente del nivel funcional del dominio.
#
# Si el nombre supera 19, el script mantiene el nombre completo en hostname, DNS y
# SPN de Kerberos, y usa un sAMAccountName recortado sólo para ese atributo.
SAM_MAX=19

# Deriva un sAMAccountName válido (<=19) preservando la parte distintiva del
# nombre. Va quitando segmentos separados por '-' desde la izquierda (ahí están
# los prefijos genéricos tipo 'srv-'), para que el resultado siga siendo legible.
# Si aún así no cabe, recorta por caracteres como último recurso.
derive_sam_name() {
  local n="$1"
  (( ${#n} <= SAM_MAX )) && { printf '%s' "$n"; return; }
  local cand="$n"
  while [[ "$cand" == *-* ]]; do
    cand="${cand#*-}"                 # quita el primer segmento completo
    (( ${#cand} <= SAM_MAX )) && { printf '%s' "$cand"; return; }
  done
  cand="${n: -SAM_MAX}"               # sin guiones aprovechables: recorte duro
  cand="${cand#-}"
  printf '%s' "$cand"
}

# ¿Qué nombre dice el DNS para nuestra IP? (fuente de verdad preferente)
DNS_NAME=""
if command -v dig >/dev/null 2>&1; then
  DNS_NAME="$(dig +short -x "$IP_ADDR" 2>/dev/null | head -1 | sed 's/\.$//')"
else
  DNS_NAME="$(getent hosts "$IP_ADDR" 2>/dev/null | awk '{print $2}' | head -1)"
fi
DNS_SHORT="${DNS_NAME%%.*}"
if [[ -n "$DNS_NAME" ]]; then
  ok "DNS inverso (PTR) de $IP_ADDR → $DNS_NAME"
else
  warn "La IP $IP_ADDR no tiene registro PTR en el DNS."
fi

NEW_SHORT=""
if [[ -n "$DNS_SHORT" ]] && ! is_template "$DNS_SHORT"; then
  # El DNS manda: es lo que el administrador registró.
  if [[ "${DNS_SHORT,,}" != "${CUR_SHORT,,}" ]]; then
    warn "El hostname local ('$CUR_SHORT') NO coincide con el del DNS ('$DNS_SHORT')."
    read -rp "  Usar el del DNS '$DNS_SHORT'? [S/n]: " R
    [[ "${R,,}" == n* ]] || NEW_SHORT="$DNS_SHORT"
  else
    ok "El hostname local coincide con el del DNS: $CUR_SHORT"
    NEW_SHORT="$CUR_SHORT"
  fi
fi

if [[ -z "$NEW_SHORT" ]]; then
  if is_template "$CUR_SHORT"; then
    # Requisito explícito: no unir NUNCA con el nombre de la plantilla.
    echo
    warn "El hostname actual ('$CUR_SHORT') parece el de una PLANTILLA."
    warn "Unir al dominio con este nombre pisaría el objeto de equipo de otra máquina."
    while :; do
      read -rp "  Introduce el hostname definitivo de este servidor: " NEW_SHORT
      NEW_SHORT="${NEW_SHORT%%.*}"
      if [[ -z "$NEW_SHORT" ]]; then
        warn "Obligatorio: no se puede continuar con el nombre de la plantilla."
      elif is_template "$NEW_SHORT"; then
        warn "'$NEW_SHORT' sigue pareciendo un nombre de plantilla/genérico."
      elif [[ ! "$NEW_SHORT" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then
        warn "Nombre inválido: usa sólo caracteres alfanuméricos y '-' (sin empezar ni terminar en '-')."
      elif (( ${#NEW_SHORT} > 63 )); then
        warn "'$NEW_SHORT' excede los 63 caracteres que permite una etiqueta DNS."
      else
        break
      fi
    done
  else
    read -rp "  Hostname a usar [$CUR_SHORT]: " R
    NEW_SHORT="${R:-$CUR_SHORT}"; NEW_SHORT="${NEW_SHORT%%.*}"
  fi
fi

is_template "$NEW_SHORT" && die "Abortado: '$NEW_SHORT' es un nombre de plantilla."
(( ${#NEW_SHORT} <= 63 )) || die "'$NEW_SHORT' excede los 63 caracteres de una etiqueta DNS."

# El hostname completo se mantiene siempre. Sólo sAMAccountName puede necesitar
# recorte, porque el esquema de AD lo limita a 20 caracteres contando el '$'.
SAM_NAME="$(derive_sam_name "$NEW_SHORT")"
ok "nombre de equipo: '$NEW_SHORT' (${#NEW_SHORT} caracteres) — se usa completo"

if [[ "$SAM_NAME" != "$NEW_SHORT" ]]; then
  echo
  warn "'$NEW_SHORT' ocupa ${#NEW_SHORT} caracteres y el atributo sAMAccountName de AD"
  warn "admite 20 contando el '\$' final (máximo 19 de nombre). Es un límite del"
  warn "esquema de AD, no del nivel funcional del dominio."
  echo
  echo "  El nombre COMPLETO se conserva en:"
  echo "    · hostname del sistema      → ${NEW_SHORT}"
  echo "    · FQDN y registro DNS       → ${NEW_SHORT}.${DOMAIN}"
  echo "    · SPN de Kerberos           → host/${NEW_SHORT}.${DOMAIN}"
  echo "    · dNSHostName en AD         → ${NEW_SHORT}.${DOMAIN}"
  echo "  Sólo se recorta el atributo interno:"
  echo "    · sAMAccountName            → ${SAM_NAME}\$"
  echo
  echo "  El login por SSH y RDP usa el FQDN, así que no se ve afectado."
  read -rp "  ¿Continuar con este esquema? [S/n]: " R
  if [[ "${R,,}" == n* ]]; then
    while :; do
      read -rp "  Nombre alternativo (<=19 caracteres para evitar el recorte): " ALT
      ALT="${ALT%%.*}"
      if [[ -z "$ALT" ]]; then warn "No puede estar vacío."
      elif is_template "$ALT"; then warn "'$ALT' parece un nombre de plantilla."
      elif [[ ! "$ALT" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then
        warn "Nombre inválido: alfanuméricos y '-' solamente."
      else
        NEW_SHORT="$ALT"; SAM_NAME="$(derive_sam_name "$ALT")"
        ok "nombre de equipo: '$NEW_SHORT' — sAMAccountName '${SAM_NAME}\$'"
        break
      fi
    done
  fi
fi

FQDN="${NEW_SHORT}.${DOMAIN}"
step "Fijando hostname: $FQDN"
hostnamectl set-hostname "$FQDN"
echo "$FQDN" > /etc/hostname

# /etc/hosts: el FQDN debe resolver a la IP real, no a 127.0.1.1 ni a la plantilla.
backup /etc/hosts
{
  echo "127.0.0.1       localhost"
  echo "${IP_ADDR}      ${FQDN} ${NEW_SHORT}"
  echo ""
  echo "::1     localhost ip6-localhost ip6-loopback"
  echo "ff02::1 ip6-allnodes"
  echo "ff02::2 ip6-allrouters"
} > /etc/hosts
[[ "$(hostname -f 2>/dev/null)" == "$FQDN" ]] \
  && ok "hostname -f → $FQDN" \
  || warn "hostname -f no devuelve $FQDN todavía (se corrige al reiniciar)."

# ---------------------------------------------------------------------------
# [Ubuntu] Repositorio 'universe': ahí viven realmd/sssd/adcli/oddjob/xrdp/
# pamtester. En imágenes cloud/minimal de Ubuntu Server puede no estar
# habilitado, y la instalación de paquetes fallaría más adelante sin este paso.
# ---------------------------------------------------------------------------
step "Comprobando el repositorio 'universe'"
UNIVERSE_OK=0
if grep -Rqs '^deb .*universe' /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null; then
  UNIVERSE_OK=1
elif grep -Rlqs '^Types: deb' /etc/apt/sources.list.d/*.sources 2>/dev/null \
     && grep -Rqs 'Components:.*universe' /etc/apt/sources.list.d/*.sources 2>/dev/null; then
  UNIVERSE_OK=1
fi
if (( UNIVERSE_OK )); then
  ok "'universe' ya está habilitado"
else
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq software-properties-common >/dev/null
  add-apt-repository -y universe >/dev/null
  ok "'universe' habilitado"
fi
apt-get update -qq

# DNS corporativo obligatorio + el dominio AD en el search (necesario para que
# realmd descubra los DCs por registros SRV).
step "Configurando DNS corporativo (${CORP_DNS[*]})"
# systemd-resolved secuestraría resolv.conf apuntando a 127.0.0.53.
if systemctl is-enabled systemd-resolved >/dev/null 2>&1; then
  systemctl disable --now systemd-resolved >/dev/null 2>&1 || true
  ok "systemd-resolved desactivado (gestiona resolv.conf de forma incompatible)"
fi
[[ -L /etc/resolv.conf ]] && { rm -f /etc/resolv.conf; ok "symlink de resolv.conf eliminado"; }
backup /etc/resolv.conf
OTHER_SEARCH="$(awk '/^search/{$1="";print}' /etc/resolv.conf 2>/dev/null \
                | tr ' ' '\n' | grep -vxF "$DOMAIN" | grep -v '^$' | tr '\n' ' ')"
{
  echo "# Generado por ad-join-linux-ubuntu.sh — DNS corporativo obligatorio."
  echo "search ${DOMAIN} ${OTHER_SEARCH}" | sed -E 's/ +$//'
  for ns in "${CORP_DNS[@]}"; do echo "nameserver ${ns}"; done
} > /etc/resolv.conf
ok "resolv.conf fijado: search '$DOMAIN', nameservers ${CORP_DNS[*]}"

# ---------------------------------------------------------------------------
# [Ubuntu] Persistencia del DNS: Ubuntu usa Netplan (no /etc/network/interfaces
# como Debian). Netplan admite 'nameservers' por interfaz y hace merge entre
# ficheros, así que basta con añadir un fichero propio con prioridad alta sin
# tocar el que ya gestiona la IP/DHCP de la interfaz (funciona igual con
# renderer networkd -típico en Server- o NetworkManager -típico en Desktop-).
# Se mantiene además un fallback a /etc/network/interfaces por si el sistema
# aún usa ifupdown (poco común en Ubuntu, pero posible en instalaciones
# mínimas o contenedores).
# ---------------------------------------------------------------------------
if [[ -d /etc/netplan ]] && command -v netplan >/dev/null 2>&1; then
  step "Persistiendo el DNS corporativo en Netplan (interfaz $PRIMARY_IF)"
  NP_ADDRS_RAW="$(printf '%s, ' "${CORP_DNS[@]}")"
  NP_ADDRS="[${NP_ADDRS_RAW%, }]"
  NP_SEARCH_LIST=("$DOMAIN" $OTHER_SEARCH)
  NP_SEARCH_RAW="$(printf '%s, ' "${NP_SEARCH_LIST[@]}")"
  NP_SEARCH="[${NP_SEARCH_RAW%, }]"
  NETPLAN_FILE="/etc/netplan/90-ad-domain-dns.yaml"
  backup "$NETPLAN_FILE"
  cat > "$NETPLAN_FILE" <<EOF
# Generado por ad-join-linux-ubuntu.sh — DNS corporativo obligatorio.
# Sólo añade 'nameservers' a la interfaz; Netplan combina esto con el resto
# de la configuración (DHCP, etc.) que ya exista en otros ficheros.
network:
  version: 2
  ethernets:
    ${PRIMARY_IF}:
      nameservers:
        addresses: ${NP_ADDRS}
        search: ${NP_SEARCH}
EOF
  chmod 600 "$NETPLAN_FILE"
  if netplan generate 2>&1 | sed 's/^/  /' && netplan apply 2>&1 | sed 's/^/  /'; then
    ok "Netplan aplicado: DNS corporativo persistente en $NETPLAN_FILE"
  else
    warn "netplan apply devolvió error; revisa $NETPLAN_FILE manualmente."
  fi
elif [[ -f /etc/network/interfaces ]] && grep -qE '^\s*iface .* inet static' /etc/network/interfaces; then
  # Fallback ifupdown (sistemas sin Netplan).
  backup /etc/network/interfaces
  if grep -qE '^\s*dns-nameservers' /etc/network/interfaces; then
    sed -i -E "s/^(\s*)dns-nameservers\s+.*/\1dns-nameservers ${CORP_DNS[*]}/" /etc/network/interfaces
  else
    sed -i -E "/^\s*iface .* inet static/a \\\tdns-nameservers ${CORP_DNS[*]}" /etc/network/interfaces
  fi
  if grep -qE '^\s*dns-search' /etc/network/interfaces; then
    sed -i -E "s/^(\s*)dns-search\s+.*/\1dns-search ${DOMAIN} ${OTHER_SEARCH}/" /etc/network/interfaces
    sed -i -E 's/^(\s*dns-search .*[^ ]) +$/\1/' /etc/network/interfaces
  else
    sed -i -E "/^\s*iface .* inet static/a \\\tdns-search ${DOMAIN}" /etc/network/interfaces
  fi
  ok "DNS persistido en /etc/network/interfaces (sobrevive al reinicio)"
else
  warn "No se encontró Netplan ni /etc/network/interfaces con IP estática."
  warn "El DNS quedará fijado sólo en /etc/resolv.conf; verifícalo tras reiniciar."
fi

# Comprobación real: sin SRV resolubles, realmd no puede unir al dominio.
if ! dig +short "_ldap._tcp.${DOMAIN}" SRV @"${CORP_DNS[0]}" 2>/dev/null | grep -q .; then
  warn "El DNS ${CORP_DNS[0]} no devuelve registros SRV para '_ldap._tcp.${DOMAIN}'."
  warn "Verifica que '$DOMAIN' es el dominio AD correcto."
  read -rp "  ¿Continuar de todas formas? [s/N]: " R
  [[ "${R,,}" == s* ]] || die "Cancelado: sin registros SRV no se puede unir al dominio."
else
  ok "registros SRV del dominio resueltos correctamente"
fi

# ============================================================================
# 3. RELOJ — Kerberos rechaza desfases > 300 s
# ============================================================================
step "Sincronizando el reloj con el NTP corporativo (${CORP_NTP[*]})"
echo "  Fuentes de hora: ${CORP_NTP[*]}"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq chrony >/dev/null
systemctl disable --now systemd-timesyncd >/dev/null 2>&1 || true
mkdir -p /etc/chrony/conf.d
{
  echo "# Generado por ad-join-linux-ubuntu.sh — NTP corporativo obligatorio."
  # 'trust': Kerberos compara contra el reloj del dominio, no contra UTC. El host
  # debe seguir al NTP corporativo aunque se desvíe de la hora real, o la
  # autenticación falla con KRB5KRB_AP_ERR_SKEW.
  for dc in "${CORP_NTP[@]}"; do echo "server ${dc} iburst trust prefer"; done
  echo "makestep 1.0 -1"        # corrige saltos grandes siempre, no solo al arrancar
} > /etc/chrony/conf.d/ad-domain.conf
# Los pool/server públicos de la config por defecto compiten con los DCs: chrony
# marcaría a los DCs como 'falseticker' y no seguiría la hora del dominio.
if grep -qE '^\s*(pool|server)\s' /etc/chrony/chrony.conf 2>/dev/null; then
  backup /etc/chrony/chrony.conf
  sed -i -E 's/^(\s*(pool|server)\s.*)$/# desactivado por ad-join-linux-ubuntu.sh: \1/' /etc/chrony/chrony.conf
  ok "fuentes NTP públicas desactivadas (la hora la marca el dominio)"
fi
systemctl enable chrony >/dev/null 2>&1
systemctl restart chrony
sleep 3
chronyc -a makestep >/dev/null 2>&1 || true   # salto inmediato
sleep 2
SKEW="$(chronyc tracking 2>/dev/null | awk -F'[ ]+' '/System time/{print $4}')"
[[ -n "$SKEW" ]] && ok "desfase respecto a las fuentes configuradas: ${SKEW}s"
# Lo que decide si Kerberos funciona es el desfase contra el reloj del dominio,
# no contra la hora UTC real. Se mide por NTP contra el servidor corporativo.
DC1="${CORP_NTP[0]}"
DC_SKEW="$(timeout 8 python3 -c "
import socket,struct,time,sys
try:
    s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(4)
    s.sendto(b'\x1b'+47*b'\0',(sys.argv[1],123)); b=time.time()
    d=s.recv(48); t=struct.unpack('!12I',d)[10]-2208988800
    print('%.1f' % abs(t-b))
except Exception: print('')
" "$DC1" 2>/dev/null)"
if [[ -n "$DC_SKEW" ]]; then
  if awk -v s="$DC_SKEW" 'BEGIN{exit !(s>120)}'; then
    warn "Desfase con el DC ${DC1}: ${DC_SKEW}s — Kerberos falla por encima de 300s."
    warn "Espera a que chrony converja con el DC o revisa la hora del propio DC."
    read -rp "  ¿Continuar de todas formas? [s/N]: " R
    [[ "${R,,}" == s* ]] || die "Corrige la hora y vuelve a ejecutar el script."
  else
    ok "desfase con el DC ${DC1}: ${DC_SKEW}s (dentro del margen de Kerberos)"
  fi
else
  warn "No se pudo medir el desfase contra el DC por NTP (puerto 123/udp filtrado)."
fi
ok "chrony activo y habilitado al arranque"

# ============================================================================
# 4. PAQUETES
# ============================================================================
step "Instalando paquetes de integración con AD"
# Pre-sembrar el realm evita que krb5-config abra un diálogo interactivo.
echo "krb5-config krb5-config/default_realm string ${REALM}" | debconf-set-selections
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  realmd sssd sssd-tools libnss-sss libpam-sss \
  adcli samba-common-bin krb5-user \
  oddjob oddjob-mkhomedir packagekit \
  dnsutils openssh-server >/dev/null
ok "realmd, sssd, adcli, krb5, oddjob-mkhomedir instalados"

# ============================================================================
# 5. UNIÓN AL DOMINIO
# ============================================================================
step "Comprobando visibilidad del dominio $DOMAIN"
realm discover "$DOMAIN" >/dev/null 2>&1 \
  || die "No se ve el dominio '$DOMAIN'. Revisa DNS y conectividad con los DCs."
realm discover "$DOMAIN" 2>/dev/null | sed 's/^/  /' | head -8

if realm list 2>/dev/null | grep -qiE "^${DOMAIN}\$|domain-name: ${DOMAIN}"; then
  warn "Este equipo ya está unido a $DOMAIN."
  read -rp "  ¿Salir del dominio y volver a unir? [s/N]: " R
  if [[ "${R,,}" == s* ]]; then
    printf '%s' "$AD_PASS" | realm leave "$DOMAIN" -U "$AD_USER" --unattended 2>&1 | sed 's/^/  /' || true
  else
    SKIP_JOIN=1
  fi
fi

if [[ -z "${SKIP_JOIN:-}" ]]; then
  step "Uniendo $FQDN al dominio $DOMAIN"
  # --host-fqdn lleva el FQDN COMPLETO sin truncar (es lo que registra dNSHostName
  # y lo que valida Kerberos). --computer-name lleva el sAMAccountName, recortado
  # sólo si el esquema de AD lo exige. --add-service-principal garantiza el SPN
  # con el nombre largo, que es el que usan SSH y RDP.
  JOIN_ARGS=( "$DOMAIN" -U "$AD_USER" --unattended
              --computer-name="$SAM_NAME"
              --os-name="Ubuntu"
              --os-version="$(. /etc/os-release && echo "$VERSION_ID")" )
  [[ -n "$AD_OU" ]] && JOIN_ARGS+=( --computer-ou="$AD_OU" )
  if printf '%s' "$AD_PASS" | realm join "${JOIN_ARGS[@]}" 2>&1 | sed 's/^/  /'; then
    ok "unido al dominio (sAMAccountName: ${SAM_NAME}\$)"
  else
    die "Falló la unión al dominio. Causas habituales: credenciales sin permiso de join, OU inexistente, desfase de reloj o el objeto de equipo '$SAM_NAME' ya existe en AD. Detalle en $LOG"
  fi
  # realm no expone --add-service-principal. 'adcli update' sí, y se autentica con
  # el keytab del propio equipo (creado por el join), no con usuario/contraseña.
  # Esto asegura que el SPN lleva el FQDN completo: es lo que Kerberos valida en
  # el login por SSH y RDP.
  step "Registrando SPN con el nombre completo ($FQDN)"
  if adcli update --domain="$DOMAIN" --host-fqdn="$FQDN" \
       --computer-name="$SAM_NAME" \
       --add-service-principal="host/${FQDN}" 2>&1 | sed 's/^/  /'; then
    ok "SPN host/${FQDN} registrado"
  else
    warn "no se pudo registrar el SPN host/${FQDN} (puede que ya exista por el join)"
  fi
fi

[[ -f /etc/krb5.keytab ]] && ok "keytab creado: /etc/krb5.keytab" || warn "no se generó /etc/krb5.keytab"
# El keytab debe contener el FQDN completo o Kerberos fallará en el login.
if [[ -f /etc/krb5.keytab ]]; then
  if klist -k /etc/krb5.keytab 2>/dev/null | grep -qiF "$FQDN"; then
    ok "el keytab contiene principales con el FQDN completo"
  else
    warn "el keytab no muestra el FQDN '$FQDN'. Principales presentes:"
    klist -k /etc/krb5.keytab 2>/dev/null | awk 'NR>3{print "      "$2}' | sort -u | head -8
  fi
fi

# ============================================================================
# 6. SSSD — resolución de usuarios y autenticación
# ============================================================================
step "Configurando SSSD"
read -rp "  ¿Permitir login con nombre corto ('juan' en vez de 'juan@${DOMAIN}')? [S/n]: " R
if [[ "${R,,}" == n* ]]; then USE_FQN="True"; else USE_FQN="False"; fi

backup /etc/sssd/sssd.conf
SSSD_CONF="/etc/sssd/sssd.conf"
# realmd crea la sección con la capitalización que devuelve el propio AD
# (p. ej. '[domain/Metrotel.local]'), que NO tiene por qué coincidir con lo que
# escribió el usuario. Hay que detectarla del fichero: si se asume minúsculas,
# el sed no encuentra la sección y las claves nunca se insertan — en silencio.
DOM_SECTION="$(grep -oP '^\[domain/\K[^]]+' "$SSSD_CONF" 2>/dev/null | head -1)"
[[ -n "$DOM_SECTION" ]] || die "No se encontró ninguna sección [domain/...] en $SSSD_CONF"
ok "sección de configuración detectada: [domain/${DOM_SECTION}]"

set_sssd() {  # set_sssd <clave> <valor> — dentro de la sección [domain/...]
  local k="$1" v="$2"
  if grep -qE "^\s*${k}\s*=" "$SSSD_CONF"; then
    sed -i -E "s|^\s*${k}\s*=.*|${k} = ${v}|" "$SSSD_CONF"
  else
    # sed sin -E y con la sección literal: evita que los '.' del dominio actúen
    # como comodines y que la capitalización real no coincida.
    sed -i "\|^\[domain/${DOM_SECTION}\]|a ${k} = ${v}" "$SSSD_CONF"
  fi
  # Verificación explícita: una inserción fallida dejaría a los usuarios fuera.
  grep -qE "^\s*${k}\s*=" "$SSSD_CONF" || warn "no se pudo fijar '${k}' en $SSSD_CONF"
}
set_sssd use_fully_qualified_names "$USE_FQN"
set_sssd fallback_homedir "/home/%u"
set_sssd default_shell "/bin/bash"
set_sssd cache_credentials "True"                 # permite login si el DC no responde
set_sssd krb5_store_password_if_offline "True"
# 'permissive' registra pero no aplica la GPO de inicio de sesión. En 'enforcing'
# (el valor por defecto de SSSD) un AD sin la GPO configurada para Linux deja
# fuera a TODOS los usuarios aunque la unión sea correcta.
set_sssd ad_gpo_access_control "permissive"
# Si una GPO del dominio no es legible por la cuenta de equipo, SSSD la trata
# como un error y rechaza el login con "Access denied ... 4 (System error)",
# que sshd traduce al engañoso "User account has expired". Ignorar las GPO
# ilegibles evita ese falso rechazo (habitual con GPOs heredadas de Windows).
set_sssd ad_gpo_ignore_unreadable "True"
set_sssd ldap_id_mapping "True"
# ad_hostname siempre: fija el FQDN con el que SSSD se identifica ante AD,
# necesario porque el hostname local y sAMAccountName pueden diferir.
set_sssd ad_hostname "$FQDN"
if [[ "$SAM_NAME" != "$NEW_SHORT" ]]; then
  set_sssd ldap_sasl_authid "${SAM_NAME}\$@${REALM}"
  ok "SSSD apuntado al objeto de equipo '${SAM_NAME}\$' con FQDN '$FQDN'"
fi
chown root:root "$SSSD_CONF"; chmod 600 "$SSSD_CONF"

# En Ubuntu (como en Debian 13) los responders de SSSD se activan por socket.
# Si además aparecen en la línea 'services' de sssd.conf,
# 'sssd_check_socket_activated_responders' aborta con status=17 y
# sssd-nss/sssd-pam/sssd-*.socket quedan en 'failed', dejando el sistema
# 'degraded' en cada arranque (el login sigue funcionando porque sssd.service
# arranca los responders por su cuenta, así que el fallo pasa desapercibido).
# Se elimina la línea para dejar la activación a systemd.
if grep -qE '^\s*services\s*=' "$SSSD_CONF"; then
  sed -i -E '/^\s*services\s*=/d' "$SSSD_CONF"
  ok "eliminada la línea 'services' de $SSSD_CONF (colisiona con los sockets de systemd)"
fi

systemctl enable sssd >/dev/null 2>&1
systemctl reset-failed 'sssd-*.socket' >/dev/null 2>&1 || true
systemctl restart sssd
sleep 4
systemctl is-active --quiet sssd && ok "sssd activo y habilitado al arranque" || die "sssd no arrancó. Revisa: journalctl -u sssd"

# 'pac' es implícito con id_provider=ad: SSSD lo arranca siempre él mismo, por lo
# que su socket colisiona incluso sin la línea 'services'. Se deshabilita según
# recomienda el propio mensaje de error de SSSD.
# awk: systemd prefija las unidades fallidas con '●', así que se busca el campo
# que acaba en '.socket' en lugar de asumir una posición fija de columna.
for SOCK in $(systemctl list-units --state=failed --all --no-legend 'sssd-*.socket' 2>/dev/null \
                | awk '{for(i=1;i<=NF;i++) if($i ~ /\.socket$/){print $i; break}}'); do
  systemctl disable --now "$SOCK" >/dev/null 2>&1
  systemctl reset-failed "$SOCK" >/dev/null 2>&1
  ok "socket redundante '$SOCK' deshabilitado (el responder lo gestiona sssd)"
done

# ============================================================================
# 7. PAM — creación automática del home
# ============================================================================
step "Configurando PAM (home automático al primer login)"
DEBIAN_FRONTEND=noninteractive pam-auth-update --enable mkhomedir >/dev/null 2>&1 \
  && ok "mkhomedir habilitado" || warn "no se pudo habilitar mkhomedir automáticamente"
DEBIAN_FRONTEND=noninteractive pam-auth-update --enable sss >/dev/null 2>&1 || true
grep -q "pam_sss.so" /etc/pam.d/common-auth && ok "pam_sss activo en common-auth" \
  || warn "pam_sss no aparece en common-auth — revisa 'pam-auth-update'"
systemctl enable --now oddjobd >/dev/null 2>&1 || true

# ============================================================================
# 8. CONTROL DE ACCESO
# ============================================================================
step "Control de acceso"
if [[ -n "$AD_GROUP" ]]; then
  realm deny --all
  if realm permit -g "${AD_GROUP}@${DOMAIN}" 2>&1 | sed 's/^/  /'; then
    ok "acceso restringido al grupo '${AD_GROUP}'"
  else
    warn "No se pudo aplicar el permiso al grupo '${AD_GROUP}'. Verifica que exista en AD."
    warn "Ahora mismo NADIE puede entrar. Corrígelo con: realm permit -g 'GRUPO@${DOMAIN}'"
  fi
else
  realm permit --all && ok "acceso permitido a todos los usuarios del dominio"
fi

if [[ "${AD_SUDO,,}" == s* && -n "$AD_GROUP" ]]; then
  printf '%%%s@%s ALL=(ALL:ALL) ALL\n' "$AD_GROUP" "$DOMAIN" > /etc/sudoers.d/ad-domain-admins
  chmod 440 /etc/sudoers.d/ad-domain-admins
  visudo -cf /etc/sudoers.d/ad-domain-admins >/dev/null \
    && ok "sudo concedido a '${AD_GROUP}'" \
    || { rm -f /etc/sudoers.d/ad-domain-admins; warn "sintaxis de sudoers inválida: regla descartada"; }
fi

# ============================================================================
# 9. SSH
# ============================================================================
step "Configurando SSH para usuarios del dominio"
backup /etc/ssh/sshd_config
mkdir -p /etc/ssh/sshd_config.d
# Fichero propio en sshd_config.d: sobrevive a actualizaciones del paquete.
cat > /etc/ssh/sshd_config.d/50-ad-domain.conf <<EOF
# Generado por ad-join-linux-ubuntu.sh
UsePAM yes
PasswordAuthentication yes
# Necesario para los diálogos de PAM: contraseña caducada, cambio obligatorio, MFA.
KbdInteractiveAuthentication yes
# SSO con ticket Kerberos desde equipos del dominio.
GSSAPIAuthentication yes
GSSAPICleanupCredentials yes
EOF
# sshd_config.d sólo se aplica si el fichero principal lo incluye. Ubuntu ya lo
# incluye por defecto desde 20.04, pero se comprueba por si el fichero fue
# editado a mano.
grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config \
  || sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
sshd -t || die "La configuración de sshd es inválida. NO se recargó (tu sesión sigue viva). Revisa $LOG"
systemctl enable ssh >/dev/null 2>&1
systemctl reload ssh
ok "sshd configurado, validado y habilitado al arranque"

# ============================================================================
# 10. RDP
# ============================================================================
if ((INSTALL_RDP)); then
  step "Instalando escritorio XFCE y xrdp"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    xfce4 xfce4-goodies dbus-x11 xorg \
    xrdp xorgxrdp policykit-1 >/dev/null 2>&1 \
   || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        xfce4 dbus-x11 xorg xrdp xorgxrdp >/dev/null
  ok "XFCE + xrdp instalados"

  # xrdp necesita leer la clave TLS que genera al instalarse.
  adduser xrdp ssl-cert >/dev/null 2>&1 || true

  # Sesión por defecto para CUALQUIER usuario (los del dominio no tienen ~/.xsession).
  cat > /etc/xrdp/startwm.sh <<'EOF'
#!/bin/sh
# Generado por ad-join-linux-ubuntu.sh
if [ -r /etc/default/locale ]; then
  . /etc/default/locale
  export LANG LANGUAGE
fi
# Evita que XFCE arranque sin bus de sesión sobre RDP.
exec dbus-launch --exit-with-session startxfce4
EOF
  chmod 755 /etc/xrdp/startwm.sh

  # PAM: xrdp-sesman debe pasar por pam_sss para autenticar contra AD.
  if [[ -f /etc/pam.d/xrdp-sesman ]]; then
    grep -qE '^@include\s+common-auth' /etc/pam.d/xrdp-sesman \
      && ok "xrdp-sesman usa common-auth (autenticación AD vía pam_sss)" \
      || warn "revisa /etc/pam.d/xrdp-sesman: debería incluir common-auth"
  fi

  # ---------------------------------------------------------------------
  # [Ubuntu] Sin esto, XFCE sobre RDP muestra diálogos de autenticación en
  # bucle para colord. polkit >= 0.106 (Ubuntu 23.04+, incluido 24.04 LTS)
  # eliminó el soporte de ficheros .pkla: las reglas locales se escriben
  # ahora en JavaScript bajo /etc/polkit-1/rules.d/. En 22.04 LTS (polkit
  # ~0.105) el formato .pkla clásico todavía funciona. Se detecta la
  # versión instalada y se genera el formato correspondiente.
  # ---------------------------------------------------------------------
  step "Permitiendo colord sin diálogos repetidos (compatibilidad polkit)"
  PKVER="$(dpkg-query -W -f='${Version}' policykit-1 2>/dev/null || echo 0)"
  if dpkg --compare-versions "$PKVER" ge "0.106" 2>/dev/null; then
    mkdir -p /etc/polkit-1/rules.d
    cat > /etc/polkit-1/rules.d/45-allow-colord.rules <<'EOF'
// Generado por ad-join-linux-ubuntu.sh
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.color-manager.") == 0) {
        return polkit.Result.YES;
    }
});
EOF
    ok "regla polkit creada en /etc/polkit-1/rules.d/45-allow-colord.rules"
  else
    mkdir -p /etc/polkit-1/localauthority/50-local.d
    cat > /etc/polkit-1/localauthority/50-local.d/45-allow-colord.pkla <<'EOF'
[Allow colord for all users]
Identity=unix-user:*
Action=org.freedesktop.color-manager.create-device;org.freedesktop.color-manager.create-profile;org.freedesktop.color-manager.delete-device;org.freedesktop.color-manager.delete-profile;org.freedesktop.color-manager.modify-device;org.freedesktop.color-manager.modify-profile
ResultAny=no
ResultInactive=no
ResultActive=yes
EOF
    ok "regla polkit creada en /etc/polkit-1/localauthority/50-local.d/45-allow-colord.pkla"
  fi

  systemctl enable xrdp xrdp-sesman >/dev/null 2>&1
  systemctl restart xrdp xrdp-sesman
  sleep 2
  systemctl is-active --quiet xrdp \
    && ok "xrdp activo en el puerto 3389 y habilitado al arranque" \
    || warn "xrdp no arrancó. Revisa: journalctl -u xrdp"
fi

# ============================================================================
# 11. VERIFICACIÓN
# ============================================================================
step "Verificación"
for svc in sssd chrony ssh oddjobd $( ((INSTALL_RDP)) && echo "xrdp xrdp-sesman" ); do
  printf '  %-14s ' "$svc"
  act=$(systemctl is-active "$svc" 2>/dev/null || echo inactive)
  ena=$(systemctl is-enabled "$svc" 2>/dev/null || echo disabled)
  if [[ "$act" == active && "$ena" == enabled ]]; then
    echo -e "${c_grn}activo + habilitado al arranque${c_rst}"
  else
    echo -e "${c_yel}${act} / ${ena}${c_rst}"
  fi
done
echo
echo "  Dominio : $(realm list 2>/dev/null | head -1 || echo '??')"
echo "  Hostname: $(hostname -f 2>/dev/null || hostname)"
echo "  IP      : $IP_ADDR"

# Prueba real de resolución: si esto falla, los usuarios no podrán entrar.
step "Probando resolución de un usuario del dominio"
if [[ "$USE_FQN" == "True" ]]; then TEST_ID="${AD_USER}@${DOMAIN}"; else TEST_ID="$AD_USER"; fi
if id "$TEST_ID" >/dev/null 2>&1; then
  ok "id $TEST_ID → resuelto correctamente"
else
  warn "No se pudo resolver '$TEST_ID' contra AD."
  warn "Diagnostica con:  sssctl domain-status ${DOM_SECTION}  y  journalctl -u sssd -n 50"
fi

# Ticket Kerberos: confirma que el keytab y el realm son correctos.
if printf '%s' "$AD_PASS" | kinit "${AD_USER}@${REALM}" >/dev/null 2>&1; then
  ok "kinit correcto: Kerberos operativo"
  kdestroy >/dev/null 2>&1 || true
else
  warn "kinit falló — revisa el realm ($REALM) y el desfase de reloj."
fi
unset AD_PASS

# Resolver al usuario NO garantiza que pueda entrar: la fase 'account' de PAM
# es una comprobación distinta y es donde fallan las GPO ilegibles y las reglas
# de acceso. Se prueba de verdad, porque sshd disfraza ese fallo como
# "User account has expired", que envía a diagnosticar en la dirección errónea.
step "Probando la autorización real de login (fase 'account' de PAM)"
if ! command -v pamtester >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq pamtester >/dev/null 2>&1 || true
fi
if command -v pamtester >/dev/null 2>&1; then
  if pamtester sshd "$TEST_ID" acct_mgmt >/dev/null 2>&1; then
    ok "PAM autoriza el login de '$TEST_ID' — SSH y RDP operativos"
    echo -e "\n${c_grn}${c_bld}Integración con AD verificada de extremo a extremo.${c_rst}"
  else
    warn "PAM RECHAZA el login de '$TEST_ID' aunque el usuario se resuelva bien."
    echo "     Detalle:"
    pamtester sshd "$TEST_ID" acct_mgmt 2>&1 | sed 's/^/       /' | head -4
    echo "     Causas más frecuentes:"
    echo "       · GPO ilegible → ya mitigado con ad_gpo_ignore_unreadable = True"
    echo "       · el usuario no está en el grupo permitido → realm permit -g 'GRUPO@${DOMAIN}'"
    echo "       · revisa:  journalctl -u sssd | grep -i denied"
  fi
else
  warn "pamtester no disponible: no se pudo verificar la autorización."
  warn "Compruébalo manualmente con un SSH real antes de dar por buena la instalación."
fi

cat <<EOF
${c_bld}Cómo entran los usuarios${c_rst}
  SSH : ssh ${TEST_ID}@${IP_ADDR}
$( ((INSTALL_RDP)) && echo "  RDP : ${IP_ADDR}:3389  (usuario: ${TEST_ID})" )

${c_bld}Notas${c_rst}
  · Log completo: $LOG
  · Copias de seguridad: ficheros *.pre-adjoin
  · SSSD está en 'ad_gpo_access_control = permissive'. Cuando AD tenga la GPO
    de inicio de sesión configurada para Linux, cámbialo a 'enforcing' en
    /etc/sssd/sssd.conf.
$( [[ -z "$AD_GROUP" ]] && echo "  · Ahora puede entrar CUALQUIER usuario del dominio. Para restringir:
    realm deny --all && realm permit -g 'GRUPO@${DOMAIN}'" )
  · Si la IP no tenía PTR, pide al administrador de DNS los registros A y PTR
    de ${FQDN} → ${IP_ADDR}.
  · El DNS corporativo quedó fijado tanto en /etc/resolv.conf como en Netplan
    (/etc/netplan/90-ad-domain-dns.yaml). Si tras reiniciar el DNS cambiara,
    revisa ese fichero con: netplan get

${c_bld}Antes de reiniciar${c_rst}: prueba el acceso en una terminal NUEVA sin cerrar
esta sesión. Todos los servicios quedan habilitados y persisten al reinicio.
EOF
