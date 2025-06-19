#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

# --- Configuración General del Odoo Completo y TPV Kiosco ---
ODEC_VERSION="18.0" # Versión de Odoo a instalar (Odoo completo)
ODEC_REPO="https://github.com/odoo/odoo.git"
ODOO_INSTALL_DIR="/opt/odoo/full" # Directorio de instalación de Odoo
ODOO_PORT=8069 # Puerto de Odoo

# Configuración de PostgreSQL
PG_VERSION="16" # Versión de PostgreSQL, ajusta si es necesario (ej: 14, 15, 16)
PG_USER="odoo_user" # Usuario de PostgreSQL para Odoo
PG_DATABASE="odoo_db" # Nombre de la base de datos de Odoo

# Configuración del Usuario TPV y Autologin para el Kiosco
TPV_USER="tpvuser"
TPV_PASSWORD="1234"

# URL de Chrome (se conectará a la instancia local de Odoo)
CHROME_POS_URL="http://localhost:${ODOO_PORT}"

# Directorios de Log
TEMP_LOG_FILE="/tmp/odoo_kiosc_install_$(date +%Y%m%d_%H%M%S).log"
FINAL_LOG_FILE="/var/log/odoo_kiosc_install.log"

# --- Inicialización y configuración del archivo de log principal ---
sudo touch "${TEMP_LOG_FILE}" || { echo "Error: No se pudo crear el archivo de log temporal en ${TEMP_LOG_FILE}. Verifica permisos de /tmp."; exit 1; }
sudo chmod 666 "${TEMP_LOG_FILE}" || { echo "Error: No se pudieron cambiar los permisos del log temporal en ${TEMP_LOG_FILE}."; exit 1; }

# --- Funciones de ayuda ---
log_message() {
    local message="$1"
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo "${timestamp} - ${message}" | sudo tee -a "${TEMP_LOG_FILE}" >/dev/null
    echo "${timestamp} - ${message}"
}

error_exit() {
    log_message "Error: $1" >&2
    if [ -f "${TEMP_LOG_FILE}" ]; then
        log_message "Moviendo log temporal a ${FINAL_LOG_FILE}..."
        sudo mv "${TEMP_LOG_FILE}" "${FINAL_LOG_FILE}" || echo "Advertencia: No se pudo mover el log a ${FINAL_LOG_FILE}. Verifica permisos."
    fi
    exit 1
}

# --- Función de limpieza completa ---
clean_previous_installations() {
    log_message "Iniciando limpieza profunda de instalaciones anteriores de Odoo/IoT Box/Kiosco..."

    # Detener y deshabilitar servicios anteriores
    sudo systemctl stop odoo-iotbox.service 2>/dev/null || true
    sudo systemctl disable odoo-iotbox.service 2>/dev/null || true
    sudo rm -f /etc/systemd/system/odoo-iotbox.service 2>/dev/null || true
    sudo systemctl stop odoo.service 2>/dev/null || true
    sudo systemctl disable odoo.service 2>/dev/null || true
    sudo rm -f /etc/systemd/system/odoo.service 2>/dev/null || true
    sudo systemctl stop ngrok.service 2>/dev/null || true
    sudo systemctl disable ngrok.service 2>/dev/null || true
    sudo rm -f /etc/systemd/system/ngrok.service 2>/dev/null || true
    sudo systemctl daemon-reload # Recargar systemd

    # Limpieza de PostgreSQL: Detener Odoo, eliminar DB y usuario
    log_message "Limpiando base de datos y usuario de PostgreSQL si existen..."
    # Asegúrate de que no haya conexiones a la base de datos para poder eliminarla
    sudo -u postgres psql -c "SELECT pg_terminate_backend(pg_stat_activity.pid) FROM pg_stat_activity WHERE pg_stat_activity.datname = '${PG_DATABASE}';" 2>/dev/null || true
    sudo -u postgres psql -c "DROP DATABASE IF EXISTS ${PG_DATABASE};" &>> "${TEMP_LOG_FILE}" || true
    sudo -u postgres psql -c "DROP USER IF EXISTS ${PG_USER};" &>> "${TEMP_LOG_FILE}" || true
    log_message "Limpieza de PostgreSQL intentada."

    # Eliminar directorios de instalación de Odoo
    sudo rm -rf "/opt/odoo/iotbox" 2>/dev/null || true
    sudo rm -rf "${ODOO_INSTALL_DIR}" 2>/dev/null || true
    sudo rm -rf "/opt/odoo" 2>/dev/null || true # Eliminar el directorio raíz de odoo si es seguro

    # Eliminar usuarios de Odoo/TPV
    if id "odoo" &>/dev/null; then
        log_message "Eliminando usuario 'odoo'..."
        sudo pkill -KILL -u odoo 2>/dev/null || true
        sudo userdel -r odoo 2>/dev/null || true
    fi
    if id "${TPV_USER}" &>/dev/null; then
        log_message "Eliminando usuario '${TPV_USER}'..."
        sudo pkill -KILL -u "${TPV_USER}" 2>/dev/null || true
        sudo userdel -r "${TPV_USER}" 2>/dev/null || true
    fi

    # Limpiar configuraciones de LightDM y Xorg
    log_message "Limpiando configuraciones de LightDM y Xorg..."
    # ¡Esta es la parte que ha sido más problemática, eliminamos todo para que se regenere!
    sudo rm -rf /etc/lightdm/* 2>/dev/null || true
    sudo rm -f /etc/X11/xorg.conf 2>/dev/null || true
    sudo rm -rf /etc/X11/xorg.conf.d/* 2>/dev/null || true

    # Eliminar configuraciones de usuario del kiosco (LXDE autostart, etc.)
    sudo rm -rf /home/"${TPV_USER}"/.config/lxsession/ 2>/dev/null || true
    sudo rm -rf /home/"${TPV_USER}"/.config/openbox/ 2>/dev/null || true
    sudo rm -rf /home/"${TPV_USER}"/.cache/lxsession/ 2>/dev/null || true


    # Eliminar logs temporales y finales de instalaciones anteriores
    sudo rm -rf /tmp/odoo_iotbox_install_*.log 2>/dev/null || true
    sudo rm -f "/var/log/odoo_iotbox_install.log" 2>/dev/null || true
    sudo rm -rf /tmp/odoo_kiosk_install_*.log 2>/dev/null || true
    sudo rm -f "${FINAL_LOG_FILE}" 2>/dev/null || true

    # Eliminar script de monitoreo de Chrome y cron job si existieran
    sudo rm -f /usr/local/bin/chrome_monitor.sh 2>/dev/null || true
    (sudo crontab -u "${TPV_USER}" -l 2>/dev/null | grep -v 'chrome_monitor.sh') | sudo crontab -u "${TPV_USER}" - 2>/dev/null || true

    log_message "Limpieza profunda finalizada."
}


# --- Mensaje de inicio ---
log_message "--- Iniciando instalación de Odoo ${ODEC_VERSION} completo y TPV Kiosco ---"
log_message "Los detalles del proceso se registrarán en: ${TEMP_LOG_FILE}"

# --- Preguntar por limpieza ---
echo ""
echo "Este script instalará Odoo ${ODEC_VERSION} completo y configurará la mini PC como TPV Kiosco."
echo ""
read -rp "¿Desea realizar una limpieza profunda de instalaciones anteriores de Odoo/IoT Box/Kiosco? (Y/n): " confirm_clean
confirm_clean=${confirm_clean:-Y}

if [[ "${confirm_clean}" =~ ^[Yy]$ ]]; then
    clean_previous_installations
else
    log_message "Se ha omitido la limpieza profunda. ¡ADVERTENCIA! Podría haber conflictos con configuraciones previas."
fi

# --- 1. Actualizar sistema y habilitar repositorios esenciales ---
log_message "Actualizando paquetes del sistema y habilitando repositorios..."
sudo apt update -y &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al actualizar paquetes."
sudo apt upgrade -y &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al actualizar el sistema."

# Asegurarse de que los repositorios estén habilitados (main, restricted, universe, multiverse)
sudo apt install -y software-properties-common &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al instalar software-properties-common."
sudo add-apt-repository universe -y &>> "${TEMP_LOG_FILE}" || log_message "Advertencia: El repositorio 'universe' ya podría estar habilitado o falló al añadirlo."
sudo add-apt-repository multiverse -y &>> "${TEMP_LOG_FILE}" || log_message "Advertencia: El repositorio 'multiverse' ya podría estar habilitado o falló al añadirlo."
sudo add-apt-repository restricted -y &>> "${TEMP_LOG_FILE}" || log_message "Advertencia: El repositorio 'restricted' ya podría estar habilitado o falló al añadirlo."
sudo apt update -y &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al actualizar repositorios después de añadir."

# --- 2. Instalar dependencias base, PostgreSQL y Entorno Gráfico ---
log_message "Instalando dependencias base del sistema, PostgreSQL, entorno gráfico (LXDE) y Chrome..."
sudo apt install -y \
    python3 \
    python3-pip \
    python3-dev \
    python3.12-venv \
    build-essential \
    libxml2-dev \
    libxslt1-dev \
    libjpeg-dev \
    zlib1g-dev \
    libldap2-dev \
    libsasl2-dev \
    libffi-dev \
    libcups2-dev \
    libssl-dev \
    git \
    npm \
    nodejs \
    curl \
    unzip \
    net-tools \
    libpq-dev \
    postgresql-common \
    postgresql-${PG_VERSION} \
    wkhtmltopdf \
    xserver-xorg \
    lightdm \
    lxde-core \
    openbox \
    --no-install-recommends &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al instalar dependencias del sistema y entorno gráfico."

# Instalar Google Chrome oficial
log_message "Descargando e instalando Google Chrome..."

# Asegurarse de que el directorio /etc/apt/keyrings exista
sudo mkdir -p /etc/apt/keyrings &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al crear el directorio /etc/apt/keyrings."

# Descargar la clave GPG de Chrome. Usamos sudo tee para sobrescribir si ya existe, y sintonizamos el gpg
wget -q -O - https://dl.google.com/linux/linux_signing_key.pub | \
    sudo gpg --dearmor --batch --yes -o /etc/apt/keyrings/google-chrome.gpg &>> "${TEMP_LOG_FILE}" || \
    error_exit "Fallo al añadir la clave GPG de Chrome. Revisa permisos o si wget/gpg están disponibles."

# Añadir el repositorio de Chrome. 'tee' con '>' sobrescribe el archivo si ya existe.
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" | sudo tee /etc/apt/sources.list.d/google-chrome.list > /dev/null || error_exit "Fallo al añadir el repositorio de Chrome."

sudo apt update -y &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al actualizar repositorios después de añadir Chrome."
sudo apt install -y google-chrome-stable &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al instalar Google Chrome estable."

# Instalar Chrome Remote Desktop (directamente con el .deb para manejar dependencias)
log_message "Descargando e instalando Chrome Remote Desktop..."
CRD_DEB_URL="https://dl.google.com/linux/direct/chrome-remote-desktop_current_amd64.deb"
CRD_DEB_FILE="/tmp/chrome-remote-desktop_current_amd64.deb"

wget "${CRD_DEB_URL}" -O "${CRD_DEB_FILE}" &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al descargar el paquete .deb de Chrome Remote Desktop."
sudo apt install -y "${CRD_DEB_FILE}" &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al instalar Chrome Remote Desktop con sus dependencias."
rm "${CRD_DEB_FILE}" &>> "${TEMP_LOG_FILE}" || log_message "Advertencia: Fallo al eliminar el archivo .deb temporal de Chrome Remote Desktop."
log_message "Chrome Remote Desktop instalado. Requiere configuración manual posterior."


log_message "Instalando módulos globales de npm (less, less-plugin-clean-css)..."
sudo npm install -g less less-plugin-clean-css &>> "${TEMP_LOG_FILE}" || log_message "Advertencia: Fallo al instalar módulos npm globales. Esto es común en sistemas minimalistas, pero Odoo puede compilar CSS/Less internamente."

# --- 3. Configuración de PostgreSQL ---
log_message "Configurando PostgreSQL..."
sudo service postgresql start &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al iniciar PostgreSQL."
log_message "Creando usuario de PostgreSQL '${PG_USER}'..."
sudo -u postgres psql -c "CREATE USER ${PG_USER} WITH PASSWORD '${TPV_PASSWORD}';" &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al crear usuario de PostgreSQL."
log_message "Creando base de datos de PostgreSQL '${PG_DATABASE}' para Odoo..."
sudo -u postgres psql -c "CREATE DATABASE ${PG_DATABASE} OWNER ${PG_USER};" &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al crear base de datos de PostgreSQL."
log_message "PostgreSQL configurado correctamente."


# --- 4. Instalación y Configuración de Odoo ---
log_message "Configurando Odoo ${ODEC_VERSION}..."
if ! id "odoo" &> /dev/null; then
    log_message "Creando usuario 'odoo' para Odoo..."
    sudo useradd -m -d /opt/odoo -U -r -s /bin/bash odoo &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al crear usuario 'odoo'."
fi

log_message "Creando directorio de instalación de Odoo: ${ODOO_INSTALL_DIR}"
sudo mkdir -pv "${ODOO_INSTALL_DIR}" &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al crear directorio de instalación de Odoo."
sudo chown -R odoo:odoo "${ODOO_INSTALL_DIR}" &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al cambiar propietario de ${ODOO_INSTALL_DIR}."

log_message "Clonando Odoo ${ODEC_VERSION} completo..."
# Añadir la opción --depth 1 si no quieres todo el historial (más rápido)
sudo -u odoo bash -c "git clone -b \"${ODEC_VERSION}\" --depth 1 \"${ODEC_REPO}\" \"${ODOO_INSTALL_DIR}/source\"" &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al clonar Odoo."
log_message "Clonación de Odoo completada."

log_message "Instalando dependencias de Python de Odoo (dentro de un entorno virtual)..."
sudo -u odoo bash -c "
    python3 -m venv \"${ODOO_INSTALL_DIR}/venv\" || exit 1
    \"${ODOO_INSTALL_DIR}/venv/bin/pip\" install wheel || exit 1
    \"${ODOO_INSTALL_DIR}/venv/bin/pip\" install -r \"${ODOO_INSTALL_DIR}/source/requirements.txt\" || exit 1
" &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al instalar dependencias de Python para Odoo."
log_message "Dependencias de Python de Odoo instaladas."

log_message "Creando archivo de configuración de Odoo..."
ODOO_CONFIG_DIR="/etc/odoo"
ODOO_CONFIG_FILE="${ODOO_CONFIG_DIR}/odoo.conf"
sudo mkdir -pv "${ODOO_CONFIG_DIR}" &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al crear directorio de configuración de Odoo."

sudo tee "${ODOO_CONFIG_FILE}" > /dev/null <<EOF
[options]
; This is the password that allows database operations:
admin_passwd = admin
db_host = False
db_port = False
db_user = ${PG_USER}
db_password = ${TPV_PASSWORD}
addons_path = ${ODOO_INSTALL_DIR}/source/addons
xmlrpc_port = ${ODOO_PORT}
data_dir = ${ODOO_INSTALL_DIR}/data
logfile = /var/log/odoo/odoo.log
log_level = info
EOF

sudo chown odoo:odoo "${ODOO_CONFIG_FILE}" &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al cambiar propietario de odoo.conf."
sudo chmod 640 "${ODOO_CONFIG_FILE}" &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al cambiar permisos de odoo.conf."

sudo mkdir -pv /var/log/odoo &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al crear directorio de logs de Odoo."
sudo chown -R odoo:odoo /var/log/odoo &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al cambiar propietario de /var/log/odoo."


log_message "Configurando servicio systemd para Odoo ${ODEC_VERSION}..."
ODOO_SERVICE_NAME="odoo"
ODOO_SERVICE_FILE="/etc/systemd/system/${ODOO_SERVICE_NAME}.service"

sudo tee "${ODOO_SERVICE_FILE}" > /dev/null <<EOF
[Unit]
Description=Odoo ${ODEC_VERSION} Service
Requires=postgresql.service
After=network.target postgresql.service

[Service]
Type=simple
User=odoo
Group=odoo
WorkingDirectory=${ODOO_INSTALL_DIR}/source
ExecStart=${ODOO_INSTALL_DIR}/venv/bin/python3 ${ODOO_INSTALL_DIR}/source/odoo-bin -c ${ODOO_CONFIG_FILE}
StandardOutput=journal
StandardError=journal
Restart=on-failure
SyslogIdentifier=odoo

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al recargar systemd daemon."
sudo systemctl enable "${ODOO_SERVICE_NAME}" &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al habilitar servicio odoo."
sudo systemctl start "${ODOO_SERVICE_NAME}" &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al iniciar servicio odoo."
log_message "Odoo ${ODEC_VERSION} configurado y el servicio iniciado."

# --- Asegurar la creación del usuario TPV ---
log_message "Asegurando que el usuario '${TPV_USER}' exista..."
if ! id "${TPV_USER}" &> /dev/null; then
    sudo useradd -m -s /bin/bash "${TPV_USER}" &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al crear el usuario '${TPV_USER}'."
    echo "${TPV_USER}:${TPV_PASSWORD}" | sudo chpasswd &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al establecer contraseña para '${TPV_USER}'."
    log_message "Usuario '${TPV_USER}' creado."
else
    log_message "El usuario '${TPV_USER}' ya existe."
fi

# --- 5. Configuración Específica para Mini PC (Drivers AMD y entorno gráfico) ---
log_message "--- Aplicando configuraciones específicas para Mini PC (Drivers AMD y entorno gráfico) ---"

# 5.1. Soluciones de drivers AMD (Temash/Kabini)
# Se crea un archivo de respaldo antes de modificar GRUB
sudo cp /etc/default/grub /etc/default/grub.bak_$(date +%Y%m%d%H%M%S)

# Eliminar líneas anteriores de GRUB_CMDLINE_LINUX_DEFAULT si existen para asegurar una sola línea
sudo sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT=/d' /etc/default/grub
# Añadir la nueva línea con las opciones específicas del driver
echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash radeon.si_support=1 amdgpu.si_support=0"' | sudo tee -a /etc/default/grub

# Blacklist el módulo amdgpu para evitar que se cargue
sudo sh -c 'echo "blacklist amdgpu" > /etc/modprobe.d/blacklist-amdgpu.conf'

# Actualizar initramfs para aplicar los cambios del kernel/módulos
sudo update-initramfs -u &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al actualizar initramfs para aplicar cambios de drivers."

# Reinstalar firmware de Linux (contiene firmware para AMD)
sudo apt install --reinstall -y linux-firmware &>> "${TEMP_LOG_FILE}" || log_message "Advertencia: Fallo al reinstalar linux-firmware. Podría no ser crítico si ya está presente."

# Reinstalar xrdp (para limpiar ese error secundario del log Xorg si aparece)
sudo apt install --reinstall -y xrdp &>> "${TEMP_LOG_FILE}" || log_message "Advertencia: Fallo al reinstalar xrdp. No crítico para el inicio gráfico."

# 5.2. Configuración de LightDM y Autologin
log_message "Configurando autologin para el usuario '${TPV_USER}' con LightDM..."
# Eliminar cualquier lightdm.conf existente para asegurar una regeneración limpia
sudo rm -f /etc/lightdm/lightdm.conf 2>/dev/null || true
# Forzar la reconfiguración para que LightDM cree un archivo de configuración predeterminado y limpio
sudo dpkg-reconfigure lightdm # Asegúrate de seleccionar 'lightdm' si te pregunta

# Crear el archivo lightdm.conf con las opciones de autologin y session LXDE
sudo tee /etc/lightdm/lightdm.conf > /dev/null <<EOF
[SeatDefaults]
autologin-user=${TPV_USER}
autologin-user-timeout=0
user-session=LXDE
EOF
sudo chmod 644 /etc/lightdm/lightdm.conf &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al establecer permisos para lightdm.conf."
log_message "Auto-login configurado para '${TPV_USER}'."


# 5.3. Configuración de Chrome en modo Kiosco y auto-relanzamiento
log_message "Configurando Chrome en modo Kiosco y auto-relanzamiento para ${TPV_USER}..."

# INICIO DE LA CORRECCIÓN PARA EL ERROR DE AUTOSTART
# Crear el directorio .config y sus subdirectorios con root, luego cambiar propietario para asegurar permisos.
# Esto evita problemas si los permisos predeterminados de tpvuser no permitían la creación profunda de directorios.
sudo mkdir -p "/home/${TPV_USER}/.config/lxsession/LXDE/" &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al crear directorio de autostart para ${TPV_USER} (como root)."
sudo chown -R "${TPV_USER}:${TPV_USER}" "/home/${TPV_USER}/.config" &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al cambiar propietario de .config para ${TPV_USER}."
# FIN DE LA CORRECCIÓN

CHROME_AUTOSTART_FILE="/home/${TPV_USER}/.config/lxsession/LXDE/autostart"
sudo tee "${CHROME_AUTOSTART_FILE}" > /dev/null <<EOF
@lxpanel --profile LXDE
@pcmanfm --desktop --profile LXDE
@xscreensaver -no-splash
@/usr/bin/xset s off
@/usr/bin/xset -dpms
@/usr/bin/xset noblank
@/usr/bin/setxkbmap -option terminate:ctrl_alt_bksp

# Loop para asegurar que Chrome siempre se esté ejecutando
@while true; do
    /usr/bin/google-chrome-stable --kiosk --incognito --disable-infobars --noerrdialogs --check-for-update-at-startup=0 --start-maximized "${CHROME_POS_URL}" || true
    sleep 5
done
EOF
sudo chown "${TPV_USER}:${TPV_USER}" "${CHROME_AUTOSTART_FILE}" &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al cambiar propietario del script de autostart de Chrome."
sudo chmod +x "${CHROME_AUTOSTART_FILE}" &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al hacer ejecutable el script de autostart de Chrome."

log_message "Chrome en modo Kiosco configurado para auto-relanzamiento."

# --- Mensajes Finales ---
log_message "--- Instalación de Odoo ${ODEC_VERSION} completo y TPV Kiosco completada ---"
log_message "Verifica el estado del servicio Odoo con: sudo systemctl status odoo.service"
log_message "Y los logs con: sudo journalctl -u odoo.service -f"
log_message "Para el kiosco, el sistema se reiniciará automáticamente al próximo arranque con Chrome abriendo la URL local."
log_message "¡RECUERDA CAMBIAR LA CONTRASEÑA DE TPV_PASSWORD EN EL SCRIPT!"

# Mover el log temporal a la ubicación final
if [ -f "${TEMP_LOG_FILE}" ]; then
    log_message "Moviendo log temporal a ${FINAL_LOG_FILE}..."
    sudo mv "${TEMP_LOG_FILE}" "${FINAL_LOG_FILE}" || log_message "Advertencia: No se pudo mover el log a ${FINAL_LOG_FILE}. Permisos incorrectos o el archivo ya existe."
fi

log_message "¡Script de instalación de Odoo Kiosco Todo en Uno terminado!"
log_message "Ahora, para configurar Chrome Remote Desktop para soporte, sigue los siguientes pasos manuales."
log_message "Se recomienda REINICIAR AHORA la mini PC para aplicar los cambios de autologin y modo kiosco."
log_message "sudo reboot"
