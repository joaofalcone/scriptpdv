#!/bin/bash

set -e

if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "sqlite3 não encontrado. Instalando..."
    sudo apt update
    sudo apt install -y sqlite3
fi

sudo tee /usr/local/bin/rejeicao > /dev/null <<'EOF'
#!/bin/bash

DB="${1:-/opt/checkout/pdv_out.db}"

LARANJA='\033[1;38;5;208m'
AZUL='\033[1;34m'
RESET='\033[0m'

if [ ! -f "$DB" ]; then
    echo "Banco não encontrado: $DB"
    exit 1
fi

for TABELA in recibo_rejeicao_nfce cupom cupom_item; do
    EXISTE=$(sqlite3 "$DB" "SELECT name FROM sqlite_master WHERE type='table' AND name='$TABELA';")
    if [ -z "$EXISTE" ]; then
        echo "Tabela não encontrada: $TABELA"
        exit 1
    fi
done

TOTAL=$(sqlite3 "$DB" "SELECT COUNT(*) FROM recibo_rejeicao_nfce;")

if [ "$TOTAL" -eq 0 ]; then
    echo "Nenhuma rejeição encontrada."
    exit 0
fi

sqlite3 -separator '|' "$DB" "
SELECT id, cupom_contingencia, descricao_rejeicao
FROM recibo_rejeicao_nfce
ORDER BY id DESC;
" | while IFS='|' read -r ID_REJEICAO NUM REJEICAO
do
    echo "=============================================================="

    printf "${LARANJA}CUPOM: %s${RESET}\n" "$NUM"
    printf "${LARANJA}REJEIÇÃO:${RESET} %s\n" "$REJEICAO"
    echo

    if ! echo "$NUM" | grep -Eq '^[0-9]+$'; then
        echo "Cupom inválido na tabela de rejeição: $NUM"
        echo
        continue
    fi

    ITEM_ERRO=$(echo "$REJEICAO" | sed -n 's/.*nItem:[[:space:]]*\([0-9]\+\).*/\1/p')

    ID_CUPOM=$(sqlite3 "$DB" "
        SELECT id
        FROM cupom
        WHERE numero = '$NUM'
        LIMIT 1;
    ")

    if [ -z "$ID_CUPOM" ]; then
        echo "Cupom não encontrado na tabela cupom."
        echo
        continue
    fi

    if [ -z "$ITEM_ERRO" ]; then
        echo "Nenhum item específico informado na rejeição."
        echo
        continue
    fi

    NCM_ERRO=$(sqlite3 "$DB" "
        SELECT IFNULL(ncm, '')
        FROM cupom_item
        WHERE id_cupom = $ID_CUPOM
          AND sequencia = $ITEM_ERRO
        LIMIT 1;
    ")

    ITENS=$(sqlite3 -separator '|' "$DB" "
        SELECT
            sequencia,
            IFNULL(codigo_plu_barras, ''),
            IFNULL(ncm, ''),
            IFNULL(descricao, '[SEM DESCRIÇÃO]')
        FROM cupom_item
        WHERE id_cupom = $ID_CUPOM
        ORDER BY sequencia;
    ")

    if [ -z "$ITENS" ]; then
        echo "Nenhum item encontrado para este cupom."
        echo
        continue
    fi

    echo "$ITENS" | while IFS='|' read -r ITEM PLU NCM DESCRICAO
    do
        if [ "$ITEM" = "$ITEM_ERRO" ]; then
            printf "${LARANJA}>>> ITEM %-4s PLU: %-15s NCM: %-10s %s <<< ITEM COM ERRO${RESET}\n" \
                "$ITEM" "$PLU" "$NCM" "$DESCRICAO"

        elif [ -n "$NCM_ERRO" ] && [ "$NCM" = "$NCM_ERRO" ]; then
            printf "${AZUL}    ITEM %-4s PLU: %-15s NCM: %-10s %s <<< MESMO NCM DO ITEM COM ERRO${RESET}\n" \
                "$ITEM" "$PLU" "$NCM" "$DESCRICAO"

        else
            printf "    ITEM %-4s PLU: %-15s NCM: %-10s %s\n" \
                "$ITEM" "$PLU" "$NCM" "$DESCRICAO"
        fi
    done

    echo
done
EOF

sudo chmod +x /usr/local/bin/rejeicao

echo "Instalado com sucesso."
echo "Use o comando: rejeicao"
