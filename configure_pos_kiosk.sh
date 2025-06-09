#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

# --- Configuración del TPV Kiosco ---
TPV_USER="tpvuser" # Nombre de usuario para el modo kiosco
TPV_PASSWORD="change_me_kiosk_password" # ¡¡CAMBIA ESTO!! Contraseña para el usuario TPV
CHROME_POS_URL="https://greckob.com/pos/web?config_id=1" # ¡URL de tu PoS en gCloud!

TEMP_LOG_FILE="/tmp/pos_kiosk_configure_$(date +%Y%m%d_%H%M%S).log"
FINAL_LOG_FILE="/var/log/pos_kiosk_configure.log"

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

get_local_ip() {
    ip route get 1.1.1.1 | awk '{print $7; exit}'
}

# --- Función de limpieza de configuraciones anteriores del kiosco ---
clean_kiosk_config() {
    log_message "Iniciando limpieza de configuración anterior de TPV Kiosco (si existe)..."

    if id "${TPV_USER}" &>/dev/null; then
        log_message "Limpiando usuario ${TPV_USER}..."
        sudo pkill -KILL -u "${TPV_USER}" 2>/dev/null || true
        sudo userdel -r "${TPV_USER}" 2>/dev+null || true
    fi

    sudo sed -i '/^autologin-user=/d' /etc/lightdm/lightdm.conf 2>/dev/null || true
    sudo sed -i '/^autologin-user-timeout=/d' /etc/lightdm/lightdm.conf 2>/dev/null || true

    local CRONTAB_CLEAN_TEMP_FILE="/tmp/root_crontab_clean_temp_$(date +%s)"
    sudo crontab -l -u root 2>/dev/null | grep -v "${MONITOR_SCRIPT}" > "${CRONTAB_CLEAN_TEMP_FILE}" || true
    sudo crontab "${CRONTAB_CLEAN_TEMP_FILE}" -u root 2>/dev/null || true
    rm -f "${CRONTAB_CLEAN_TEMP_FILE}"

    sudo rm -f /usr/local/bin/chrome_monitor.sh 2>/dev/null || true
    sudo rm -f /var/log/chrome_monitor.log 2>/dev/null || true

    sudo rm -rf /tmp/pos_kiosk_configure_*.log 2>/dev/null || true
    sudo rm -f "${FINAL_LOG_FILE}" 2>/dev/null || true

    log_message "Limpieza de configuración de kiosco finalizada."
}

# --- Mensaje de inicio ---
log_message "--- Iniciando configuración de TPV Kiosco (Ubuntu 24.04 LTS Minimal) ---"
log_message "Este script instalará el entorno gráfico, Chrome y configurará el auto-inicio en modo Kiosco."
log_message "Los detalles del proceso se registrarán en: ${TEMP_LOG_FILE}"

# --- Preguntar por limpieza ---
echo ""
read -rp "¿Desea limpiar cualquier configuración anterior de TPV Kiosco (usuario, auto-login, monitoreo)? (Y/n): " confirm_clean
confirm_clean=${confirm_clean:-Y}

if [[ "${confirm_clean}" =~ ^[Yy]$ ]]; then
    clean_kiosk_config
else
    log_message "Se ha omitido la limpieza de configuraciones anteriores de TPV Kiosco."
    log_message "¡ADVERTENCIA! Si hay configuraciones previas, podría haber conflictos."
fi

# --- Actualizar sistema e instalar dependencias del entorno gráfico y Chrome ---
log_message "Actualizando paquetes del sistema..."
sudo apt update -y &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al actualizar paquetes."
sudo apt upgrade -y &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al actualizar el sistema."

# --- INICIO: Instalación explícita de cron ---
log_message "Verificando e instalando el paquete 'cron' si no está presente..."
if ! dpkg -s cron &> /dev/null; then
    sudo apt install -y cron &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al instalar el paquete 'cron'."
    log_message "Paquete 'cron' instalado correctamente."
else
    log_message "El paquete 'cron' ya está instalado."
fi
# --- FIN: Instalación explícita de cron ---

log_message "Instalando dependencias de entorno gráfico y Google Chrome..."
sudo apt install -y \
    xorg \
    lightdm \
    lxde-core \
    gnupg \
    apt-transport-https \
    ca-certificates \
    software-properties-common \
    --no-install-recommends || error_exit "Fallo al instalar dependencias del entorno gráfico y Chrome."

log_message "Dependencias del entorno gráfico y Chrome instaladas correctamente."

# --- Instalar Google Chrome (si no fue instalado por el script de IoT Box) ---
if ! command -v google-chrome &> /dev/null; then
    log_message "Google Chrome no está instalado, procediendo con la instalación..."
    sudo wget -q -O - https://dl.google.com/linux/linux_signing_key.pub | sudo gpg --dearmor -o /etc/apt/keyrings/google-chrome.gpg &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al añadir clave GPG de Google Chrome."
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" | sudo tee /etc/apt/sources.list.d/google-chrome.list &> /dev/null || error_exit "Fallo al añadir repositorio de Google Chrome."
    sudo apt update -y &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al actualizar paquetes después de añadir repo Chrome."
    sudo apt install -y google-chrome-stable &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al instalar Google Chrome."
    log_message "Google Chrome instalado."
else
    log_message "Google Chrome ya está instalado. Omitiendo instalación."
fi

# --- Configuración del Usuario TPV y Auto-login ---
log_message "Creando usuario '${TPV_USER}' para el TPV Kiosco..."
if ! id "${TPV_USER}" &> /dev/null; then
    sudo adduser --gecos "TPV Kiosco User" --disabled-password "${TPV_USER}" &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al crear usuario '${TPV_USER}'."
    echo "${TPV_USER}:${TPV_PASSWORD}" | sudo chpasswd &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al establecer contraseña para '${TPV_USER}'."
else
    log_message "El usuario '${TPV_USER}' ya existe."
fi

log_message "Configurando auto-login para el usuario '${TPV_USER}' con LightDM..."

if [ ! -f /etc/lightdm/lightdm.conf ]; then
    log_message "lightdm.conf no encontrado, creando un archivo básico."
    sudo tee /etc/lightdm/lightdm.conf > /dev/null <<EOF
[SeatDefaults]
EOF
    sudo chmod 644 /etc/lightdm/lightdm.conf &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al establecer permisos para lightdm.conf."
fi

sudo sed -i 's/^#autologin-user=.*/autologin-user='"${TPV_USER}"'/' /etc/lightdm/lightdm.conf
sudo sed -i 's/^#autologin-user-timeout=.*/autologin-user-timeout=0/' /etc/lightdm/lightdm.conf
log_message "Auto-login configurado para '${TPV_USER}'."

# --- Configuración de Chrome en Modo Kiosco y Reinicio Automático ---
log_message "Configurando Chrome en modo Kiosco y reinicio automático..."

sudo -u "${TPV_USER}" mkdir -p "/home/${TPV_USER}/.config/lxsession/LXDE/" &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al crear directorio de autostart para ${TPV_USER}."

CHROME_START_SCRIPT="/home/${TPV_USER}/.config/lxsession/LXDE/autostart"
sudo tee "${CHROME_START_SCRIPT}" > /dev/null <<EOF
@/usr/bin/google-chrome --kiosk --incognito --disable-infobars --noerrdialogs --check-for-update-at-startup=0 --start-maximized ${CHROME_POS_URL}
EOF
sudo chown "${TPV_USER}:${TPV_USER}" "${CHROME_START_SCRIPT}" &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al cambiar propietario del script de inicio de Chrome."
sudo chmod +x "${CHROME_START_SCRIPT}" &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al hacer ejecutable el script de inicio de Chrome."

MONITOR_SCRIPT="/usr/local/bin/chrome_monitor.sh"
sudo tee "${MONITOR_SCRIPT}" > /dev/null <<EOF
#!/usr/bin/env bash
sleep 30
if ! pgrep -x "chrome" > /dev/null; then
    echo "$(date) - Chrome process not found. Rebooting..." >> /var/log/chrome_monitor.log
    sudo reboot
fi
EOF
sudo chmod +x "${MONITOR_SCRIPT}" &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al hacer ejecutable el script de monitoreo de Chrome."
sudo chown root:root "${MONITOR_SCRIPT}" &>> "${TEMP_LOG_FILE}"

log_message "Configurando tarea cron para monitorear Chrome..."

if ! sudo systemctl is-active --quiet cron; then
    log_message "El servicio cron no está activo. Intentando iniciarlo y habilitarlo..."
    sudo systemctl start cron &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al iniciar el servicio cron."
    sudo systemctl enable cron &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al habilitar el servicio cron."
    log_message "Servicio cron iniciado y habilitado."
else
    log_message "El servicio cron ya está activo."
fi

CRONTAB_TEMP_FILE="/tmp/root_crontab_temp_$(date +%s)"

sudo crontab -l -u root 2>/dev/null | grep -v "${MONITOR_SCRIPT}" > "${CRONTAB_TEMP_FILE}" || true

echo "*/5 * * * * ${MONITOR_SCRIPT} >> /var/log/chrome_monitor.log 2>&1" >> "${CRONTAB_TEMP_FILE}"

log_message "DEBUG: Contenido del archivo temporal ${CRONTAB_TEMP_FILE}:"
sudo cat "${CRONTAB_TEMP_FILE}" >> "${TEMP_LOG_FILE}"

sudo crontab "${CRONTAB_TEMP_FILE}" -u root &>> "${TEMP_LOG_FILE}" || error_exit "Fallo al configurar cron para monitoreo de Chrome."

rm "${CRONTAB_TEMP_FILE}"

log_message "Monitoreo de Chrome configurado. El sistema se reiniciará si Chrome se cierra."

log_message "--- Configuración de TPV Kiosco completada ---"

log_message "--- Pasos Finales (Manuales y Verificación) ---"
log_message "1. REINICIA LA MINI PC AHORA para que los cambios de auto-login y Chrome surtan efecto:"
log_message "   sudo reboot"
log_message "2. Después del reinicio, el sistema debería iniciar sesión automáticamente como '${TPV_USER}'"
log_message "   y Chrome debería abrirse en modo kiosco con la URL de tu PoS."
log_message "3. CONECTA TU ODOO EN GCLOUD A LA IOT BOX:"
log_message "   En tu instancia de Odoo (https://greckob.com), ve a Punto de Venta -> Configuración -> IoT Box."
log_message "   Añade una nueva IoT Box con la dirección IP LOCAL de esta mini PC y el puerto 8069."
log_message "   (Puedes obtener la IP local con: ip a | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1')"
log_message "4. VERIFICA LA CONEXIÓN DE HARDWARE: Asegúrate de que las impresoras, escáneres, etc., estén conectados y reconocidos."

if [ -f "${TEMP_LOG_FILE}" ]; then
    log_message "Moviendo log temporal a ${FINAL_LOG_FILE}..."
    sudo mv "${TEMP_LOG_FILE}" "${FINAL_LOG_FILE}" || log_message "Advertencia: No se pudo mover el log a ${FINAL_LOG_FILE}. Permisos incorrectos o el archivo ya existe."
fi

log_message "¡Script de configuración de TPV Kiosco terminado! Por favor, reinicia la mini PC."
