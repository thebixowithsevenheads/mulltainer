# Arquivos de teste sao sourcados pelo runner; nao definem 'set' por si mesmo.
#
# Estagio 3 (container). O estagio inteiro precisa de docker e root, mas duas
# pecas dele nao: o snippet de shell do alias (extraido do proprio lib e rodado
# aqui contra um arquivo temporario) e a forma da remocao do container.

LIB3="$RAIZ/lib/03-container.sh"

# --- o snippet do alias: status 1 e' normal, status 2 NAO pode sobrescrever ---
#
# Status do `grep -v`, medidos: 0 casou alguma linha, 1 NAO casou nada, 2
# arquivo ausente ou ilegivel.
#
# O 1 e' o caso NORMAL aqui (.zshrc sem o alias antigo, vazio, ou contendo SO a
# linha do alias) e o guard original o transformava em falha do estagio -- o
# defeito eager. Mas um `|| true` cru engole o 2 junto com o 1: ai o
# .zshrc.novo fica vazio e o mv passa por cima do .zshrc do Exegol. Perda de
# dados, pior que a falha eager. Os dois lados sao cobertos aqui.
#
# O comando e' EXTRAIDO do lib, nao recopiado aqui: assim o teste acompanha o
# arquivo de verdade em vez de uma copia que pode divergir dele. As quebras de
# linha sao preservadas -- o snippet e' um bloco if/then/fi e colapsar tudo numa
# linha o quebraria.
# A extracao e' ancorada na linha `sh -c \` do _alias_no_zshrc, NAO no conteudo
# do snippet: ancorar no conteudo faria a extracao quebrar toda vez que o codigo
# sob teste mudasse, e um teste que quebra por nao achar o que testar nao esta
# discriminando nada -- esta so sumindo.
_bruto_zshrc="$(awk '
  /_alias_no_zshrc\(\)/ { na_funcao = 1 }
  na_funcao && /sh -c \\$/ && !pegou { pegando = 1; next }
  pegando { print; if (/'"'"' \\$/) { pegando = 0; pegou = 1 } }
' "$LIB3")"
_cmd_zshrc="$(printf '%s\n' "$_bruto_zshrc" \
  | sed -e "1s/^[[:space:]]*'//" -e "\$s/'[[:space:]]*\\\\\$//")"
afirmar_contem 'grep -v "^alias mullvad-switch="' "$_cmd_zshrc" \
  "alias: consegui extrair o snippet do lib (se falhar, o resto abaixo nao vale nada)"
afirmar_contem '-le 1' "$_cmd_zshrc" \
  "alias: o snippet distingue status <=1 (ok) de qualquer outro (erro de leitura)"

TMP3="$(mktemp -d)"
trap 'rm -rf "$TMP3"' RETURN
_cmd_zshrc="${_cmd_zshrc//\/root\/.zshrc/$TMP3/zshrc}"

_rodar_zshrc() { sh -c "$_cmd_zshrc" >/dev/null 2>&1; }

# Caso 1: .zshrc contendo SO a linha do alias -> grep sai 1 -> NAO e' falha.
printf 'alias mullvad-switch=antigo\n' > "$TMP3/zshrc"
_rodar_zshrc
afirmar_igual 0 "$?" "alias: .zshrc so com o alias antigo nao e' falha"
afirmar_igual 0 "$(wc -c < "$TMP3/zshrc")" "alias: o alias antigo saiu do arquivo"

# Caso 2: .zshrc vazio.
: > "$TMP3/zshrc"
_rodar_zshrc
afirmar_igual 0 "$?" "alias: .zshrc vazio nao e' falha"

# Caso 3: .zshrc inexistente (container recem-criado sem shell rodado ainda).
# Nada a limpar: sai 0 e nao cria arquivo nenhum -- o append do lib logo depois
# e' que cria o .zshrc com o alias.
rm -f "$TMP3/zshrc" "$TMP3/zshrc.novo"
_rodar_zshrc
afirmar_igual 0 "$?" "alias: .zshrc ausente nao e' falha"
afirmar_igual "nao" "$([[ -e "$TMP3/zshrc" ]] && echo sim || echo nao)" \
  "alias: .zshrc ausente nao e' criado vazio pelo snippet"
afirmar_igual "nao" "$([[ -e "$TMP3/zshrc.novo" ]] && echo sim || echo nao)" \
  "alias: .zshrc ausente nao deixa .zshrc.novo para tras"

# Caso 4: o caso que sempre funcionou -- linhas de sobra preservadas na ordem.
printf 'export A=1\nalias mullvad-switch=velho\nexport B=2\n' > "$TMP3/zshrc"
_rodar_zshrc
afirmar_igual 0 "$?" "alias: .zshrc com outras linhas nao e' falha"
afirmar_igual "$(printf 'export A=1\nexport B=2')" "$(cat "$TMP3/zshrc")" \
  "alias: so a linha do alias sai, o resto e a ordem ficam"

# Caso 5: .zshrc ILEGIVEL -> status 2. NAO pode sobrescrever nem engolir.
# Este e' o caso de perda de dados: um `|| true` cru mandaria um .zshrc.novo
# vazio por cima do .zshrc do Exegol, que nao e' pequeno.
#
# chmod 000 nao torna nada ilegivel para o root, entao a parte comportamental
# roda so como usuario comum -- que e' como esta suite e' feita para rodar (a
# testabilidade sem root e' o ponto do KS_DRY_RUN em todo este projeto). Como
# root, a assercao de forma acima (`-le 1` presente no snippet) e' o que resta.
printf 'CONTEUDO IMPORTANTE DO EXEGOL\nmais linhas\n' > "$TMP3/zshrc"
_bytes_antes="$(wc -c < "$TMP3/zshrc")"
if [[ $EUID -ne 0 ]]; then
  chmod 000 "$TMP3/zshrc"
  _rodar_zshrc
  _st_ilegivel=$?
  chmod 644 "$TMP3/zshrc"
  afirmar_igual 2 "$_st_ilegivel" \
    "alias: .zshrc ilegivel FALHA (status 2), nao e' engolido como se fosse normal"
  afirmar_igual "$_bytes_antes" "$(wc -c < "$TMP3/zshrc")" \
    "alias: .zshrc ilegivel fica INTACTO -- nada de mv de arquivo vazio por cima"
  afirmar_igual "nao" "$([[ -e "$TMP3/zshrc.novo" ]] && echo sim || echo nao)" \
    "alias: .zshrc ilegivel nao deixa .zshrc.novo para tras"
else
  afirmar_igual ok ok "alias: caso ilegivel pulado (rodando como root, chmod 000 nao vale)"
fi

# --- a remocao do container -------------------------------------------------
#
# `exegol remove` tambem apaga o volume de workspace (remove() chama
# __removeVolume() a menos que container_only, que este call site nao passava) e
# pergunta "Workspace ... is not empty, do you want to delete it?" -- nossa
# promessa de que o /workspace sobrevive dependia da resposta a um prompt de
# OUTRA ferramenta. E o rich.prompt.Confirm levanta EOFError em EOF: sob --yes
# sem TTY a remocao falhava, o `|| true` engolia, e o `exegol start` seguinte
# reusava o container antigo -- estagio destrutivo virando no-op silencioso.
_bloco_remove="$(awk '/^_recriar_container\(\)/,/^\}/' "$LIB3")"
afirmar_contem 'docker rm -f "$FULL_NAME"' "$_bloco_remove" \
  "remocao: usa docker rm -f, que nao toca no bind mount do /workspace"
afirmar_igual 0 "$(grep -c 'exegol_cmd remove' <<< "$_bloco_remove" || true)" \
  "remocao: nao usa mais 'exegol remove' (ele apaga o workspace e pergunta)"
afirmar_igual 0 "$(grep -c 'rm -f "\$FULL_NAME" 2>/dev/null || true' <<< "$_bloco_remove" || true)" \
  "remocao: a falha da remocao NAO e' engolida por || true"
# A mensagem, nao a linha do `if`: o `_recriar_container` JA abria com um
# `if docker container inspect ...` (a checagem de existencia), entao afirmar so
# a linha do if nao discriminaria nada.
afirmar_contem 'continua existindo depois do docker rm -f' "$_bloco_remove" \
  "remocao: confere que o container sumiu de fato antes de seguir"

# --- a desinstalacao tem a MESMA remocao, e nao pode "dar certo" em silencio --
#
# lib/06-uninstall.sh tinha a linha exata que o lib/03 acabou de perder:
# `exegol_cmd remove ... 2>/dev/null || true`. Aqui era pior: a chain e a unit da
# camada 2 sao removidas ANTES do container, entao sem TTY a remocao falhava, o
# `|| true` engolia, e o estagio imprimia "Desinstalado." com o container ainda
# de pe e sem kill switch nenhum.
LIB6="$RAIZ/lib/06-uninstall.sh"
_bloco_uninstall="$(awk '/^estagio_desinstalar\(\)/,/^\}/' "$LIB6")"

afirmar_contem 'docker rm -f "$FULL_NAME"' "$_bloco_uninstall" \
  "uninstall: usa docker rm -f, nao exegol remove"
afirmar_igual 0 "$(grep -c 'exegol_cmd remove' <<< "$_bloco_uninstall" || true)" \
  "uninstall: nao usa mais 'exegol remove' (apaga o workspace e pergunta)"
afirmar_igual 0 "$(grep -c 'rm -f "\$FULL_NAME" 2>/dev/null || true' <<< "$_bloco_uninstall" || true)" \
  "uninstall: a remocao do container NAO e' engolida por || true"
# A forma NEGADA (`&& ! docker container inspect`), nao a linha do `if`: o bloco
# JA abre com `if docker container inspect ...` (a checagem de existencia), entao
# afirmar so aquilo nao discriminaria nada -- o mesmo erro que eu ja tinha
# cometido no teste do lib/03 e corrigido la.
afirmar_contem '&& ! docker container inspect "$FULL_NAME" >/dev/null 2>&1; then' \
  "$_bloco_uninstall" "uninstall: confere que o container sumiu de fato"

# O "Desinstalado." nao pode ser inconditional -- era ele que mentia.
afirmar_contem 'Desinstalacao INCOMPLETA' "$_bloco_uninstall" \
  "uninstall: reporta desinstalacao incompleta em vez de sucesso silencioso"
_l_ok="$(grep -n 'ok "Desinstalado\."' <<< "$_bloco_uninstall" | cut -d: -f1)"
_l_if="$(grep -n 'if (( falhas )); then' <<< "$_bloco_uninstall" | cut -d: -f1)"
if [[ -n "$_l_ok" && -n "$_l_if" && "$_l_if" -lt "$_l_ok" ]]; then
  afirmar_igual ok ok "uninstall: o \"Desinstalado.\" esta atras do teste de falhas"
else
  afirmar_igual "if(${_l_if}) < ok(${_l_ok})" "falso" \
    "uninstall: o \"Desinstalado.\" esta atras do teste de falhas"
fi
# E o estagio precisa propagar o status, senao o rodar() reporta sucesso.
afirmar_contem '(( falhas == 0 ))' "$_bloco_uninstall" \
  "uninstall: o estagio devolve status nao-zero quando algo ficou para tras"
# O aviso do meio-estado (camada 2 ja removida) tem que estar la: e' a unica
# coisa que diz ao usuario que o container sobreviveu SEM protecao.
afirmar_contem 'SEM a camada 2' "$_bloco_uninstall" \
  "uninstall: avisa que o container que sobrou esta sem a camada 2"

# --- parada graciosa antes do rm -f, nos DOIS arquivos ------------------------
# `exegol remove` fazia stop(timeout=2) antes de remover; um container de
# pentest pode ter trabalho em voo.
for _arq in "$LIB3" "$LIB6"; do
  afirmar_contem 'docker stop -t 2 "$FULL_NAME"' "$(cat "$_arq")" \
    "parada graciosa de 2s antes do rm -f em $(basename "$_arq")"
done

unset LIB6 _bloco_uninstall _l_ok _l_if _arq
unset _cmd_zshrc _bruto_zshrc _bytes_antes _st_ilegivel _bloco_remove LIB3
unset -f _rodar_zshrc

# --- prompt do container -----------------------------------------------------
#
# O .zshrc do Exegol registra `add-zsh-hook precmd update_prompt`, que reconstroi
# o PROMPT ANTES DE CADA COMANDO. Medido no container: sem desregistrar o hook,
# o PROMPT vira o prompt com timestamp do Exegol no primeiro precmd, e o nosso
# some sem deixar rastro. Um `PROMPT=` no fim do .zshrc, sozinho, e' no-op.
#
# Por isso a linha do add-zsh-hook -d e' a peca load-bearing deste bloco, e nao
# um detalhe de limpeza -- e' o que estes testes protegem.
# O LIB3 do topo deste arquivo e' desfeito no `unset` de limpeza acima, entao
# aqui ele e' redefinido em vez de herdado.
LIB3="$RAIZ/lib/03-container.sh"
_bloco_prompt="$(sed -n '/_prompt_no_zshrc()/,/^}/p' "$LIB3")"

afirmar_contem 'add-zsh-hook -d precmd update_prompt' "$_bloco_prompt" \
  "prompt: desregistra o hook precmd do Exegol (sem isso o PROMPT e sobrescrito)"

afirmar_contem '%F{red}${PROMPT_USUARIO}%f' "$_bloco_prompt" \
  "prompt: o usuario sai em vermelho"

afirmar_contem '%F{white}${PROMPT_HOST}%f' "$_bloco_prompt" \
  "prompt: o host sai em branco"

# Idempotencia: o estagio roda de novo em toda reinstalacao. Sem a remocao do
# bloco anterior, cada rodada empilharia outro PROMPT no .zshrc.
afirmar_contem 'mulltainer prompt BEGIN' "$_bloco_prompt" \
  "prompt: o bloco e delimitado"
afirmar_contem 'mulltainer prompt END' "$_bloco_prompt" \
  "prompt: o bloco tem fim delimitado"
afirmar_contem 'sed -i "/^# --- mulltainer prompt BEGIN ---$/,/^# --- mulltainer prompt END ---$/d"' \
  "$_bloco_prompt" "prompt: remove o bloco anterior antes de gravar (idempotente)"

# A ancora do sed e' ancorada em linha inteira nos dois lados. Sem isso, um
# BEGIN sem END apagaria ate o fim do .zshrc do Exegol.
afirmar_contem 'BEGIN ---$/,/^#' "$_bloco_prompt" \
  "prompt: as ancoras do sed sao de linha inteira"

# A identidade e escolha de quem usa, nao caracteristica da ferramenta.
afirmar_contem 'PROMPT_USUARIO="${PROMPT_USUARIO:-demon7}"' "$(cat "$LIB3")" \
  "prompt: o usuario e configuravel, com demon7 de padrao"
afirmar_contem 'PROMPT_HOST="${PROMPT_HOST:-sect}"' "$(cat "$LIB3")" \
  "prompt: o host e configuravel, com sect de padrao"

# De nada adianta a funcao existir se o estagio nao a chama.
_corpo_estagio="$(sed -n '/^estagio_container()/,/^}/p' "$LIB3")"
afirmar_contem '_prompt_no_zshrc' "$_corpo_estagio" \
  "prompt: o estagio chama _prompt_no_zshrc"

# --- paleta do mullvad-switch ------------------------------------------------
#
# O azul da Mullvad (#294D73 = 41,77,115) so pode aparecer como FUNDO (48;2;).
# Como cor de TEXTO (38;2;) ele fica ilegivel sobre fundo escuro -- e' quase
# nenhum contraste. Este teste e' o que impede alguem de "simplificar" trocando
# o fundo por texto e entregando uma UI que nao da pra ler.
_MS="$RAIZ/payload/mullvad-switch.py"
afirmar_contem '48;2;41;77;115' "$(cat "$_MS")" \
  "switch: o azul da Mullvad entra como fundo"
afirmar_igual 0 "$(grep -c '38;2;41;77;115' "$_MS" || true)" \
  "switch: o azul escuro NUNCA e usado como cor de texto (ilegivel)"
afirmar_contem '38;2;255;213;36' "$(cat "$_MS")" \
  "switch: o amarelo da Mullvad e usado como texto"

# --- o instalador nao pode ENTRAR no container --------------------------------
#
# `exegol start` e "create, start, resume AND ENTER" (texto do proprio --help):
# ao terminar ele abre um shell dentro do container. Num instalador isso trava
# o estagio no meio -- ele so continua quando o usuario digita exit, e se a
# janela for fechada em vez disso, o IP nunca e fixado e o payload nunca e
# instalado. Verificado que com a entrada fechada o container sai com NET_ADMIN,
# src_valid_mark e /dev/net/tun iguais, e o comando devolve 0.
LIB3="$RAIZ/lib/03-container.sh"
_todo_lib3="$(cat "$LIB3")"

afirmar_contem 'exegol_cmd start "$CONTAINER_NAME" "$IMAGE_TAG" --vpn "" < /dev/null' \
  "$_todo_lib3" "shell: a criacao roda com a entrada fechada (senao o instalador para dentro do container)"

# Nenhum `exegol_cmd start` pode escapar da regra. Conta as ocorrencias sem
# `< /dev/null` na mesma linha -- se alguem adicionar outra chamada, isto acusa.
# grep -c imprime a contagem e sai 1 quando ela e' zero; o || true so evita que
# o errexit do runner mate aqui -- a contagem impressa continua sendo capturada.
_start_solto="$(grep 'exegol_cmd start' "$LIB3" | grep -vc '< /dev/null' || true)"
afirmar_igual 0 "$_start_solto" \
  "shell: nenhum exegol_cmd start sem a entrada fechada"

# Religar depois de trocar a rede usa docker start: o container ja existe e ja
# esta configurado, e o exegol start abriria shell de novo no meio do estagio.
_bloco_fixar="$(sed -n '/^_fixar_ip()/,/^}/p' "$LIB3")"
afirmar_contem 'docker start "$FULL_NAME"' "$_bloco_fixar" \
  "shell: o religamento usa docker start, que nao abre shell"
afirmar_igual 0 "$(grep -c 'exegol_cmd start' <<< "$_bloco_fixar" || true)" \
  "shell: o religamento NAO usa exegol start"

unset _bloco_prompt _corpo_estagio _MS _todo_lib3 _bloco_fixar _start_solto LIB3
