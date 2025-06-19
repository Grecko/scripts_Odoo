#!/bin/bash

LOG_FILE="/home/tpvuser/chrome_kiosk_monitor.log"
CHROME_COMMAND="/usr/bin/google-chrome-stable --kiosk --incognito --disable-infobars --noerrdialogs --check-for-update-at-startup=0 --start-maximized 'http://localhost:8069'"
ODOO_URL="http://localhost:8069"

# Exportar variables de entorno necesarias para que Chrome sepa dónde dibujar
# DISPLAY es el monitor virtual donde se mostrará la ventana
# XAUTHORITY es la clave de autenticación para el servidor X
# Asegúrate que estas rutas sean correctas para tu configuración.
# En un autologin, /home/tpvuser/.Xauthority suele ser la correcta.
export XAUTHORITY="/home/tpvuser/.Xauthority"
export DISPLAY=":0"

# Verificar si Chrome ya está corriendo para el usuario tpvuser
if pgrep -u tpvuser -f google-chrome-stable > /dev/null; then
    echo "$(date): Chrome already running for tpvuser. Exiting check." >> "$LOG_FILE"
    exit 0
fi

echo "$(date): Chrome is not running. Checking Odoo URL." >> "$LOG_FILE"

# Validar que la URL de Odoo sea accesible
# curl -s: silencioso, --head: solo cabeceras, --request GET: método GET
if curl -s --head --request GET "$ODOO_URL" | grep "200 OK" > /dev/null; then
    echo "$(date): Odoo URL ($ODOO_URL) is reachable. Launching Chrome." >> "$LOG_FILE"
    # Lanzar Chrome en segundo plano, completamente separado del script padre
    # setsid: inicia el comando en una nueva sesión de proceso, lo desvincula de la terminal
    # nohup: hace que el comando no muera si la terminal de control se cierra (aunque aquí es un servicio)
    # >> /dev/null 2>&1: redirige la salida y errores de Chrome a /dev/null para no saturar el log principal
    setsid nohup bash -c "$CHROME_COMMAND" >> /dev/null 2>&1 &
    echo "$(date): Chrome launch command issued." >> "$LOG_FILE"
else
    echo "$(date): Odoo URL ($ODOO_URL) is NOT reachable. Retrying later." >> "$LOG_FILE"
fi

exit 0
