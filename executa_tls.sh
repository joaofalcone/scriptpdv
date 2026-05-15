#!/bin/bash

set -e

echo "Instalando dependências..."
sudo apt update && sudo apt install -y mysql-client sqlite3 zenity

URL_SCRIPT="https://raw.githubusercontent.com/joaofalcone/scriptpdv/main/InstalaTLS.sh"
TMP_SCRIPT="/tmp/InstalaTLS.sh"

echo "Baixando script para /tmp..."
wget -qO "$TMP_SCRIPT" "$URL_SCRIPT"

chmod +x "$TMP_SCRIPT"

echo "Executando script..."
bash "$TMP_SCRIPT"
