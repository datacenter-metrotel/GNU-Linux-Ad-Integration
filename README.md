# ad-join-linux

Scripts de shell para unir servidores Linux a un dominio **Active Directory**
(vía `realmd` + `sssd` + `adcli`) y dejar habilitado el acceso de usuarios del
dominio por **SSH** y, opcionalmente, por **RDP** (escritorio XFCE + xrdp).

Cada script pregunta siempre el dominio, el usuario y la contraseña de forma
interactiva, valida que el equipo no se una con un hostname de plantilla,
fuerza el DNS y el NTP corporativos, y termina con una verificación real de
extremo a extremo (resolución del usuario, `kinit` y autorización PAM), no
solo con "el comando no devolvió error".

## Scripts disponibles

| Script                     | Distribuciones objetivo                                    |
|-----------------------------|-------------------------------------------------------------|
| `ad-join-linux-debian.sh`   | Debian 13                                                    |
| `ad-join-linux-ubuntu.sh`   | Ubuntu 22.04 / 24.04 LTS                                     |
| `ad-join-linux-redhat.sh`   | RHEL 8/9, CentOS Stream, Rocky Linux, AlmaLinux              |

Los tres hacen exactamente lo mismo a nivel funcional; lo que cambia entre
ellos es la capa específica de cada distro (gestor de paquetes, repos extra,
persistencia de red/DNS, PAM y nombres de servicio). Ver la sección
[Diferencias entre distros](#diferencias-entre-distros) más abajo.

## Qué hace el script

1. **Datos del dominio** — pide dominio AD, usuario y contraseña con
   privilegios de join, OU destino (opcional), grupo autorizado a entrar
   (opcional) y si ese grupo debe tener `sudo`.
2. **Hostname** — detecta si el hostname actual parece el de una plantilla
   clonada (`template`, `golden`, `localhost`, `debian`, `ubuntu`, `rhel`,
   nombres genéricos, etc.) y **se niega a unir el equipo con ese nombre**;
   pide uno definitivo. Si el PTR del DNS ya tiene un nombre válido, lo
   propone. Respeta el límite real de AD para `sAMAccountName` (19
   caracteres + `$`) sin truncar nunca el hostname/FQDN real.
3. **DNS y NTP corporativos** — fuerza los servidores DNS/NTP indicados en
   las constantes `CORP_DNS` / `CORP_NTP` del script (ver
   [Configuración](#configuración-antes-de-usar)), de forma persistente tras
   reiniciar, y verifica que resuelven registros SRV del dominio antes de
   seguir.
4. **Paquetes** — instala `realmd`, `sssd`, `adcli`, `krb5`, `oddjob-mkhomedir`
   y demás dependencias (habilitando repos extra si la distro los necesita).
5. **Unión al dominio** — `realm join` con el hostname completo, más
   `adcli update` para asegurar el SPN `host/<fqdn>` con el nombre completo
   (necesario para que Kerberos valide bien SSH/RDP aunque el
   `sAMAccountName` haya sido recortado).
6. **SSSD** — configura `ad_gpo_access_control = permissive` (evita bloquear
   a todos los usuarios si el dominio no tiene la GPO de login Linux
   configurada), `ad_gpo_ignore_unreadable = True` (evita el falso
   "User account has expired" por GPOs heredadas ilegibles), caché de
   credenciales offline, y corrige el problema conocido de colisión entre la
   línea `services=` de `sssd.conf` y la activación por socket de systemd.
7. **PAM** — habilita la creación automática del `$HOME` al primer login.
8. **Control de acceso** — `realm permit --all` o, si se indicó un grupo,
   `realm deny --all` + `realm permit -g GRUPO@dominio`, más una regla de
   `sudo` opcional en `/etc/sudoers.d/`.
9. **SSH** — habilita `PasswordAuthentication`, `KbdInteractiveAuthentication`
   y `GSSAPIAuthentication` en un fichero propio bajo `sshd_config.d/`
   (sobrevive a actualizaciones del paquete), valida la sintaxis con
   `sshd -t` antes de recargar.
10. **RDP** *(opcional, se puede omitir con `--no-rdp`)* — instala escritorio
    XFCE + xrdp, configura la sesión por defecto y una regla de polkit para
    que `colord` no muestre diálogos de autenticación en bucle.
11. **Verificación** — comprueba el estado de los servicios, resuelve un
    usuario de prueba (`id`), obtiene un ticket Kerberos (`kinit`) y —lo más
    importante— prueba la fase `account` de PAM con `pamtester`, que es la
    que de verdad decide si alguien puede iniciar sesión (resolver al usuario
    no es lo mismo que poder entrar).

Todo el proceso queda registrado en `/var/log/ad-join-linux.log`, y cada
fichero de configuración modificado se respalda una sola vez como
`<archivo>.pre-adjoin` antes de tocarlo.

## Requisitos

- Acceso root (`sudo`).
- Conectividad de red hacia los controladores de dominio y hacia los
  servidores DNS/NTP corporativos.
- Un usuario de AD con permiso para unir equipos al dominio (o a la OU
  indicada).
- El equipo **no** debe llamarse igual que la plantilla/imagen desde la que
  fue clonado — el script lo detecta y te va a pedir un nombre definitivo si
  es el caso.

## Uso

```bash
# Clonar o descargar el repo, y en el servidor a unir:
chmod +x ad-join-linux-*.sh

# Debian 13
sudo ./ad-join-linux-debian.sh

# Ubuntu 22.04 / 24.04
sudo ./ad-join-linux-ubuntu.sh

# RHEL / CentOS Stream / Rocky / AlmaLinux
sudo ./ad-join-linux-redhat.sh
```

Para omitir la instalación de escritorio XFCE + xrdp (solo SSH):

```bash
sudo ./ad-join-linux-<distro>.sh --no-rdp
```

Ayuda rápida:

```bash
./ad-join-linux-<distro>.sh --help
```

## Configuración antes de usar

Editar estas constantes al principio de cada script antes de usarlo en otro
entorno (vienen precargadas con los valores de este dominio/infra):

```bash
DOMAIN_DEFAULT="metrotel.local"          # dominio AD sugerido por defecto
CORP_DNS=(172.18.194.36 172.18.194.37)   # DNS corporativos obligatorios
CORP_NTP=(172.18.194.36 172.18.194.37)   # NTP corporativos obligatorios (Kerberos)
```

## Diferencias entre distros

| Aspecto                        | Debian / Ubuntu                                    | RHEL / Rocky / Alma                                   |
|---------------------------------|-----------------------------------------------------|---------------------------------------------------------|
| Gestor de paquetes               | `apt-get`                                           | `dnf`                                                    |
| Repos extra necesarios           | `universe` (solo Ubuntu)                            | EPEL + CodeReady Builder / `crb` / `powertools`          |
| Persistencia de DNS              | `/etc/resolv.conf` estático + Netplan (Ubuntu) o `/etc/network/interfaces` (Debian, si aplica) | Perfil de conexión de **NetworkManager** (`nmcli`) |
| Activación de SSSD + mkhomedir   | `pam-auth-update`                                   | `authselect select sssd with-mkhomedir`                  |
| Servicio SSH                     | `ssh`                                               | `sshd`                                                    |
| Firewall                         | no se toca (no viene activo por defecto)            | `firewalld` — se abren `ssh` y, si aplica, `3389/tcp`     |
| SELinux                          | N/A                                                  | se informa el estado, **no se modifica**                 |

## Notas y solución de problemas

- **`ad_gpo_access_control = permissive`**: queda así a propósito para no
  bloquear a nadie si el dominio todavía no tiene la GPO de inicio de sesión
  para Linux configurada. Una vez que esté, cambiarlo a `enforcing` en
  `/etc/sssd/sssd.conf` y reiniciar `sssd`.
- **Acceso abierto a todo el dominio**: si no se indica un grupo al ejecutar
  el script, cualquier usuario del dominio puede entrar. Para restringirlo
  después:
  ```bash
  realm deny --all
  realm permit -g 'GRUPO@dominio.local'
  ```
- **Diagnóstico de login rechazado** (el usuario resuelve con `id` pero no
  puede entrar):
  ```bash
  journalctl -u sssd | grep -i denied
  sssctl domain-status <dominio>
  # En RHEL, además:
  ausearch -m avc -ts recent
  ```
- **Probar antes de reiniciar**: siempre validar el acceso (SSH y, si aplica,
  RDP) en una terminal nueva sin cerrar la sesión actual. Todos los servicios
  quedan habilitados y persisten al reinicio, pero es más fácil corregir algo
  con una sesión de root todavía abierta.

## Seguridad

- La contraseña del usuario de dominio nunca se escribe a disco: se pasa por
  `stdin` a `realm join` / `kinit`, y se hace `unset` de la variable en cuanto
  deja de ser necesaria.
- Los ficheros modificados se respaldan como `<archivo>.pre-adjoin` antes de
  la primera edición.
- El log completo de cada ejecución queda en `/var/log/ad-join-linux.log`.

## Licencia

Uso interno. Ajustar `CORP_DNS`, `CORP_NTP` y `DOMAIN_DEFAULT` antes de
reutilizar estos scripts fuera de este entorno.
