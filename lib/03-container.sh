#!/usr/bin/env bash
# lib/03-container.sh -- estagio 3: rede dedicada, container, payload, conf.
# Nao executa nada ao ser sourceado.
set -euo pipefail

# Identidade mostrada no prompt do container. Sao variaveis porque "demon7" e
# "sect" sao escolha de quem usa, nao caracteristica da ferramenta -- trocar
# aqui (ou exportar antes de rodar) muda o prompt inteiro.
PROMPT_USUARIO="${PROMPT_USUARIO:-demon7}"
PROMPT_HOST="${PROMPT_HOST:-sect}"

estagio_container() {
  [[ -n "${MULLVAD_CONF:-}" ]] || morrer "sem .conf -- rode o estagio 2 primeiro"
  [[ -f "$MULLVAD_CONF" ]] || morrer "conf nao encontrado: ${MULLVAD_CONF}"
  # || return $? em cada chamada que nao e' a ultima do corpo: sem isso, a
  # supressao de errexit dentro de um estagio (ver ATENCAO em install.sh:rodar())
  # deixaria uma falha de _rede_dedicada, por exemplo, ser ignorada e o estagio
  # seguiria para _recriar_container mesmo assim.
  _rede_dedicada     || return $?
  _recriar_container || return $?
  _fixar_ip          || return $?
  _instalar_payload  || return $?
  _conf_para_dentro  || return $?
  _alias_no_zshrc    || return $?
  _prompt_no_zshrc
}

_rede_dedicada() {
  if docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
    ok "rede ${NETWORK_NAME}: ja existe"
    return 0
  fi
  info "Criando a rede ${NETWORK_NAME} (${SUBNET})..."
  docker network create --driver bridge \
    --subnet "$SUBNET" --gateway "$GATEWAY" \
    --opt com.docker.network.bridge.enable_ip_masquerade=true \
    --ipv6=false "$NETWORK_NAME" \
    || { erro "nao consegui criar a rede ${NETWORK_NAME} -- a subnet ${SUBNET} colide com outra rede docker?"; return 1; }
  ok "rede criada"
}

_recriar_container() {
  if docker container inspect "$FULL_NAME" >/dev/null 2>&1; then
    aviso "${FULL_NAME} ja existe e vai ser RECRIADO."
    aviso "O /workspace e bind mount e sobrevive. O resto do filesystem dele, nao."
    confirmar "Recriar ${FULL_NAME}?" || return 3
    # docker rm -f, NAO `exegol remove`. Duas razoes, as duas lidas no fonte do
    # Exegol 5.1.11 instalado neste host:
    #
    #   1. ExegolContainer.remove() chama __removeVolume() a menos que
    #      container_only=True (que este call site nao passa), e o
    #      __removeVolume pergunta "Workspace <path> is not empty, do you want
    #      to delete it?". Ou seja: nossa promessa de que o /workspace sobrevive
    #      dependia da resposta do usuario a um prompt de OUTRA ferramenta, que
    #      nem mencionamos. Com docker rm -f o bind mount do host nao e' tocado
    #      e a promessa passa a ser literalmente verdadeira.
    #
    #   2. Esse prompt e' rich.prompt.Confirm, que levanta EOFError em EOF
    #      (verificado). Sob --yes sem TTY, a remocao falhava, o `|| true`
    #      engolia o erro, e o `exegol start` seguinte REUSAVA o container
    #      antigo -- o unico estagio documentado como destrutivo virava um
    #      no-op silencioso, e o usuario seguia com o container velho achando
    #      que tinha um novo.
    #
    # Parada graciosa de 2s antes do rm -f: e' o que o `exegol remove` fazia
    # (stop(timeout=2)) e um container de pentest pode ter trabalho em voo. O
    # rm -f depois nao depende dela ter dado certo -- ele mata e remove.
    docker stop -t 2 "$FULL_NAME" >/dev/null 2>&1 || true
    docker rm -f "$FULL_NAME" >/dev/null \
      || { erro "nao consegui remover o container ${FULL_NAME} -- rode: docker rm -f ${FULL_NAME}"; return 1; }
    # Conferir em vez de confiar: e' justamente a checagem que faltava.
    if docker container inspect "$FULL_NAME" >/dev/null 2>&1; then
      erro "o container ${FULL_NAME} continua existindo depois do docker rm -f"
      return 1
    fi
    ok "${FULL_NAME} removido (o /workspace, bind mount no host, ficou intacto)"
  fi

  # O --vpn com valor VAZIO e o ponto central desta arquitetura: ele ativa
  # NET_ADMIN, /dev/net/tun, net.ipv4.conf.all.src_valid_mark=1 e
  # net.ipv6.conf.all.disable_ipv6=0 SEM montar conf nenhum, deixando
  # /etc/wireguard gravavel dentro do container. Ver ContainerConfig.py:347
  # (if ParametersManager().vpn is not None) e :756-804 (enableVPN) do Exegol.
  info "Criando ${FULL_NAME} com capabilities de VPN..."
  aviso "O exegol start ABRE UM SHELL no container ao terminar. O instalador"
  aviso "nao quer isso, entao roda com a entrada fechada -- o shell recebe EOF"
  aviso "e sai sozinho. A linha 'cannot attach stdin to a TTY-enabled container'"
  aviso "que aparecer no fim e' esperada e nao indica falha."
  # < /dev/null e' o ponto: `exegol start` "create, start, resume AND ENTER"
  # (texto do proprio --help). Sem isso o instalador PARA aqui, dentro do
  # container, e so continua quando o usuario digita exit -- e se ele fechar a
  # janela em vez de sair, o estagio nunca chega a fixar o IP nem a instalar o
  # payload. Verificado que com a entrada fechada o container sai com NET_ADMIN,
  # src_valid_mark e /dev/net/tun exatamente iguais, e o comando devolve 0.
  exegol_cmd start "$CONTAINER_NAME" "$IMAGE_TAG" --vpn "" < /dev/null \
    || { erro "o exegol start falhou -- veja a saida acima"; return 1; }
  _conferir_capabilities
}

_conferir_capabilities() {
  local caps sysctls
  # return 1, nao morrer: esta checagem roda DEPOIS da mutacao (o container ja
  # foi criado por _recriar_container), entao morrer aqui mataria o instalador
  # inteiro sem o rodar() chegar a reportar o estagio nem a dica de retomada.
  # A mensagem amigavel continua existindo -- so troca o jeito de sair.
  caps="$(docker inspect "$FULL_NAME" --format '{{.HostConfig.CapAdd}}' 2>/dev/null)" \
    || { erro "nao consegui inspecionar ${FULL_NAME} -- ele subiu?"; return 1; }
  sysctls="$(docker inspect "$FULL_NAME" --format '{{.HostConfig.Sysctls}}' 2>/dev/null)" \
    || { erro "nao consegui inspecionar ${FULL_NAME} -- ele subiu?"; return 1; }
  [[ "$caps" == *NET_ADMIN* ]] || { erro \
    "container sem NET_ADMIN -- o 'exegol start --vpn \"\"' nao fez o esperado"; return 1; }
  [[ "$sysctls" == *src_valid_mark* ]] || { erro \
    "container sem net.ipv4.conf.all.src_valid_mark -- o wg-quick vai falhar"; return 1; }
  ok "capabilities conferidas: NET_ADMIN + src_valid_mark"
}

_fixar_ip() {
  info "Fixando ${STATIC_IP} em ${NETWORK_NAME}..."
  exegol_cmd stop "$CONTAINER_NAME" \
    || { erro "nao consegui parar ${FULL_NAME} para fixar o IP"; return 1; }
  local rede
  for rede in $(docker inspect "$FULL_NAME" \
      --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}'); do
    docker network disconnect "$rede" "$FULL_NAME" 2>/dev/null || true
  done
  docker network connect --ip "$STATIC_IP" "$NETWORK_NAME" "$FULL_NAME" \
    || { erro "nao consegui fixar ${STATIC_IP} -- o endereco ja esta em uso nessa rede?"; return 1; }
  # docker start, NAO exegol start: o exegol start entraria no container e
  # deixaria o instalador parado num shell no meio do estagio. Aqui o container
  # ja existe e ja esta configurado -- religar e' exatamente o que docker start
  # faz, sem abrir shell nenhum.
  docker start "$FULL_NAME" >/dev/null \
    || { erro "nao consegui religar ${FULL_NAME} depois de fixar o IP"; return 1; }
  ok "IP fixo: ${STATIC_IP}"
}

# /opt/my-resources dentro do container e bind mount de ~/.exegol/my-resources,
# entao o payload e instalado escrevendo no host. E o que elimina a pilha de
# 'docker exec ... tee' com heredoc aninhado da versao antiga.
_instalar_payload() {
  local dir_bin="${REAL_HOME}/.exegol/my-resources/bin"
  install -d -m 755 "$dir_bin" \
    || { erro "nao consegui criar ${dir_bin}"; return 1; }
  local arq
  for arq in killswitch-postup.sh mullvad-switch.py wgconf.py mullvad_api.py; do
    install -m 755 "${RAIZ_REPO}/payload/${arq}" "${dir_bin}/${arq}" \
      || { erro "nao consegui instalar ${arq} em ${dir_bin}"; return 1; }
  done
  ok "payload instalado em ${dir_bin}"
}

# A copia VIVA do conf e a de dentro do container. A do host e semente e backup.
_conf_para_dentro() {
  docker exec "$FULL_NAME" install -d -m 700 /etc/wireguard \
    || { erro "nao consegui criar /etc/wireguard dentro de ${FULL_NAME}"; return 1; }
  docker exec -i "$FULL_NAME" sh -c 'umask 077; cat > /etc/wireguard/wg0.conf' \
    < "$MULLVAD_CONF" \
    || { erro "nao consegui copiar o conf para dentro de ${FULL_NAME}"; return 1; }
  docker exec "$FULL_NAME" chmod 600 /etc/wireguard/wg0.conf \
    || { erro "nao consegui travar a permissao do wg0.conf dentro de ${FULL_NAME}"; return 1; }
  docker exec "$FULL_NAME" install -d -m 755 /workspace/.mullvad \
    || { erro "nao consegui criar /workspace/.mullvad dentro de ${FULL_NAME}"; return 1; }
  ok "conf instalado em /etc/wireguard/wg0.conf dentro do container"
}

# Sem env vars: o mullvad-switch le tudo do state.json. Idempotente.
_alias_no_zshrc() {
  # Os status do grep, medidos: 0 casou alguma linha, 1 NAO casou nada, 2 arquivo
  # ausente ou ilegivel. O caso NORMAL aqui e' o 1 (.zshrc sem o alias antigo,
  # vazio, ou contendo SO a linha do alias), e o guard original transformava esse
  # resultado normal em falha do estagio.
  #
  # Mas um `|| true` cru engole o 2 junto com o 1, e ai o .zshrc.novo fica vazio
  # e o mv passa por cima do .zshrc do Exegol, que nao e' pequeno -- perda de
  # dados, pior que a falha eager que estavamos consertando. Por isso:
  #
  #   - .zshrc inexistente: nada a limpar, sai 0 sem criar arquivo nenhum. O
  #     append logo abaixo cria o .zshrc com o alias, que e' o resultado certo.
  #   - status 0 ou 1: sucesso, o mv acontece.
  #   - qualquer outro status (leitura falhou): descarta o .zshrc.novo e propaga
  #     o status. O .zshrc ORIGINAL fica intacto, e o estagio falha com mensagem.
  docker exec "$FULL_NAME" sh -c \
    'if [ -e /root/.zshrc ]; then
       grep -v "^alias mullvad-switch=" /root/.zshrc > /root/.zshrc.novo
       s=$?
       if [ "$s" -le 1 ]; then
         mv /root/.zshrc.novo /root/.zshrc
       else
         rm -f /root/.zshrc.novo
         exit "$s"
       fi
     fi' \
    || { erro "nao consegui limpar o alias antigo em /root/.zshrc dentro de ${FULL_NAME}"; return 1; }
  docker exec "$FULL_NAME" sh -c \
    "printf \"alias mullvad-switch='python3 /opt/my-resources/bin/mullvad-switch.py'\n\" >> /root/.zshrc" \
    || { erro "nao consegui gravar o alias em /root/.zshrc dentro de ${FULL_NAME}"; return 1; }
  ok "alias mullvad-switch instalado"
}


# Prompt do container: demon7 em vermelho, sect em branco.
#
# Bloco delimitado em vez de append cru: o estagio e' idempotente e roda de
# novo em toda reinstalacao, entao precisa conseguir substituir a propria
# marcacao anterior sem duplicar nem comer o resto do .zshrc.
_prompt_no_zshrc() {
  docker exec "$FULL_NAME" sh -c \
    'if [ -e /root/.zshrc ]; then
       sed -i "/^# --- mulltainer prompt BEGIN ---$/,/^# --- mulltainer prompt END ---$/d" \
         /root/.zshrc
     fi' \
    || { erro "nao consegui limpar o prompt antigo em /root/.zshrc dentro de ${FULL_NAME}"; return 1; }

  # ATENCAO: o .zshrc do Exegol define uma funcao update_prompt e a registra
  # como hook precmd (verificado no container: `add-zsh-hook precmd
  # update_prompt`). Isso reconstroi o PROMPT ANTES DE CADA COMANDO, entao um
  # `PROMPT=` no fim do arquivo nao tem efeito nenhum -- o proximo precmd passa
  # por cima. Por isso o bloco desregistra o hook antes de definir o prompt.
  docker exec -i "$FULL_NAME" sh -c 'cat >> /root/.zshrc' <<EOF
# --- mulltainer prompt BEGIN ---
autoload -Uz add-zsh-hook 2>/dev/null
add-zsh-hook -d precmd update_prompt 2>/dev/null
PROMPT='%F{red}${PROMPT_USUARIO}%f@%F{white}${PROMPT_HOST}%f %~ \$ '
RPROMPT=''
# --- mulltainer prompt END ---
EOF
  local st=$?
  [[ $st -eq 0 ]] \
    || { erro "nao consegui gravar o prompt em /root/.zshrc dentro de ${FULL_NAME}"; return 1; }
  ok "prompt instalado: ${PROMPT_USUARIO}@${PROMPT_HOST}"
}
