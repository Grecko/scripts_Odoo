#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

# --- Configuración General de Odoo IoT Box ---
ODEC_VERSION="18.0"
ODEC_REPO="https://github.com/odoo/odoo.git"
IOTBOX_INSTALL_DIR="/opt/odoo/iotbox"
IOTBOX_PORT=8069

# Directorios de Log
TEMP_LOG_FILE="/tmp/odoo_iotbox_install_$(date +%Y%m%d_%H%M%S).log"
FINAL_LOG_FILE="/var/log/odoo_iotbox_install.log"

# --- Configuración Opcional de Ngrok ---
ENABLE_NGROK="true"
NGROK_URL="https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.tgz"
NGROK_BIN_NAME="ngrok"
NGROK_INSTALL_PATH="/usr/local/bin/${NGROK_BIN_NAME}"

# --- Inicialización y configuración del archivo de log principal ---
sudo touch "${TEMP_LOG_FILE}" || { echo "Error: No se pudo crear el archivo de log temporal en ${TEMP_LOG_FILE}. Verifica permisos de /tmp."; exit 1; }
sudo chmod 666 "${TEMP_LOG_FILE}" || { echo "Error: No se pudieron cambiar los permisos del log temporal en ${TEMP_LOG_FILE}."; exit 1; }

# --- Funciones de ayuda ---
log_message() {
    local message="$1"
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo "${timestamp} - ${message}" >> "${TEMP_LOG_FILE}"
    echo "${timestamp} - ${message}"
}

error_exit() {
    log_message "Error: $1" >&2
    if [ -f "${TEMP_LOG_FILE}" ]; then
        log_message "Moviendo log temporal a ${FINAL_LOG_FILE}..."
        sudo mv "${TEMP_LOG_FILE}" "${FINAL_LOG_FILE}" || echo "Advertencia: No se pudo mover el log a ${FINAL_LOG_FILE}."
    fi
    exit 1
}

# --- Función de limpieza de instalación anterior de IoT Box ---
clean_iotbox_installation() {
    log_message "Iniciando limpieza de instalación anterior de Odoo IoT Box (si existe)..."

    sudo systemctl stop odoo-iotbox.service 2>/dev/null || true
    sudo systemctl disable odoo-iotbox.service 2>/dev/null || true
    sudo rm -f /etc/systemd/system/odoo-iotbox.service 2>/dev/null || true
    sudo systemctl daemon-reload

    sudo rm -rf "${IOTBOX_INSTALL_DIR}" 2>/dev/null || true

    if id "odoo" &>/dev/null; then
        sudo pkill -KILL -u odoo 2>/dev/null || true
        sudo userdel -r odoo 2>/dev/null || true
    fi

    sudo rm -rf /tmp/odoo_iotbox_install_*.log 2>/dev/null || true
    sudo rm -f "${FINAL_LOG_FILE}" 2>/dev/null || true

    log_message "Limpieza de IoT Box finalizada."
}

# --- Mensaje de inicio ---
log_message "--- Iniciando instalación de Odoo IoT Box ---"
log_message "Los detalles del proceso se registrarán en: ${TEMP_LOG_FILE}"

# --- Preguntar por limpieza ---
echo ""
echo "Este script instalará la Odoo IoT Box."
echo ""
read -rp "¿Desea limpiar cualquier instalación anterior de Odoo IoT Box? (Y/n): " confirm_clean
confirm_clean=${confirm_clean:-Y}

if [[ "${confirm_clean}" =~ ^[Yy]$ ]]; then
    clean_iotbox_installation
else
    log_message "Se ha omitido la limpieza de instalaciones anteriores de IoT Box."
    log_message "¡ADVERTENCIA! Si hay configuraciones previas, podría haber conflictos."
fi

# --- Actualizar sistema e instalar dependencias base de IoT Box ---
log_message "Actualizando paquetes del sistema..."
sudo apt update -y &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al actualizar paquetes."
sudo apt upgrade -y &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al actualizar el sistema."

log_message "Instalando dependencias de Odoo IoT Box..."
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
    --no-install-recommends || error_exit "Fallo al instalar dependencias del sistema para IoT Box."

log_message "Dependencias del sistema para IoT Box instaladas correctamente."

log_message "Instalando módulos globales de npm (less, less-plugin-clean-css)..."
sudo npm install -g less less-plugin-clean-css &>> "${TEMP_LOG_FILE}" || log_message "Advertencia: Fallo al instalar módulos npm globales. Esto es común en sistemas minimalistas, pero Odoo puede compilar CSS/Less internamente."

# --- Configuración de Odoo IoT Box ---
log_message "Configurando Odoo IoT Box..."
if ! id "odoo" &> /dev/null; then
    log_message "Creando usuario 'odoo' para IoT Box..."
    sudo useradd -m -d /opt/odoo -U -r -s /bin/bash odoo &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al crear usuario 'odoo'."
fi

log_message "Creando directorio de instalación IoT Box: ${IOTBOX_INSTALL_DIR}"
sudo mkdir -pv "${IOTBOX_INSTALL_DIR}" &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al crear directorio de instalación IoT Box."
sudo chown -R odoo:odoo "${IOTBOX_INSTALL_DIR}" &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al cambiar propietario de ${IOTBOX_INSTALL_DIR}."

log_message "Clonando Odoo IoT Box (${ODEC_VERSION}) con sparse-checkout..."
sudo -u odoo bash -c "
    git clone -b \"${ODEC_VERSION}\" --no-local --no-checkout --depth 1 \"${ODEC_REPO}\" \"${IOTBOX_INSTALL_DIR}/source\" || exit 1
    cd \"${IOTBOX_INSTALL_DIR}/source\" || exit 1
    git config core.sparsecheckout true || exit 1
    echo \"requirements.txt
odoo-bin
odoo/
addons/web/
addons/hw_proxy/
addons/hw_escpos/
addons/hw_l10n_mx_facturae/
addons/point_of_sale/tools/posbox/configuration/\" | tee --append .git/info/sparse-checkout > /dev/null
    git read-tree -mu HEAD || exit 1
" &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al clonar y configurar sparse-checkout de Odoo IoT Box."
log_message "Clonación escasa de IoT Box completada."

log_message "Instalando dependencias de Python de Odoo IoT Box (dentro de un entorno virtual)..."
sudo -u odoo bash -c "
    python3 -m venv \"${IOTBOX_INSTALL_DIR}/venv\" || exit 1
    \"${IOTBOX_INSTALL_DIR}/venv/bin/pip\" install wheel || exit 1
    \"${IOTBOX_INSTALL_DIR}/venv/bin/pip\" install -r \"${IOTBOX_INSTALL_DIR}/source/requirements.txt\" || exit 1
" &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al instalar dependencias de Python para IoT Box."
log_message "Dependencias de Python de IoT Box instaladas."

log_message "Configurando servicio systemd para Odoo IoT Box..."
IOT_BOX_SERVICE_NAME="odoo-iotbox"
IOT_BOX_SERVICE_FILE="/etc/systemd/system/${IOT_BOX_SERVICE_NAME}.service"

sudo tee "${IOT_BOX_SERVICE_FILE}" > /dev/null <<EOF
[Unit]
Description=Odoo IoT Box Service
After=network.target

[Service]
Type=simple
User=odoo
Group=odoo
WorkingDirectory=${IOTBOX_INSTALL_DIR}/source
ExecStart=${IOTBOX_INSTALL_DIR}/venv/bin/python3 ${IOTBOX_INSTALL_DIR}/source/odoo-bin \
    --addons-path=${IOTBOX_INSTALL_DIR}/source/addons \
    --without-demo=all \
    --log-level=info \
    --xmlrpc-port=${IOTBOX_PORT} \
    --data-dir=${IOTBOX_INSTALL_DIR}/data \
    --no-database
StandardOutput=journal
StandardError=journal
Restart=on-failure
SyslogIdentifier=odoo-iotbox

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al recargar systemd daemon."
sudo systemctl enable "${IOT_BOX_SERVICE_NAME}" &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al habilitar servicio iotbox."
sudo systemctl start "${IOT_BOX_SERVICE_NAME}" &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al iniciar servicio iotbox."
log_message "Odoo IoT Box configurada y el servicio iniciado."

# --- Configuración Opcional de Ngrok (para IoT Box) ---
if [ "${ENABLE_NGROK}" = "true" ]; then
    log_message "Ngrok habilitado. Descargando e instalando Ngrok desde ${NGROK_URL}..."
    curl -s "${NGROK_URL}" -o /tmp/ngrok.tgz &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al descargar Ngrok."
    sudo tar -xvzf /tmp/ngrok.tgz -C /tmp/ &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al descomprimir Ngrok."
    sudo mv "/tmp/${NGROK_BIN_NAME}" "${NGROK_INSTALL_PATH}" &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al mover Ngrok al directorio de instalación."
    sudo rm -v /tmp/ngrok.tgz &>> "${TEMP_LOG_FILE}"
    sudo rm -v "/tmp/${NGROK_BIN_NAME}" &>> "${TEMP_LOG_FILE}"
    sudo chmod +x "${NGROK_INSTALL_PATH}" &>> "${TEMP_LOG_FILE}"
    log_message "Ngrok instalado en ${NGROK_INSTALL_PATH}."

    log_message "Configurando servicio systemd para Ngrok..."
    NGROK_SERVICE_NAME="ngrok"
    NGROK_SERVICE_FILE="/etc/systemd/system/${NGROK_SERVICE_NAME}.service"

    sudo tee "${NGROK_SERVICE_FILE}" > /dev/null <<EOF
[Unit]
Description=Ngrok Tunnel Service
After=network.target odoo-iotbox.service

[Service]
ExecStart=${NGROK_INSTALL_PATH} http ${IOTBOX_PORT}
Restart=on-failure
SyslogIdentifier=ngrok

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al recargar systemd daemon."
    sudo systemctl enable "${NGROK_SERVICE_NAME}" &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al habilitar servicio ngrok."
    sudo systemctl start "${NGROK_SERVICE_NAME}" &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al iniciar servicio ngrok."
    log_message "Ngrok configurado y el servicio iniciado."
else
    log_message "Ngrok está deshabilitado según la configuración."
fi

log_message "--- Instalación de Odoo IoT Box completada ---"
log_message "Verifica el estado del servicio Odoo IoT Box con:"
log_message "sudo systemctl status ${IOT_BOX_SERVICE_NAME}"
log_message "Y los logs con: sudo journalctl -u ${IOT_BOX_SERVICE_NAME} -f"

# Mover el log temporal a la ubicación final
if [ -f "${TEMP_LOG_FILE}" ]; then
    log_message "Moviendo log temporal a ${FINAL_LOG_FILE}..."
    sudo mv "${TEMP_LOG_FILE}" "${FINAL_LOG_FILE}" || log_message "Advertencia: No se pudo mover el log a ${FINAL_LOG_FILE}. Permisos incorrectos o el archivo ya existe."
fi

log_message "¡Script de instalación de Odoo IoT Box terminado!"
log_message "Ahora procede con la ejecución del script 'configure_pos_kiosk.sh'."
