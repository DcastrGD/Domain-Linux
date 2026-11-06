#!/usr/bin/env bash
#
# autoDM.sh - Automatización básica de un controlador de dominio Samba AD DC
# Pensado para Debian con systemd e ifupdown.
#
# IMPORTANTE:
# - Ejecutar como root: sudo bash autoDM.sh
# - La configuración de red estática puede cortar una sesión SSH.
# - No ejecutar sobre un controlador de dominio ya provisionado.
#

set -Eeuo pipefail

trap 'rc=$?; echo "[-] Error en la línea ${LINENO}. Código de salida: ${rc}." >&2; exit "$rc"' ERR

# ---------------------------------------------------------------------------
# Funciones auxiliares
# ---------------------------------------------------------------------------

function is_root {
    if [[ "${EUID}" -ne 0 ]]; then
        echo "[-] Este script necesita privilegios de administrador."
        echo "[!] Ejecuta: sudo bash $0"
        exit 1
    fi
}

function valid_ipv4 {
    local ip="$1"
    local a b c d extra

    IFS='.' read -r a b c d extra <<< "$ip"

    [[ -n "${a:-}" && -n "${b:-}" && -n "${c:-}" && -n "${d:-}" && -z "${extra:-}" ]] || return 1

    for octet in "$a" "$b" "$c" "$d"; do
        [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done
}

function valid_netmask {
    local mask="$1" octet partial_seen=0 found=0 allowed value
    local a b c d extra
    local valid_octets=(255 254 252 248 240 224 192 128 0)

    IFS='.' read -r a b c d extra <<< "$mask"
    [[ -n "${a:-}" && -n "${b:-}" && -n "${c:-}" && -n "${d:-}" && -z "${extra:-}" ]] || return 1

    for octet in "$a" "$b" "$c" "$d"; do
        [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
        (( 10#$octet <= 255 )) || return 1

        allowed=0
        for value in "${valid_octets[@]}"; do
            if (( 10#$octet == value )); then
                allowed=1
                break
            fi
        done
        (( allowed == 1 )) || return 1

        if (( partial_seen == 1 && 10#$octet != 0 )); then
            return 1
        fi
        (( 10#$octet != 255 )) && partial_seen=1
        (( 10#$octet != 0 )) && found=1
    done

    (( found == 1 ))
}

function ask_required {
    local prompt="$1"
    local variable_name="$2"
    local value=""

    while [[ -z "$value" ]]; do
        read -r -p "$prompt" value
        if [[ -z "$value" ]]; then
            echo "[!] Este campo no puede quedar vacío."
        fi
    done

    printf -v "$variable_name" '%s' "$value"
}

function backup_file {
    local file="$1"
    local backup="${file}.bak"

    if [[ -e "$file" || -L "$file" ]]; then
        if [[ -e "$backup" || -L "$backup" ]]; then
            backup="${file}.bak.$(date +%Y%m%d-%H%M%S)"
        fi
        cp -a -- "$file" "$backup"
        echo "[+] Copia de seguridad: $backup"
    fi
}

# ---------------------------------------------------------------------------
# Recogida y validación de datos
# ---------------------------------------------------------------------------

function initial_config {
    echo "=================================================="
    echo "       CONFIGURACIÓN INICIAL DE SAMBA AD DC"
    echo "=================================================="
    echo

    NETBIOS="$(hostname)"

    ask_required "Nombre del dominio (ej. acme): " NAME_DOMAIN
    ask_required "Extensión del dominio (ej. local): " EXTENSION_DOMAIN

    NAME_DOMAIN="${NAME_DOMAIN,,}"
    EXTENSION_DOMAIN="${EXTENSION_DOMAIN,,}"

    if [[ ! "$NAME_DOMAIN" =~ ^[a-z0-9]([a-z0-9-]{0,13}[a-z0-9])?$ ]]; then
        echo "[-] El nombre NetBIOS debe tener entre 1 y 15 caracteres y usar letras, números o guiones."
        exit 1
    fi

    if [[ ! "$EXTENSION_DOMAIN" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
        echo "[-] La extensión no tiene un formato válido."
        exit 1
    fi

    DOMAIN="${NAME_DOMAIN}.${EXTENSION_DOMAIN}"
    DOMAIN_LOWER="${DOMAIN,,}"
    DOMAIN_UPPER="${DOMAIN^^}"

    echo
    echo "Dominio DNS:       $DOMAIN_LOWER"
    echo "Realm Kerberos:    $DOMAIN_UPPER"
    echo "Dominio NetBIOS:   ${NAME_DOMAIN^^}"
    echo "Hostname actual:   $NETBIOS"
    echo

    read -r -p "¿Quieres cambiar el nombre del equipo? (s/n) [$NETBIOS]: " CONFIRM
    if [[ "${CONFIRM,,}" == "s" ]]; then
        ask_required "Nuevo hostname: " CHANGE_HOSTNAME
        CHANGE_HOSTNAME="${CHANGE_HOSTNAME,,}"

        if [[ ! "$CHANGE_HOSTNAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
            echo "[-] El hostname no tiene un formato válido."
            exit 1
        fi
    else
        CHANGE_HOSTNAME="$NETBIOS"
    fi

    read -r -p "Interfaz de red (ej. enp0s3): " INTERFAZ
    ask_required "Dirección IPv4 estática: " IP
    while ! valid_ipv4 "$IP"; do
        echo "[!] Dirección IPv4 no válida."
        ask_required "Dirección IPv4 estática: " IP
    done

    ask_required "Máscara de red (ej. 255.255.255.0): " MASK
    while ! valid_netmask "$MASK"; do
        echo "[!] Máscara no válida. Usa una máscara contigua, por ejemplo 255.255.255.0."
        ask_required "Máscara de red: " MASK
    done

    read -r -p "Puerta de enlace (ENTER si no procede): " GATEWAY
    if [[ -n "$GATEWAY" ]] && ! valid_ipv4 "$GATEWAY"; then
        echo "[-] La puerta de enlace no es una IPv4 válida."
        exit 1
    fi

    ask_required "DNS reenviador externo (IP del router u otro DNS): " DNS_FORWARDER
    while ! valid_ipv4 "$DNS_FORWARDER"; do
        echo "[!] DNS reenviador no válido."
        ask_required "DNS reenviador externo: " DNS_FORWARDER
    done

    echo
    echo "[!] La configuración de red estática puede cortar la conexión SSH."
    read -r -p "¿Continuar con estos datos? (s/n): " CONFIRM
    [[ "${CONFIRM,,}" == "s" ]] || {
        echo "[!] Operación cancelada."
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Instalación de paquetes
# ---------------------------------------------------------------------------

function pkg {
    echo
    echo "[+] Actualizando índices de paquetes..."
    apt-get update

    echo "[+] Instalando dependencias..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        samba \
        krb5-user \
        winbind \
        smbclient \
        dnsutils \
        iproute2

    echo "[+] Paquetes instalados."
}

# ---------------------------------------------------------------------------
# Configuración de red con ifupdown
# ---------------------------------------------------------------------------

function config_network {
    echo
    echo "[+] Configurando red..."

    if ! command -v ifup >/dev/null 2>&1 || ! command -v ifquery >/dev/null 2>&1; then
        echo "[-] No se encuentran ifup/ifquery. Instala ifupdown o configura la IP con tu gestor de red."
        return 1
    fi

    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        echo "[-] NetworkManager está activo; no modificaré /etc/network/interfaces."
        return 1
    fi

    if systemctl is-active --quiet systemd-networkd 2>/dev/null; then
        echo "[-] systemd-networkd está activo; no mezclaré gestores de red."
        return 1
    fi

    if ! ip link show "$INTERFAZ" >/dev/null 2>&1; then
        echo "[-] No existe la interfaz $INTERFAZ."
        return 1
    fi

    local tmp_interfaces
    tmp_interfaces="$(mktemp)"
    cat > "$tmp_interfaces" <<EOF
# Configuración generada por autoDM.sh
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

auto ${INTERFAZ}
iface ${INTERFAZ} inet static
    address ${IP}
    netmask ${MASK}
EOF

    if [[ -n "$GATEWAY" ]]; then
        printf '    gateway %s\n' "$GATEWAY" >> "$tmp_interfaces"
    fi

    if ! ifquery --interfaces="$tmp_interfaces" "$INTERFAZ" >/dev/null 2>&1; then
        echo "[-] ifupdown no acepta la configuración generada."
        rm -f "$tmp_interfaces"
        return 1
    fi

    backup_file /etc/network/interfaces
    install -m 0644 "$tmp_interfaces" /etc/network/interfaces
    rm -f "$tmp_interfaces"

    echo "[+] /etc/network/interfaces escrito y validado."
    echo
    echo "[!] Se aplicará la IPv4 estática en ${INTERFAZ}."
    echo "[!] Si estás conectado por SSH mediante esta interfaz, podrías perder la conexión."
    read -r -p "¿Aplicar ahora la configuración? (s/n): " CONFIRM

    if [[ "${CONFIRM,,}" != "s" ]]; then
        echo "[-] Configuración guardada, pero no aplicada."
        return 1
    fi

    local current_ip
    current_ip="$(ip -o -4 addr show dev "$INTERFAZ" 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4}')"

    if grep -Fxq "$IP" <<< "$current_ip"; then
        echo "[+] La IPv4 ${IP} ya está configurada en ${INTERFAZ}."
    else
        echo "[+] Aplicando configuración con ifupdown..."
        if ! ifup --force "$INTERFAZ"; then
            echo "[-] ifupdown no pudo activar ${INTERFAZ}."
            echo "[!] Consulta: journalctl -u networking -b --no-pager"
            return 1
        fi
    fi

    current_ip="$(ip -o -4 addr show dev "$INTERFAZ" 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4}')"
    if ! grep -Fxq "$IP" <<< "$current_ip"; then
        echo "[-] La IPv4 ${IP} no aparece en ${INTERFAZ} después de aplicar la configuración."
        echo "[!] IPv4 detectadas: ${current_ip:-ninguna}"
        return 1
    fi

    echo "[+] Red configurada correctamente: ${INTERFAZ} -> ${IP}/${MASK}."
}

# Hostname y /etc/hosts
# ---------------------------------------------------------------------------

function config_hostname {
    echo
    echo "[+] Configurando hostname..."

    if [[ "$(hostname)" != "$CHANGE_HOSTNAME" ]]; then
        hostnamectl set-hostname "$CHANGE_HOSTNAME"
    fi

    echo "[+] Hostname actual: $(hostname)"
}

function hosts {
    echo
    echo "[+] Configurando /etc/hosts..."

    backup_file /etc/hosts

    cat > /etc/hosts <<EOF
127.0.0.1       localhost
${IP}            ${CHANGE_HOSTNAME}.${DOMAIN_LOWER} ${CHANGE_HOSTNAME}

# The following lines are desirable for IPv6 capable hosts
::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF

    echo "[+] /etc/hosts actualizado."
}

# ---------------------------------------------------------------------------
# Provisionamiento Samba AD DC
# ---------------------------------------------------------------------------

function samba {
    echo
    echo "[+] Preparando Samba AD DC..."

    if [[ -e /var/lib/samba/private/sam.ldb ]]; then
        echo "[-] Ya existe una base de datos de dominio en /var/lib/samba/private/sam.ldb."
        echo "[-] Se cancela para evitar sobrescribir un dominio existente."
        return 1
    fi

    if [[ -f /etc/samba/smb.conf ]]; then
        backup_file /etc/samba/smb.conf
        mv /etc/samba/smb.conf /etc/samba/smb.conf.pre-provision
    fi

    echo
    read -r -s -p "Contraseña de Administrator del dominio: " DOMAIN_PASS
    echo
    read -r -s -p "Repite la contraseña: " DOMAIN_PASS_CONFIRM
    echo

    if [[ "$DOMAIN_PASS" != "$DOMAIN_PASS_CONFIRM" ]]; then
        echo "[-] Las contraseñas no coinciden."
        return 1
    fi

    if [[ ${#DOMAIN_PASS} -lt 8 ]]; then
        echo "[-] La contraseña debe tener al menos 8 caracteres."
        return 1
    fi

    echo "[+] Provisionando el dominio ${DOMAIN_UPPER}..."

    if ! samba-tool domain provision \
        --realm="$DOMAIN_UPPER" \
        --domain="${NAME_DOMAIN^^}" \
        --server-role=dc \
        --dns-backend=SAMBA_INTERNAL \
        --use-rfc2307 \
        --option="dns forwarder = ${DNS_FORWARDER}" \
        --adminpass="$DOMAIN_PASS"; then

        echo "[-] Ha fallado el provisionamiento de Samba."
        return 1
    fi

    unset DOMAIN_PASS DOMAIN_PASS_CONFIRM

    if [[ ! -f /etc/samba/smb.conf ]]; then
        echo "[-] Samba no ha generado /etc/samba/smb.conf."
        return 1
    fi

    echo "[+] Provisionamiento completado."
    echo "[+] Se conserva el smb.conf generado por Samba."
    testparm -s
}

# ---------------------------------------------------------------------------
# Kerberos
# ---------------------------------------------------------------------------

function krb5 {
    echo
    echo "[+] Configurando Kerberos..."

    if [[ ! -f /var/lib/samba/private/krb5.conf ]]; then
        echo "[-] No se encuentra /var/lib/samba/private/krb5.conf."
        return 1
    fi

    backup_file /etc/krb5.conf
    cp /var/lib/samba/private/krb5.conf /etc/krb5.conf

    echo "[+] /etc/krb5.conf actualizado con la configuración de Samba."
}

# ---------------------------------------------------------------------------
# Servicios y DNS local
# ---------------------------------------------------------------------------

function services {
    echo
    echo "[+] Preparando servicios..."

    # systemd-resolved puede no estar instalado en algunas instalaciones.
    if systemctl list-unit-files systemd-resolved.service --no-legend 2>/dev/null |
        grep -q '^systemd-resolved.service'; then
        if systemctl is-active --quiet systemd-resolved.service; then
            echo "[+] Deteniendo systemd-resolved para liberar su servicio DNS..."
            systemctl disable --now systemd-resolved.service
        fi
    fi

    # En un AD DC se utiliza samba-ad-dc, no los demonios independientes.
    for service in smbd nmbd winbind; do
        if systemctl list-unit-files "${service}.service" --no-legend 2>/dev/null |
            grep -q "^${service}.service"; then
            systemctl disable --now "${service}.service" 2>/dev/null || true
        fi
    done

    systemctl unmask samba-ad-dc.service
    systemctl enable samba-ad-dc.service
    systemctl restart samba-ad-dc.service

    if ! systemctl is-active --quiet samba-ad-dc.service; then
        echo "[-] samba-ad-dc no está activo."
        systemctl status samba-ad-dc.service --no-pager || true
        return 1
    fi

    echo "[+] samba-ad-dc está activo."
}

function resolv {
    echo
    echo "[+] Configurando resolución DNS local..."

    backup_file /etc/resolv.conf

    # Se reemplaza también un posible enlace simbólico a systemd-resolved.
    if [[ -L /etc/resolv.conf ]]; then
        rm /etc/resolv.conf
    fi

    cat > /etc/resolv.conf <<EOF
search ${DOMAIN_LOWER}
nameserver 127.0.0.1
EOF

    echo "[+] /etc/resolv.conf apunta al DNS local de Samba."
}

# ---------------------------------------------------------------------------
# Comprobaciones y creación opcional de usuario
# ---------------------------------------------------------------------------

function level_domain {
    echo
    echo "[+] Comprobando el nivel del dominio..."
    samba-tool domain level show

    echo
    echo "[+] Comprobando registros DNS SRV..."

    if ! host -t SRV "_ldap._tcp.${DOMAIN_LOWER}" 127.0.0.1; then
        echo "[-] No se ha podido consultar el registro SRV LDAP."
        return 1
    fi

    if ! host -t SRV "_kerberos._udp.${DOMAIN_LOWER}" 127.0.0.1; then
        echo "[-] No se ha podido consultar el registro SRV Kerberos."
        return 1
    fi

    echo
    echo "[+] Comprobando registro A del controlador..."
    host -t A "${CHANGE_HOSTNAME}.${DOMAIN_LOWER}" 127.0.0.1

    echo
    echo "[+] Comprobando configuración Samba..."
    testparm -s

    echo
    read -r -p "¿Quieres crear un usuario de dominio? (s/n): " CONFIRM
    if [[ "${CONFIRM,,}" == "s" ]]; then
        ask_required "Nombre del nuevo usuario: " USER_DOMAIN
        samba-tool user create "$USER_DOMAIN"
    fi

    echo
    echo "[+] Listando recursos compartidos (solicitará credenciales)..."
    smbclient -L localhost -U Administrator
}

# ---------------------------------------------------------------------------
# Ejecución principal
# ---------------------------------------------------------------------------

function main {
    is_root

    # No continuar si ya existe un dominio provisionado.
    if [[ -e /var/lib/samba/private/sam.ldb ]]; then
        echo "[-] Este equipo ya parece tener un dominio Samba provisionado."
        echo "[-] No se ejecutará una nueva provisión."
        exit 1
    fi

    initial_config
    pkg
    config_network
    config_hostname
    hosts
    samba
    krb5
    services
    resolv
    level_domain

    echo
    echo "=================================================="
    echo "[+] Configuración de Samba AD DC finalizada."
    echo "    Dominio:  ${DOMAIN_LOWER}"
    echo "    Realm:    ${DOMAIN_UPPER}"
    echo "    Hostname: ${CHANGE_HOSTNAME}"
    echo "    IP:       ${IP}"
    echo "=================================================="
}

main "$@"
