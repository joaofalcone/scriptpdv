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

    # Extrai o número do item no padrão 'nItem: X'
    ITEM_ERRO=$(echo "$REJEICAO" | grep -o 'nItem: [0-9]\+' | awk '{print $2}')

    # Busca o ID interno do cupom usando o número do cupom de contingência
    ID=$(sqlite3 "$DB" "SELECT id FROM cupom WHERE numero = '$NUM' LIMIT 1;")

    # Se não encontrar o cupom, mostra apenas a rejeição
    if [ -z "$ID" ]; then
        echo "Cupom não encontrado na tabela cupom."
        echo
        continue
    fi

    # Se não houver item específico na rejeição
    if [ -z "$ITEM_ERRO" ]; then
        echo "Nenhum item específico informado na rejeição."
        echo
        continue
    fi

    # Lista os itens do cupom e destaca em amarelo o item com erro
    sqlite3 -separator '|' "$DB" "
    SELECT
        sequencia,
        codigo_plu_barras,
        descricao
    FROM cupom_item
    WHERE id_cupom = $ID
    ORDER BY sequencia;
    " | while IFS='|' read -r ITEM PLU DESCRICAO
    do
        if [ "$ITEM" = "$ITEM_ERRO" ]; then
            # Fundo amarelo + texto preto + negrito
            printf '\033[1;30;43m>>> ITEM %-4s PLU: %-15s %s <<< ITEM COM ERRO\033[0m\n' \
                "$ITEM" "$PLU" "$DESCRICAO"
        else
            printf '    ITEM %-4s PLU: %-15s %s\n' \
                "$ITEM" "$PLU" "$DESCRICAO"
        fi
    done

    echo
done
EOF

sudo chmod +x /usr/local/bin/rejeicao

echo "Instalado com sucesso."
echo "Use o comando: rejeicao"
