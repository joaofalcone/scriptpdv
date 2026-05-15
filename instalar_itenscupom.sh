#!/bin/bash

sudo tee /usr/local/bin/itenscupom > /dev/null <<'EOF'
#!/bin/bash

DB="/opt/checkout/pdv_out.db"

if [ ! -f "$DB" ]; then
    echo "Banco não encontrado: $DB"
    exit 1
fi

read -p "Número do cupom: " NUM

ID=$(sqlite3 "$DB" "SELECT id FROM cupom WHERE numero = '$NUM' LIMIT 1;")

if [ -z "$ID" ]; then
    echo "Cupom não encontrado."
    exit 1
fi

echo "ID do cupom: $ID"
echo

sqlite3 -header -column "$DB" "
SELECT
    ci.sequencia AS item,
    p.descricao AS descricao,
    ci.codigo_interno AS codigo
FROM cupom_item ci
LEFT JOIN produto p
    ON p.codigo_interno = ci.codigo_interno
WHERE ci.id_cupom = $ID
ORDER BY ci.sequencia;
"
EOF

sudo chmod +x /usr/local/bin/itenscupom

echo "Instalado com sucesso."
echo "Use o comando: itenscupom"
