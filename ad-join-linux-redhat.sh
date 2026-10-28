#!/usr/bin/env bash
#
# ad-join-linux-redhat.sh — Une un RHEL/CentOS Stream/Rocky/AlmaLinux (8 o 9) a
# un dominio Active Directory y habilita el acceso de los usuarios del dominio
# por SSH y RDP.
#
# Adaptado de la versión para Debian 13. Diferencias principales frente a la
# familia Debian/Ubuntu (ver comentarios "# [RHEL]" a lo largo del script):
#   · dnf en vez de apt-get; nombres de paquete propios de RHEL (krb5-workstation,
#     samba-common-tools, bind-utils, etc.).
#   · Se habilitan EPEL y CodeReady Builder/CRB/PowerTools (ahí viven xrdp,
#     xorgxrdp, pamtester y el grupo Xfce).
#   · authselect en vez de pam-auth-update para activar SSSD + creación de home.
#   · El DNS corporativo se fija a nivel de conexión de NetworkManager (nmcli),
#     no como fichero estático: RHEL no usa systemd-resolved y NetworkManager
#     reescribe /etc/resolv.conf según el perfil de conexión, así que hay que
#     configurarlo ahí para que sobreviva al reinicio.
#   · Se abren los puertos necesarios en firewalld (SSH y, si aplica, RDP/3389).
#   · El servicio SSH se llama 'sshd' (no 'ssh').
#   · Se avisa si SELinux está en modo enforcing (viene así por defecto).
#
# Pregunta siempre por: dominio, usuario y contraseña.
# Deja todo persistente tras reiniciar.
#
# Uso:   sudo ./ad-join-linux-redhat.sh            (sólo AD + SSH; SIN escritorio)
#        sudo ./ad-join-linux-redhat.sh --rdp      (añade escritorio XFCE + xrdp)
#
# ---------------------------------------------------------------------------
# Versión endurecida (hardening frente a 'set -euo pipefail'):
#   · Se instalan temprano bind-utils (dig) y python3, que el script usa ANTES
#     de la instalación principal de paquetes (sección 1.5).
#   · Se blindan con '|| true' los pipelines de extracción/diagnóstico donde un
#     grep sin coincidencias, un 'head' que corta la tubería (SIGPIPE) o un
#     'timeout' podían devolver estado !=0 y abortar el script en silencio por
#     culpa de 'pipefail' (p.ej. OTHER_SEARCH, 'realm discover | head', DOM_SECTION,
#     la medición de desfase NTP, etc.). El valor vacío es el resultado correcto
#     en esos casos y los chequeos posteriores ya lo contemplan.
#   · chrony: se añade 'confdir /etc/chrony.d' a /etc/chrony.conf (RHEL no lo
#     trae por defecto y ad-domain.conf quedaba sin cargar, dejando al equipo
#     sin fuentes NTP) y se verifica que chrony seleccione al NTP corporativo.
# ---------------------------------------------------------------------------
set -euo pipefail
# ---------------------------------------------------------------- constantes
DOMAIN_DEFAULT="metrotel.local"
LOG="/var/log/ad-join-linux.log"
# Por defecto NO se instala escritorio/RDP (servidores headless). Se activa con --rdp.
INSTALL_RDP=0
# Servidores corporativos OBLIGATORIOS de DNS y NTP (requisito de infraestructura).
# Son la única fuente válida de resolución y de hora para los equipos del dominio.
CORP_DNS=(172.18.194.36 172.18.194.37)
CORP_NTP=(172.18.194.36 172.18.194.37)
# Nombres que delatan una VM clonada de plantilla y que NUNCA deben unirse a AD.
# TPL_SUBSTR: palabras propias de plantillas — se buscan en cualquier posición.
# TPL_EXACT : nombres genéricos — sólo bloquean si son el nombre COMPLETO, para
#             no rechazar hostnames legítimos como 'rhel-prod-db'.
TPL_SUBSTR='template|plantilla|changeme|golden|sin-?nombre|untitled'
TPL_EXACT='template|plantilla|debian|ubuntu|linux|rhel|redhat|red-?hat|centos|rocky|alma|almalinux|fedora|localhost|localhost\.localdomain|generic|base|golden|clone|vm|new-?vm|newhost|host|server|srv|test|prueba|default|image|snapshot|master|gold'

for arg in "$@"; do
  case "$arg" in
    --rdp)    INSTALL_RDP=1 ;;
    --no-rdp) INSTALL_RDP=0 ;;   # aceptado por compatibilidad (ya es el valor por defecto)
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
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
echo "===== ad-join-linux-redhat.sh — $(date -Is) ====="

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
# 1.5 REPOSITORIOS Y DEPENDENCIAS — se habilitan EPEL + CRB/PowerTools y se
# instalan POR ADELANTADO todos los paquetes que provee cada comando que el
# script va a usar (dig, python3, hostname, realm, adcli, kinit/klist,
# authselect, chronyc, getenforce, pamtester, nmcli, sshd y —salvo --no-rdp—
# xrdp/XFCE). Así ningún paso posterior se topa con un binario ausente. Es
# idempotente: lo que ya está instalado simplemente se omite. Las instalaciones
# puntuales que quedan más abajo pasan a ser redes de seguridad (no-ops rápidos).
# ============================================================================
step "Habilitando repositorios de paquetes (EPEL + CRB/PowerTools)"
dnf install -y -q dnf-plugins-core >/dev/null
if ! rpm -q epel-release >/dev/null 2>&1; then
  if ! dnf install -y -q epel-release >/dev/null 2>&1; then
    RHEL_VER="$(rpm -E %rhel)"
    dnf install -y -q "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${RHEL_VER}.noarch.rpm" >/dev/null \
      || warn "No se pudo instalar epel-release automáticamente. xrdp/pamtester podrían fallar más adelante."
  fi
  ok "EPEL instalado"
else
  ok "EPEL ya estaba instalado"
fi
if grep -qi '^NAME="Red Hat' /etc/os-release 2>/dev/null; then
  # RHEL con suscripción activa.
  subscription-manager repos --enable "codeready-builder-for-rhel-$(rpm -E %rhel)-$(arch)-rpms" >/dev/null 2>&1 \
    && ok "CodeReady Builder habilitado" \
    || warn "No se pudo habilitar CodeReady Builder (¿sistema sin suscripción activa?). xrdp podría fallar al resolver dependencias."
else
  # Rocky/Alma/CentOS Stream.
  dnf config-manager --set-enabled crb        >/dev/null 2>&1 \
    || dnf config-manager --set-enabled powertools >/dev/null 2>&1 \
    || warn "No se encontró el repo crb/powertools. Actívalo manualmente si xrdp falla al instalar."
  ok "repositorio de dependencias (crb/powertools) habilitado"
fi
dnf makecache -q >/dev/null 2>&1 || true

step "Instalando por adelantado todas las dependencias del script"
# Cada comando del script → su paquete (los binarios de coreutils/util-linux/
# systemd/rpm/dnf/NetworkManager ya vienen en el sistema base).
PKGS=(
  bind-utils python3 hostname iproute sudo
  chrony openssh-server
  realmd sssd sssd-tools sssd-common
  adcli samba-common-tools samba-common krb5-workstation
  oddjob oddjob-mkhomedir authselect
  openldap-clients policycoreutils-python-utils
  libselinux-utils pamtester
)
# Escritorio remoto (sólo si NO se pasó --no-rdp).
if ((INSTALL_RDP)); then
  PKGS+=( xrdp xorgxrdp dbus-x11 xorg-x11-server-Xorg polkit )
fi
dnf install -y -q "${PKGS[@]}" >/dev/null 2>&1 \
  && ok "dependencias instaladas por adelantado (${#PKGS[@]} paquetes solicitados)" \
  || warn "algún paquete del lote no se pudo instalar; se reintentará en su sección correspondiente."
if ((INSTALL_RDP)); then
  dnf groupinstall -y -q "Xfce" >/dev/null 2>&1 \
    || dnf install -y -q xfce4-session xfce4-panel xfwm4 xfdesktop xfce4-terminal >/dev/null 2>&1 \
    || warn "no se pudo instalar el entorno XFCE todavía; se reintentará en la sección de RDP."
  ok "entorno XFCE preparado"
fi
command -v nmcli >/dev/null 2>&1 \
  || warn "nmcli no está presente; se requiere NetworkManager para fijar el DNS corporativo."

# ============================================================================
# 2. HOSTNAME — nunca el de la plantilla; debe coincidir con DNS/administrador
# ============================================================================
step "Verificando identidad del host (hostname / DNS)"
CUR_SHORT="$(hostname -s 2>/dev/null || cat /etc/hostname)"
PRIMARY_IF="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}' || true)"
[[ -n "$PRIMARY_IF" ]] || PRIMARY_IF="$(ip -4 -br addr show scope global | awk '{print $1; exit}' || true)"
IP_ADDR="$(ip -4 -o addr show dev "$PRIMARY_IF" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1 || true)"
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
  DNS_NAME="$(dig +short -x "$IP_ADDR" 2>/dev/null | head -1 | sed 's/\.$//' || true)"
else
  DNS_NAME="$(getent hosts "$IP_ADDR" 2>/dev/null | awk '{print $2}' | head -1 || true)"
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

# /etc/hosts: el FQDN debe resolver a la IP real, no a la plantilla.
backup /etc/hosts
{
  echo "127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4"
  echo "::1         localhost localhost.localdomain localhost6 localhost6.localdomain6"
  echo "${IP_ADDR}   ${FQDN} ${NEW_SHORT}"
} > /etc/hosts
[[ "$(hostname -f 2>/dev/null)" == "$FQDN" ]] \
  && ok "hostname -f → $FQDN" \
  || warn "hostname -f no devuelve $FQDN todavía (se corrige al reiniciar)."

# ---------------------------------------------------------------------------
# [RHEL] EPEL + CRB/PowerTools y la instalación de paquetes ya se hicieron por
# adelantado en la sección 1.5. Aquí no se repiten.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# [RHEL] DNS corporativo: RHEL no usa systemd-resolved. NetworkManager escribe
# /etc/resolv.conf a partir del perfil de la conexión activa, así que fijar el
# fichero a mano no sirve: en el próximo evento de red (DHCP renew, reboot)
# NetworkManager lo pisa. Hay que configurarlo en el propio perfil con nmcli.
# ---------------------------------------------------------------------------
step "Configurando DNS corporativo vía NetworkManager (${CORP_DNS[*]})"
command -v nmcli >/dev/null 2>&1 || die "nmcli no está disponible; este script requiere NetworkManager."
CONN_NAME="$(nmcli -t -f DEVICE,NAME,STATE connection show --active \
             | awk -F: -v d="$PRIMARY_IF" '$1==d && $3=="activated"{print $2; exit}')"
[[ -n "$CONN_NAME" ]] || die "No se encontró una conexión NetworkManager activa para $PRIMARY_IF."
DNS_CSV="$(IFS=,; echo "${CORP_DNS[*]}")"
OTHER_SEARCH="$(nmcli -g ipv4.dns-search connection show "$CONN_NAME" 2>/dev/null \
                | tr ',' '\n' | grep -vxF "$DOMAIN" | grep -v '^--$' | grep -v '^$' | tr '\n' ',' | sed 's/,$//' || true)"
SEARCH_CSV="${DOMAIN}${OTHER_SEARCH:+,${OTHER_SEARCH}}"
nmcli connection modify "$CONN_NAME" \
  ipv4.dns "$DNS_CSV" \
  ipv4.ignore-auto-dns yes \
  ipv4.dns-search "$SEARCH_CSV" 2>&1 | sed 's/^/  /'
nmcli connection up "$CONN_NAME" >/dev/null 2>&1 \
  && ok "conexión '${CONN_NAME}' reaplicada: DNS ${CORP_DNS[*]}, search ${SEARCH_CSV}" \
  || warn "no se pudo reaplicar la conexión '$CONN_NAME'; revisa 'nmcli con show ${CONN_NAME}'"
grep -qF "${CORP_DNS[0]}" /etc/resolv.conf 2>/dev/null \
  && ok "/etc/resolv.conf refleja el DNS corporativo" \
  || warn "/etc/resolv.conf todavía no muestra ${CORP_DNS[0]}; puede tardar unos segundos"

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
# chrony viene instalado y activo por defecto en RHEL/Rocky/Alma; se asegura
# igualmente por si la imagen lo omitió.
dnf install -y -q chrony >/dev/null
mkdir -p /etc/chrony.d
{
  echo "# Generado por ad-join-linux-redhat.sh — NTP corporativo obligatorio."
  # 'trust': Kerberos compara contra el reloj del dominio, no contra UTC. El host
  # debe seguir al NTP corporativo aunque se desvíe de la hora real, o la
  # autenticación falla con KRB5KRB_AP_ERR_SKEW.
  for dc in "${CORP_NTP[@]}"; do echo "server ${dc} iburst trust prefer"; done
  echo "makestep 1.0 -1"        # corrige saltos grandes siempre, no solo al arrancar
} > /etc/chrony.d/ad-domain.conf
# [RHEL] El chrony.conf por defecto de RHEL/Rocky/Alma 8 y 9 NO lee /etc/chrony.d
# (a diferencia de Debian/Ubuntu, que traen 'confdir /etc/chrony/conf.d'). Sin
# esta línea ad-domain.conf se ignora y, como abajo se comentan los pool/server
# públicos, chrony queda SIN NINGUNA fuente: el reloj deriva libremente hasta que
# Kerberos falla por desfase (KRB5KRB_AP_ERR_SKEW) semanas después del join.
if ! grep -qE '^\s*(confdir|include)\s+/etc/chrony\.d' /etc/chrony.conf 2>/dev/null; then
  backup /etc/chrony.conf
  echo "confdir /etc/chrony.d   # añadido por ad-join-linux-redhat.sh (carga ad-domain.conf)" >> /etc/chrony.conf
  ok "chrony.conf ahora carga /etc/chrony.d (confdir)"
fi
# Los pool/server públicos de la config por defecto compiten con los DCs: chrony
# marcaría a los DCs como 'falseticker' y no seguiría la hora del dominio.
if grep -qE '^\s*(pool|server)\s' /etc/chrony.conf 2>/dev/null; then
  backup /etc/chrony.conf
  sed -i -E 's/^(\s*(pool|server)\s.*)$/# desactivado por ad-join-linux-redhat.sh: \1/' /etc/chrony.conf
  ok "fuentes NTP públicas desactivadas (la hora la marca el dominio)"
fi
systemctl enable chronyd >/dev/null 2>&1
systemctl restart chronyd
sleep 3
chronyc -a makestep >/dev/null 2>&1 || true   # salto inmediato
sleep 2
SKEW="$(chronyc tracking 2>/dev/null | awk -F'[ ]+' '/System time/{print $4}' || true)"
[[ -n "$SKEW" ]] && ok "desfase respecto a las fuentes configuradas: ${SKEW}s"
# El desfase de arriba NO prueba nada si chrony no tiene fuentes: sin fuentes
# 'System time' vale ~0 y parece correcto. Se exige que chrony liste al NTP
# corporativo y que lo seleccione (^* o ^+) en un plazo razonable.
# corp_ntp_state → "selected" | "listed" | "missing"
corp_ntp_state() {
  local src st=missing ntp
  src="$(chronyc -n sources 2>/dev/null || true)"
  for ntp in "${CORP_NTP[@]}"; do
    if awk -v ip="$ntp" '$2==ip && $1 ~ /^\^[*+]/{f=1} END{exit !f}' <<<"$src"; then
      echo selected; return 0
    fi
    awk -v ip="$ntp" '$2==ip{f=1} END{exit !f}' <<<"$src" && st=listed
  done
  echo "$st"
}
NTP_STATE=missing
for _ in $(seq 1 15); do
  NTP_STATE="$(corp_ntp_state)"
  [[ "$NTP_STATE" == selected ]] && break
  sleep 2
done
case "$NTP_STATE" in
  selected) ok "chrony sincroniza contra el NTP corporativo:"
            chronyc -n sources 2>/dev/null | sed -n '3,$p' | sed 's/^/       /' || true ;;
  listed)   warn "chrony conoce a ${CORP_NTP[*]} pero aún no los selecciona (¿123/udp filtrado?)."
            warn "Revisa: chronyc -n sources   chronyc -n sourcestats" ;;
  *)        die "chrony NO tiene como fuente a ${CORP_NTP[*]}: /etc/chrony.d/ad-domain.conf no se está cargando. Revisa 'confdir /etc/chrony.d' en /etc/chrony.conf." ;;
esac
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
" "$DC1" 2>/dev/null || true)"
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
ok "chronyd activo y habilitado al arranque"

# ============================================================================
# 4. PAQUETES
# ============================================================================
step "Instalando paquetes de integración con AD"
dnf install -y -q \
  realmd sssd sssd-tools sssd-common \
  adcli samba-common-tools samba-common krb5-workstation \
  oddjob oddjob-mkhomedir authselect \
  bind-utils openldap-clients \
  policycoreutils-python-utils \
  openssh-server >/dev/null
ok "realmd, sssd, adcli, krb5, oddjob-mkhomedir instalados"

# ============================================================================
# 5. UNIÓN AL DOMINIO
# ============================================================================
step "Comprobando visibilidad del dominio $DOMAIN"
realm discover "$DOMAIN" >/dev/null 2>&1 \
  || die "No se ve el dominio '$DOMAIN'. Revisa DNS y conectividad con los DCs."
realm discover "$DOMAIN" 2>/dev/null | sed 's/^/  /' | head -8 || true

# ---------------------------------------------------------------------------
# Pre-chequeo de credenciales con Kerberos ANTES de intentar el join. 'realm
# join' con una contraseña VENCIDA falla con un genérico "Cannot read password"
# que despista; aquí se detecta y se avisa con claridad. Se usa un ccache de
# ARCHIVO (KRB5CCNAME=FILE:...) porque el ccache por defecto suele ser KCM
# (sssd-kcm), que todavía no está activo y haría fallar a kinit sin tener que ver
# con la contraseña.
# ---------------------------------------------------------------------------
step "Comprobando las credenciales de '$AD_USER' (contraseña vigente / vencida)"
KC_CHK="$(mktemp /tmp/adjoin-kinit.XXXXXX 2>/dev/null || echo /tmp/adjoin-kinit.cc)"
# Se captura el código de retorno real de kinit (rc=0 => contraseña vigente),
# sin que 'set -e' aborte: el patrón '… && KRC=0 || KRC=$?' lo neutraliza.
KINIT_OUT="$(printf '%s\n' "$AD_PASS" | KRB5CCNAME="FILE:$KC_CHK" kinit "${AD_USER}@${REALM}" 2>&1)" && KRC=0 || KRC=$?
kdestroy -c "FILE:$KC_CHK" >/dev/null 2>&1 || true
rm -f "$KC_CHK"
if (( KRC == 0 )); then
  ok "contraseña VIGENTE y credenciales válidas para ${AD_USER}@${REALM}"
elif echo "$KINIT_OUT" | grep -qiE 'password .*expired|key expired|expired while|Password expired'; then
  warn "La contraseña de '${AD_USER}' está VENCIDA en Active Directory."
  echo "     Kerberos informa:"
  echo "$KINIT_OUT" | sed 's/^/       /' | head -3
  echo "     El join NO puede continuar hasta renovarla. Opciones:"
  echo "       · Renovala vos:  kinit ${AD_USER}@${REALM}   (te deja fijar una nueva)"
  echo "       · Que un admin de AD la resetee y destilde 'cambiar en el próximo inicio'."
  echo "       · Usá otra cuenta con permiso de join y contraseña vigente."
  die "Contraseña vencida: renovala y volvé a ejecutar el script."
elif echo "$KINIT_OUT" | grep -qiE 'Preauthentication failed|Password incorrect|Generic preauth|Invalid argument while'; then
  warn "Contraseña INCORRECTA para '${AD_USER}'."
  echo "$KINIT_OUT" | sed 's/^/       /' | head -2
  die "Credenciales inválidas: revisá usuario/contraseña y volvé a ejecutar."
elif echo "$KINIT_OUT" | grep -qiE 'not found in Kerberos database|Client .* unknown|KDC_ERR_C_PRINCIPAL_UNKNOWN'; then
  warn "El usuario '${AD_USER}' no existe en el realm ${REALM}."
  echo "$KINIT_OUT" | sed 's/^/       /' | head -2
  die "Usuario inexistente: revisá el nombre (sin '@' ni dominio) y volvé a ejecutar."
elif echo "$KINIT_OUT" | grep -qiE 'Clock skew|Kerberos.*skew'; then
  warn "Desfase de reloj excesivo contra el KDC (Kerberos rechaza > 300s)."
  echo "$KINIT_OUT" | sed 's/^/       /' | head -2
  die "Corregí la hora (revisá chrony/el DC) y volvé a ejecutar."
else
  warn "No se pudo validar la credencial por un motivo inesperado; se intentará el join igualmente."
  echo "$KINIT_OUT" | sed 's/^/       /' | head -3
fi

if realm list 2>/dev/null | grep -qiE "^${DOMAIN}\$|domain-name: ${DOMAIN}"; then
  warn "Este equipo ya está unido a $DOMAIN."
  read -rp "  ¿Salir del dominio y volver a unir? [s/N]: " R
  if [[ "${R,,}" == s* ]]; then
    printf '%s' "$AD_PASS" | realm leave "$DOMAIN" -U "$AD_USER" --unattended 2>&1 | sed 's/^/  /' || true
  else
    SKIP_JOIN=1
  fi
fi

OS_NAME_STR="$(. /etc/os-release && echo "$NAME")"
OS_VER_STR="$(. /etc/os-release && echo "$VERSION_ID")"
if [[ -z "${SKIP_JOIN:-}" ]]; then
  step "Uniendo $FQDN al dominio $DOMAIN"
  # --host-fqdn lleva el FQDN COMPLETO sin truncar (es lo que registra dNSHostName
  # y lo que valida Kerberos). --computer-name lleva el sAMAccountName, recortado
  # sólo si el esquema de AD lo exige. --add-service-principal garantiza el SPN
  # con el nombre largo, que es el que usan SSH y RDP.
  JOIN_ARGS=( "$DOMAIN" -U "$AD_USER" --unattended
              --computer-name="$SAM_NAME"
              --os-name="$OS_NAME_STR"
              --os-version="$OS_VER_STR" )
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
    klist -k /etc/krb5.keytab 2>/dev/null | awk 'NR>3{print "      "$2}' | sort -u | head -8 || true
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
DOM_SECTION="$(grep -oP '^\[domain/\K[^]]+' "$SSSD_CONF" 2>/dev/null | head -1 || true)"
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

# [RHEL] Responders de SSSD en MODO CLÁSICO (arrancados por el monitor vía la
# línea 'services'), NO por socket-activation. Motivo: en RHEL 9 el monitor
# (sssd.service) corre como root, pero las unidades sssd-*.socket activan al
# responder con User=sssd (uid distinto). El responder de PAM entonces exige que
# el socket privado del backend sea de ese uid y, al ser de root, aborta con
# 'sbus-dp ... must be owned by uid [NNN]' → "Failed to connect to backend
# server". Resultado: NSS resuelve pero PAM no, y NINGÚN usuario puede entrar
# aunque el join esté perfecto. Fijando 'services = nss, pam' y desactivando la
# socket-activation, el monitor arranca nss y pam como el mismo usuario que el
# backend y todo queda consistente.
if grep -qE '^\s*services\s*=' "$SSSD_CONF"; then
  sed -i -E 's|^\s*services\s*=.*|services = nss, pam|' "$SSSD_CONF"
else
  sed -i '/^\[sssd\]/a services = nss, pam' "$SSSD_CONF"
fi
ok "responders fijados: 'services = nss, pam' (modo clásico, sin socket-activation)"

# Desactiva las unidades socket de responder de sssd (incluidas las '-priv'): si
# quedan habilitadas chocan con 'services=' y aparecen como 'failed'.
# IMPORTANTE: se EXCLUYE 'sssd-kcm.socket'. KCM no es un responder: es el servidor
# de caché de credenciales Kerberos. El krb5.conf de RHEL usa
# 'default_ccache_name = KCM:', de modo que si KCM no corre la AUTENTICACIÓN por
# SSH falla con 'krb5_child: No KCM server found' AUNQUE NSS y PAM resuelvan. Por
# eso KCM se deja aparte y se habilita explícitamente más abajo.
SSSD_SOCKS="$(systemctl list-unit-files --no-legend 'sssd-*.socket' 2>/dev/null | awk '{print $1}' | grep -v '^sssd-kcm' || true)"
if [[ -n "$SSSD_SOCKS" ]]; then
  # shellcheck disable=SC2086
  systemctl stop    $SSSD_SOCKS >/dev/null 2>&1 || true
  # shellcheck disable=SC2086
  systemctl disable $SSSD_SOCKS >/dev/null 2>&1 || true
fi
find /etc/systemd/system/sssd.service.wants -maxdepth 1 -name 'sssd-*.socket' ! -name 'sssd-kcm.socket' -delete 2>/dev/null || true

systemctl enable sssd >/dev/null 2>&1
systemctl daemon-reload
# Pipes viejos fuera: se recrean con el propietario correcto al arrancar limpio.
systemctl stop sssd >/dev/null 2>&1 || true
rm -f /var/lib/sss/pipes/nss /var/lib/sss/pipes/pam /var/lib/sss/pipes/pac 2>/dev/null || true
rm -f /var/lib/sss/pipes/private/sbus-* /var/lib/sss/pipes/private/pam /var/lib/sss/pipes/private/nss 2>/dev/null || true
systemctl reset-failed 'sssd*' >/dev/null 2>&1 || true
systemctl start sssd
sleep 4
systemctl is-active --quiet sssd && ok "sssd activo y habilitado al arranque" || die "sssd no arrancó. Revisa: journalctl -u sssd"

# KCM: servidor de caché de tickets Kerberos. Imprescindible para que el login
# almacene el TGT del usuario; sin él, SSH falla con 'No KCM server found'.
systemctl enable --now sssd-kcm.socket >/dev/null 2>&1 \
  && ok "sssd-kcm (caché de credenciales Kerberos) activo y habilitado" \
  || warn "no se pudo habilitar sssd-kcm.socket; el login podría fallar con 'krb5_child: No KCM server found'."

# Verificación dura: responder de PAM realmente atendiendo. Si el pipe de PAM no
# existe, el login fallaría pese a que NSS resuelva.
[[ -S /var/lib/sss/pipes/pam ]] && ok "responder PAM activo (pipe /var/lib/sss/pipes/pam presente)" \
  || warn "el pipe de PAM no aparece; revisa 'journalctl -u sssd' y /var/log/sssd/sssd_pam.log"

# ============================================================================
# 7. PAM — authselect (SSSD + creación automática del home)
# ============================================================================
# [RHEL] RHEL/Rocky/Alma no usan pam-auth-update: la herramienta equivalente es
# 'authselect', que gestiona /etc/pam.d de forma atómica y evita ediciones a
# mano inconsistentes. El perfil 'sssd' activa pam_sss; la característica
# 'with-mkhomedir' añade pam_oddjob_mkhomedir para crear el home al primer login.
step "Configurando autenticación con authselect (SSSD + home automático)"
if authselect select sssd with-mkhomedir --force >/dev/null 2>&1; then
  ok "authselect: perfil 'sssd' con mkhomedir aplicado"
else
  die "No se pudo aplicar el perfil de authselect. Revisa: authselect current"
fi
authselect check >/dev/null 2>&1 && ok "authselect: configuración consistente" \
  || warn "authselect reporta inconsistencias — revisa 'authselect check'"
grep -q "pam_sss.so" /etc/pam.d/system-auth 2>/dev/null && ok "pam_sss activo en system-auth" \
  || warn "pam_sss no aparece en system-auth — revisa 'authselect current -v'"
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
# Generado por ad-join-linux-redhat.sh
UsePAM yes
PasswordAuthentication yes
# Necesario para los diálogos de PAM: contraseña caducada, cambio obligatorio, MFA.
KbdInteractiveAuthentication yes
# SSO con ticket Kerberos desde equipos del dominio.
GSSAPIAuthentication yes
GSSAPICleanupCredentials yes
EOF
# sshd_config.d sólo se aplica si el fichero principal lo incluye (ya viene
# incluido por defecto desde RHEL 8, se verifica por si se editó a mano).
grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config \
  || sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
sshd -t || die "La configuración de sshd es inválida. NO se recargó (tu sesión sigue viva). Revisa $LOG"
# [RHEL] El servicio se llama 'sshd', no 'ssh'.
systemctl enable sshd >/dev/null 2>&1
systemctl reload sshd
ok "sshd configurado, validado y habilitado al arranque"

# [RHEL] firewalld viene activo por defecto: sin esto, SSH podría quedar
# bloqueado en un firewalld recién reseteado o con zona no estándar.
if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-service=ssh >/dev/null 2>&1
  firewall-cmd --reload >/dev/null 2>&1
  ok "firewalld: servicio ssh permitido"
fi

# ============================================================================
# 10. RDP
# ============================================================================
if ((INSTALL_RDP)); then
  step "Instalando escritorio XFCE y xrdp"
  # xrdp/xorgxrdp vienen de EPEL; el grupo 'Xfce' también.
  dnf groupinstall -y -q "Xfce" >/dev/null 2>&1 \
    || dnf install -y -q xfce4-session xfce4-panel xfwm4 xfdesktop xfce4-terminal >/dev/null
  dnf install -y -q xrdp xorgxrdp dbus-x11 xorg-x11-server-Xorg polkit >/dev/null
  ok "XFCE + xrdp instalados"

  # Sesión por defecto para CUALQUIER usuario (los del dominio no tienen ~/.xsession).
  cat > /etc/xrdp/startwm.sh <<'EOF'
#!/bin/sh
# Generado por ad-join-linux-redhat.sh
if [ -r /etc/profile.d/lang.sh ]; then
  . /etc/profile.d/lang.sh
fi
# Evita que XFCE arranque sin bus de sesión sobre RDP.
exec dbus-launch --exit-with-session startxfce4
EOF
  chmod 755 /etc/xrdp/startwm.sh

  # PAM: xrdp-sesman debe pasar por system-auth (gestionado por authselect) para
  # autenticar contra AD.
  if [[ -f /etc/pam.d/xrdp-sesman ]]; then
    grep -qE '^(auth|account)\s+include\s+system-auth' /etc/pam.d/xrdp-sesman \
      && ok "xrdp-sesman usa system-auth (autenticación AD vía pam_sss)" \
      || warn "revisa /etc/pam.d/xrdp-sesman: debería incluir system-auth"
  fi

  # ---------------------------------------------------------------------
  # [RHEL] Sin esto, XFCE sobre RDP muestra diálogos de autenticación en
  # bucle para colord. El polkit de RHEL 8/9 (y derivados) sigue soportando
  # el formato clásico .pkla; en versiones más nuevas de polkit (>=0.106,
  # no presentes aún en RHEL 8/9 al momento de escribir esto) el formato
  # correcto son reglas JS en /etc/polkit-1/rules.d/. Se detecta la versión
  # instalada para generar el formato adecuado.
  # ---------------------------------------------------------------------
  step "Permitiendo colord sin diálogos repetidos (compatibilidad polkit)"
  PKVER="$(rpm -q --qf '%{VERSION}' polkit 2>/dev/null || echo 0)"
  if command -v rpmdev-vercmp >/dev/null 2>&1 && rpmdev-vercmp "$PKVER" 0.106 2>/dev/null | grep -q '>='; then
    NEW_POLKIT=1
  elif printf '%s\n0.106\n' "$PKVER" | sort -V | head -1 | grep -qv "^${PKVER}\$"; then
    NEW_POLKIT=1
  else
    NEW_POLKIT=0
  fi
  if (( NEW_POLKIT )); then
    mkdir -p /etc/polkit-1/rules.d
    cat > /etc/polkit-1/rules.d/45-allow-colord.rules <<'EOF'
// Generado por ad-join-linux-redhat.sh
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

  # [RHEL] firewalld no tiene un servicio 'rdp' definido por defecto en todas
  # las versiones: se abre el puerto directamente para no depender de eso.
  if systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port=3389/tcp >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
    ok "firewalld: puerto 3389/tcp (RDP) permitido"
  fi
fi

# ============================================================================
# 11. SELINUX — aviso, no se desactiva
# ============================================================================
step "Comprobando SELinux"
if command -v getenforce >/dev/null 2>&1; then
  SEL_MODE="$(getenforce)"
  if [[ "$SEL_MODE" == "Enforcing" ]]; then
    ok "SELinux en modo Enforcing (recomendado; no se modifica)"
    echo "     Si algo falla de forma extraña (login, xrdp), revisa denegaciones con:"
    echo "       ausearch -m avc -ts recent   ó   journalctl -t setroubleshoot"
  else
    warn "SELinux está en modo '$SEL_MODE', no 'Enforcing'. Este script no lo cambia,"
    warn "pero es buena práctica dejarlo en Enforcing salvo motivo justificado."
  fi
else
  warn "No se pudo determinar el estado de SELinux (¿getenforce no disponible?)."
fi

# ============================================================================
# 12. VERIFICACIÓN
# ============================================================================
step "Verificación"
for svc in sssd chronyd sshd oddjobd $( ((INSTALL_RDP)) && echo "xrdp xrdp-sesman" || true ); do
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

# Contador de problemas que IMPIDEN el login. Determina el veredicto final: sólo
# se declara el éxito de extremo a extremo si vale 0.
HC_ERR=0

# --- 12.a Unidades de SSSD en estado 'failed' --------------------------------
# Un 'sssd-*.socket' en 'failed' es la huella de la socket-activation chocando
# con 'services='; no siempre rompe el login, pero ensucia el arranque y suele
# acompañar al fallo del responder de PAM. Se avisa siempre.
step "Estado de las unidades de SSSD"
if systemctl is-active --quiet sssd; then
  ok "sssd activo"
else
  warn "sssd NO está activo: sin él no hay resolución ni login."
  ((HC_ERR++)) || true
fi
FAILED_SSSD="$(systemctl --failed --all --no-legend 'sssd*' 2>/dev/null | awk '{print $2}' | tr '\n' ' ')"
if [[ -n "${FAILED_SSSD// /}" ]]; then
  warn "Unidades de SSSD en 'failed': ${FAILED_SSSD}"
  echo "     Límpialas (modo clásico, sin socket-activation):"
  echo "       systemctl disable --now ${FAILED_SSSD}"
  echo "       systemctl reset-failed ${FAILED_SSSD}"
else
  ok "ninguna unidad de SSSD en estado 'failed'"
fi

# --- 12.b Responders realmente atendiendo (pipes NSS y PAM) ------------------
# El síntoma que más despista: el join está perfecto pero el pipe del responder
# no existe, así que NSS o PAM no contestan y NADIE entra. Se comprueba el pipe.
step "Responders de SSSD atendiendo (NSS y PAM)"
if [[ -S /var/lib/sss/pipes/nss ]]; then
  ok "responder NSS: /var/lib/sss/pipes/nss presente"
else
  warn "responder NSS CAÍDO (no existe /var/lib/sss/pipes/nss): 'id' y 'getent' fallarán."
  echo "     Revisa 'services = nss, pam' en $SSSD_CONF y que el .socket NSS no quede habilitado."
  ((HC_ERR++)) || true
fi
if [[ -S /var/lib/sss/pipes/pam ]]; then
  ok "responder PAM: /var/lib/sss/pipes/pam presente"
else
  warn "responder PAM CAÍDO (no existe /var/lib/sss/pipes/pam): NINGÚN login funcionará."
  echo "     Causa típica: socket-activation arrancando el responder con un usuario"
  echo "     distinto al del backend. Busca 'must be owned by uid' en /var/log/sssd/sssd_pam.log."
  ((HC_ERR++)) || true
fi
# KCM: sin el servidor de caché de tickets Kerberos, la AUTENTICACIÓN por SSH
# falla con 'krb5_child: No KCM server found' aunque NSS y PAM resuelvan bien.
if systemctl is-active --quiet sssd-kcm.socket || [[ -S /var/run/.heim_org.h5l.kcm-socket ]]; then
  ok "KCM (caché de tickets Kerberos) activo"
else
  warn "KCM CAÍDO (sssd-kcm.socket inactivo): el login fallará con 'No KCM server found'."
  echo "     Habilítalo con: systemctl enable --now sssd-kcm.socket"
  ((HC_ERR++)) || true
fi

# --- 12.c Backend Online contra los DC ---------------------------------------
if command -v sssctl >/dev/null 2>&1; then
  DSTAT="$(sssctl domain-status "$DOM_SECTION" 2>/dev/null | awk -F': *' '/Online status/{print $2; exit}' || true)"
  case "${DSTAT,,}" in
    *online*)  ok "backend SSSD Online contra '${DOM_SECTION}'" ;;
    *offline*) warn "backend SSSD OFFLINE: no alcanza a los DC (DNS, puertos 389/88/445/3268 o reloj)."; ((HC_ERR++)) || true ;;
    *)         warn "no se pudo determinar el estado Online del backend (sssctl domain-status)." ;;
  esac
fi

# --- 12.c2 Reloj sincronizado con el NTP corporativo -------------------------
# Hoy el reloj puede estar bien y Kerberos funcionar, pero si chrony no tiene al
# NTP corporativo como fuente el desfase crece hasta romper el login más
# adelante. Se avisa sin contarlo como fallo duro: no impide entrar HOY.
step "Reloj sincronizado con el NTP corporativo"
case "$(corp_ntp_state)" in
  selected) ok "chrony sigue a ${CORP_NTP[*]} ($(timedatectl show -p NTPSynchronized --value 2>/dev/null | sed 's/yes/sincronizado/;s/no/convergiendo/'))" ;;
  listed)   warn "chrony tiene a ${CORP_NTP[*]} pero no los selecciona: revisa 'chronyc -n sources' y 123/udp." ;;
  *)        warn "chrony NO usa el NTP corporativo: falta 'confdir /etc/chrony.d' en /etc/chrony.conf."
            warn "Kerberos dejará de funcionar cuando el reloj se desvíe más de 300 s." ;;
esac

# --- 12.d Resolución NSS real + contraste con InfoPipe -----------------------
# Se prueba por NSS ('getent', el camino que usan sshd/login), no sólo 'id'. Si
# NSS falla pero el backend SÍ ve al usuario por InfoPipe, el problema es el
# responder/NSS, no el join ni AD: se dice con todas las letras.
step "Probando resolución de un usuario del dominio"
if [[ "$USE_FQN" == "True" ]]; then TEST_ID="${AD_USER}@${DOMAIN}"; else TEST_ID="$AD_USER"; fi
if getent passwd "$TEST_ID" >/dev/null 2>&1; then
  ok "getent passwd $TEST_ID → resuelto por NSS"
  getent passwd "$TEST_ID" 2>/dev/null | sed 's/^/       /' | head -1 || true
else
  warn "NSS NO resuelve '$TEST_ID' ('getent passwd' vacío)."
  ((HC_ERR++)) || true
  if command -v sssctl >/dev/null 2>&1 && sssctl user-checks "$TEST_ID" 2>/dev/null | grep -qiE '^ *- *name:'; then
    warn "PERO el backend SÍ lo encuentra por InfoPipe → el fallo es del responder NSS,"
    warn "no del join ni de AD. El pipe /var/lib/sss/pipes/nss no está atendiendo."
    echo "     Solución: 'services = nss, pam' en $SSSD_CONF y desactivar la socket-activation de sssd."
  else
    warn "El backend tampoco lo encuentra. Revisa el grupo permitido, el DNS y:"
    warn "  sssctl domain-status ${DOM_SECTION}   journalctl -u sssd -n 50"
  fi
fi

# Ticket Kerberos: confirma que el keytab y el realm son correctos. Se usa un
# ccache de ARCHIVO para no depender de KCM (sssd-kcm), que puede no estar activo
# y daría un falso negativo sin relación con la contraseña.
KC_VER="$(mktemp /tmp/adjoin-kinit.XXXXXX 2>/dev/null || echo /tmp/adjoin-kinit-ver.cc)"
if printf '%s\n' "$AD_PASS" | KRB5CCNAME="FILE:$KC_VER" kinit "${AD_USER}@${REALM}" >/dev/null 2>&1; then
  ok "kinit correcto: Kerberos operativo"
  kdestroy -c "FILE:$KC_VER" >/dev/null 2>&1 || true
else
  warn "kinit falló — revisa el realm ($REALM) y el desfase de reloj."
fi
rm -f "$KC_VER"
unset AD_PASS

# Resolver al usuario NO garantiza que pueda entrar: la fase 'account' de PAM
# es una comprobación distinta y es donde fallan las GPO ilegibles y las reglas
# de acceso. Se prueba de verdad, porque sshd disfraza ese fallo como
# "User account has expired", que envía a diagnosticar en la dirección errónea.
step "Probando la autorización real de login (fase 'account' de PAM)"
if ! command -v pamtester >/dev/null 2>&1; then
  dnf install -y -q pamtester >/dev/null 2>&1 || true
fi
if command -v pamtester >/dev/null 2>&1; then
  PAM_OUT="$(pamtester sshd "$TEST_ID" acct_mgmt 2>&1 || true)"
  if echo "$PAM_OUT" | grep -qiE 'account management done'; then
    ok "PAM autoriza el login de '$TEST_ID' — SSH$( ((INSTALL_RDP)) && echo ' y RDP' || true ) operativos"
  else
    warn "PAM RECHAZA el login de '$TEST_ID'."
    ((HC_ERR++)) || true
    echo "     Detalle:"
    echo "$PAM_OUT" | sed 's/^/       /' | head -4
    # Mensaje específico: el responder de PAM no conecta al backend (el fallo de
    # propietario de socket que detectamos). 'id' puede funcionar y aun así PAM no.
    if echo "$PAM_OUT" | grep -qiE 'cannot retrieve authentication info|authentication service'; then
      warn "Pinta a responder de PAM caído / sin conexión al backend (no a permisos)."
      echo "       · Revisa /var/log/sssd/sssd_pam.log (busca 'must be owned by uid')."
      echo "       · Asegura 'services = nss, pam' y sin socket-activation de sssd."
    else
      echo "     Causas más frecuentes:"
      echo "       · GPO ilegible → ya mitigado con ad_gpo_ignore_unreadable = True"
      echo "       · el usuario no está en el grupo permitido → realm permit -g 'GRUPO@${DOMAIN}'"
      echo "       · denegación de SELinux → ausearch -m avc -ts recent"
      echo "       · revisa:  journalctl -u sssd | grep -i denied"
    fi
  fi
else
  warn "pamtester no disponible: no se pudo verificar la autorización."
  warn "Compruébalo manualmente con un SSH real antes de dar por buena la instalación."
fi

# --- Veredicto final: sólo 'OK de extremo a extremo' si NO hubo fallos duros ---
if (( HC_ERR == 0 )); then
  echo -e "\n${c_grn}${c_bld}Integración con AD verificada de extremo a extremo (servicios + NSS + PAM + backend Online).${c_rst}"
else
  echo -e "\n${c_red}${c_bld}La unión al dominio se completó, pero el chequeo de salud encontró ${HC_ERR} problema(s) que impiden el login.${c_rst}"
  echo -e "${c_red}Revisa los avisos [!] de arriba y el log $LOG antes de dar por buena la instalación.${c_rst}"
fi

cat <<EOF
${c_bld}Cómo entran los usuarios${c_rst}
  SSH : ssh ${TEST_ID}@${IP_ADDR}
$( ((INSTALL_RDP)) && echo "  RDP : ${IP_ADDR}:3389  (usuario: ${TEST_ID})" || true )

${c_bld}Notas${c_rst}
  · Log completo: $LOG
  · Copias de seguridad: ficheros *.pre-adjoin
  · SSSD está en 'ad_gpo_access_control = permissive'. Cuando AD tenga la GPO
    de inicio de sesión configurada para Linux, cámbialo a 'enforcing' en
    /etc/sssd/sssd.conf.
$( [[ -z "$AD_GROUP" ]] && echo "  · Ahora puede entrar CUALQUIER usuario del dominio. Para restringir:
    realm deny --all && realm permit -g 'GRUPO@${DOMAIN}'" || true )
  · Si la IP no tenía PTR, pide al administrador de DNS los registros A y PTR
    de ${FQDN} → ${IP_ADDR}.
  · El DNS corporativo quedó fijado en el perfil de NetworkManager de la
    conexión '${CONN_NAME}'. Revisa con: nmcli con show '${CONN_NAME}' | grep ipv4.dns
  · SELinux no fue modificado por este script. Si algo falla, revisa
    'ausearch -m avc -ts recent' antes de deshabilitarlo.

${c_bld}Antes de reiniciar${c_rst}: prueba el acceso en una terminal NUEVA sin cerrar
esta sesión. Todos los servicios quedan habilitados y persisten al reinicio.
EOF
