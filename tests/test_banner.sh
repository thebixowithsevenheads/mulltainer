# Arquivos de teste sao sourceados pelo runner; nao definem `set` por si mesmos.
#
# A arte do banner e' fragil de um jeito especifico: a primeira versao era a
# ANSI Shadow do figlet, que mistura o bloco cheio com ═║╔╗╚╝. As bordas finas
# de box-drawing sao o que mais varia de largura entre fontes monoespacadas, e
# em fonte pequena viram ruido -- foi exatamente o que embaralhou o GIF. Estes
# testes travam a arte em "so bloco cheio e espaco", com todas as linhas do
# mesmo comprimento e caber na largura que o fallback assume.

_arte_banner() {
  sed -n '/local -a arte=(/,/^  )$/p' "$RAIZ/lib/common.sh" \
    | grep -o "'[^']*'" | tr -d "'"
}

_n_linhas="$(_arte_banner | wc -l)"
afirmar_igual 6 "$_n_linhas" "banner: a arte tem 6 linhas"

# Se aparecer qualquer coisa fora de bloco cheio e espaco, a lista sai nao-vazia.
# `grep -o .` e nao `fold -w1`: o fold corta por BYTE, e o bloco cheio tem 3
# bytes em UTF-8 -- ele devolvia os bytes crus 342 226 210 e o teste acusava
# caracteres invalidos numa arte correta.
# O espaco e' uma linha COM um espaco, nao uma linha vazia -- tem que sair
# explicitamente, senao o proprio espaco e' acusado.
_fora="$(_arte_banner | grep -o . | sort -u | grep -vE '^(█| )?$' || true)"
afirmar_igual "" "$_fora" "banner: a arte usa so bloco cheio (U+2588) e espaco"

# Larguras em CARACTERES, nao em bytes: o bloco cheio ocupa 3 bytes em UTF-8,
# entao `wc -c` daria numeros que nao dizem nada sobre alinhamento na tela.
_larguras="$(_arte_banner | awk '{ print length($0) }' | sort -u | tr '\n' ' ')"
_n_larguras="$(_arte_banner | awk '{ print length($0) }' | sort -u | wc -l)"
afirmar_igual 1 "$_n_larguras" "banner: todas as linhas tem a mesma largura ($_larguras)"

# O banner largo so e' impresso acima de 82 colunas; a arte tem que caber la.
_larg="$(_arte_banner | head -1 | awk '{ print length($0) }')"
afirmar_igual sim "$([[ "$_larg" -le 82 ]] && echo sim || echo nao)" \
  "banner: a arte cabe no limite de 82 colunas (tem $_larg)"

# Uma cor por linha: o gradiente perde ou sobra linha se isso divergir.
_n_cores="$(sed -n '/local -a cor=(/,/^ *)$/p' "$RAIZ/lib/common.sh" \
  | grep -c '38;2;' || true)"
afirmar_igual "$_n_linhas" "$_n_cores" "banner: ha uma cor de gradiente por linha da arte"

# O fallback estreito precisa existir: terminal apertado nao pode cuspir arte
# quebrada, e a marca tem que aparecer de algum jeito.
afirmar_contem 'M U L L T A I N E R' "$(cat "$RAIZ/lib/common.sh")" \
  "banner: existe o fallback estreito com a marca"

# O banner tem que ser realmente chamado, senao nada disso aparece pro usuario.
afirmar_contem 'banner' "$(cat "$RAIZ/install.sh")" \
  "banner: o install.sh chama o banner"
