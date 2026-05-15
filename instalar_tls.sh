#!/bin/bash

set -e

echo "Atualizando repositórios e instalando dependências..."
sudo apt update && sudo apt install -y mysql-client sqlite3 zenity

URL_SCRIPT="https://raw.githubusercontent.com/joaofalcone/scriptpdv/main/tls.sh"
TMP_SCRIPT="/tmp/tls.sh"

echo "Baixando tls.sh..."
wget -qO "$TMP_SCRIPT" "$URL_SCRIPT"

chmod 777 "$TMP_SCRIPT"

echo "Executando tls.sh..."
bash "$TMP_SCRIPT"
