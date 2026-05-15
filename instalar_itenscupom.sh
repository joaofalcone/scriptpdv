sudo tee /usr/local/bin/rejeicao > /dev/null <<'EOF'
#!/bin/bash

DB="/opt/checkout/pdv_out.db"

if [ ! -f "$DB" ]; then
    echo "Banco não encontrado: $DB"
    exit 1
fi

sqlite3 -separator '|' "$DB" "
SELECT cupom_contingencia, descricao_rejeicao
FROM recibo_rejeicao_nfce
ORDER BY id DESC;
" | while IFS='|' read -r NUM REJEICAO
do
    echo "=============================================================="
    echo "CUPOM: $NUM"
    echo "REJEIÇÃO: $REJEICAO"
    echo

    ITEM_ERRO=$(echo "$REJEICAO" | grep -o 'nItem: [0-9]\+' | awk '{print $2}')

    ID=$(sqlite3 "$DB" "SELECT id FROM cupom WHERE numero = '$NUM' LIMIT 1;")

    if [ -z "$ID" ]; then
        echo "Cupom não encontrado na tabela cupom."
        echo
        continue
    fi

    if [ -z "$ITEM_ERRO" ]; then
        echo "Nenhum item específico informado na rejeição."
        echo
        continue
    fi

    sqlite3 -separator '|' "$DB" "
    SELECT
        sequencia,
        codigo_interno,
        codigo_plu_barras,
        codigo_plu_barras_lido
    FROM cupom_item
    WHERE id_cupom = $ID
    ORDER BY sequencia;
    " | while IFS='|' read -r ITEM CODIGO PLU PLU_LIDO
    do
        if [ "$ITEM" = "$ITEM_ERRO" ]; then
            printf ">>> ITEM %-4s CODIGO: %-10s PLU: %-15s PLU_LIDO: %-20s <<< ITEM COM ERRO\n" "$ITEM" "$CODIGO" "$PLU" "$PLU_LIDO"
        else
            printf "    ITEM %-4s CODIGO: %-10s PLU: %-15s PLU_LIDO: %-20s\n" "$ITEM" "$CODIGO" "$PLU" "$PLU_LIDO"
        fi
    done

    echo
done
EOF

sudo chmod +x /usr/local/bin/rejeicao
