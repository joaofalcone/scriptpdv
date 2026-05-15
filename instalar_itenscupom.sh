#!/bin/bash

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

    # Busca o ID interno do cupom
    ID=$(sqlite3 "$DB" "SELECT id FROM cupom WHERE numero = '$NUM' LIMIT 1;")

    # Se não encontrar o cupom, mostra apenas a rejeição
    if [ -z "$ID" ]; then
        echo "Cupom não encontrado na tabela cupom."
        echo
        continue
    fi

    # Se não houver item específico na mensagem
    if [ -z "$ITEM_ERRO" ]; then
        echo "Nenhum item específico informado na rejeição."
        echo
        continue
    fi

    # Lista os itens do cupom e destaca o item com erro
    sqlite3 -separator '|' "$DB" "
    SELECT
        ci.sequencia,
        IFNULL(p.descricao, '[SEM DESCRIÇÃO]'),
        ci.codigo_interno
    FROM cupom_item ci
    LEFT JOIN produto p
        ON p.codigo_interno = ci.codigo_interno
    WHERE ci.id_cupom = $ID
    ORDER BY ci.sequencia;
    " | while IFS='|' read -r ITEM DESC CODIGO
    do
        if [ "$ITEM" = "$ITEM_ERRO" ]; then
            printf ">>> %-4s %-50s %s  <<< ITEM COM ERRO\n" "$ITEM" "$DESC" "$CODIGO"
        else
            printf "    %-4s %-50s %s\n" "$ITEM" "$DESC" "$CODIGO"
        fi
    done

    echo
done
EOF

sudo chmod +x /usr/local/bin/rejeicao

echo "Instalado com sucesso."
echo "Use o comando: rejeicao"
