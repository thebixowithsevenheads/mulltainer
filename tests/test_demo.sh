# Arquivos de teste sao sourceados pelo runner; nao definem `set` por si mesmos.
#
# O demo/mockup.sh encena uma sessao para gerar o GIF do README. Se um estagio
# mudar o texto de uma mensagem e o mockup nao acompanhar, o GIF passa a mostrar
# uma ferramenta que nao existe mais -- e ninguem percebe, porque o GIF nao roda
# em CI. Estes testes sao o alarme: cada string que o mockup afirma tem que
# existir no estagio de onde ela veio.
#
# Nao afirmam que o mockup esta COMPLETO (nada garante isso automaticamente),
# so que ele nao esta desatualizado nas mensagens que usa.

MOCKUP="$RAIZ/demo/mockup.sh"

afirmar_igual "sim" "$([[ -f "$MOCKUP" ]] && echo sim || echo nao)" \
  "demo: o mockup.sh existe"

# O mockup precisa sourcear o common.sh de verdade -- e o que garante que banner,
# cores e formato de info/ok/aviso venham das funcoes reais, nao de imitacao.
afirmar_contem 'source "${RAIZ}/lib/common.sh"' "$(cat "$MOCKUP")" \
  "demo: o mockup sourceia o lib/common.sh real"

# Cada par: a string que o mockup mostra, e o arquivo que deveria produzi-la.
# A comparacao ignora as partes interpoladas, olhando so o trecho literal.
_demo_par() {
  local trecho="$1" arquivo="$2" desc="$3"
  local no_mockup no_codigo
  no_mockup="$(grep -cF "$trecho" "$MOCKUP" || true)"
  no_codigo="$(grep -cF "$trecho" "$RAIZ/$arquivo" || true)"
  if [[ "$no_mockup" -gt 0 && "$no_codigo" -gt 0 ]]; then
    afirmar_igual ok ok "$desc"
  else
    afirmar_igual "mockup=$no_mockup codigo=$no_codigo (esperava ambos > 0)" \
      "divergiu" "$desc"
  fi
}

_demo_par 'Distro detectada: '            'lib/01-deps.sh'     'demo: "Distro detectada" bate com o estagio 1'
_demo_par 'Vou rodar: '                   'lib/01-deps.sh'     'demo: "Vou rodar" bate com o estagio 1'
_demo_par 'gratuita, sem assinatura'      'lib/01-deps.sh'     'demo: texto da imagem free bate com o estagio 1'
_demo_par 'A Mullvad permite 5 por conta' 'lib/02-mullvad.sh'  'demo: aviso dos 5 slots bate com o estagio 2'
_demo_par 'Conta valida. Expira em: '     'lib/02-mullvad.sh'  'demo: validade da conta bate com o estagio 2'
_demo_par 'Chave registrada. Endereco atribuido: ' 'lib/02-mullvad.sh' 'demo: chave registrada bate com o estagio 2'
_demo_par 'Conf gerado: '                 'lib/02-mullvad.sh'  'demo: conf gerado bate com o estagio 2'
_demo_par 'com capabilities de VPN'       'lib/03-container.sh' 'demo: criacao do container bate com o estagio 3'
_demo_par 'capabilities conferidas: NET_ADMIN + src_valid_mark' 'lib/03-container.sh' 'demo: capabilities conferidas bate com o estagio 3'
_demo_par 'alias mullvad-switch instalado' 'lib/03-container.sh' 'demo: alias bate com o estagio 3'
_demo_par 'scripts do host instalados em /usr/local/sbin' 'lib/04-killswitch.sh' 'demo: scripts do host bate com o estagio 4'
_demo_par 'ativo e habilitado no boot'    'lib/04-killswitch.sh' 'demo: unit ativa bate com o estagio 4'
_demo_par 'Subindo o tunel pela primeira vez' 'install.sh'     'demo: primeira subida bate com o install.sh'

# Os itens da verificacao, que sao o coracao do demo: se um PASSA mudar de
# texto, o GIF mostra um item que o estagio nao imprime mais.
_demo_par 'handshake do wg0 estabelecido' 'lib/05-verify.sh' 'demo: item handshake bate com o estagio 5'
_demo_par 'resolv.conf aponta para o DNS da Mullvad (10.64.0.1)' 'lib/05-verify.sh' 'demo: item DNS bate com o estagio 5'
_demo_par 'IPv6 bloqueado'                'lib/05-verify.sh'   'demo: item IPv6 bate com o estagio 5'
_demo_par 'watcher da camada 2 ativo'     'lib/05-verify.sh'   'demo: item watcher bate com o estagio 5'
_demo_par 'camada 1: sem tunel, nada sai do container' 'lib/05-verify.sh' 'demo: item camada 1 bate com o estagio 5'
_demo_par 'camada 2: descartou o trafego com a camada 1 desativada' 'lib/05-verify.sh' 'demo: item camada 2 bate com o estagio 5'
_demo_par 'tunel restaurado e saindo pela Mullvad' 'lib/05-verify.sh' 'demo: item restauracao bate com o estagio 5'
_demo_par 'Tudo passou. O kill switch esta protegendo nas duas camadas.' 'lib/05-verify.sh' 'demo: veredito final bate com o estagio 5'
_demo_par 'Teste de vazamento -- derrubando o tunel de proposito' 'lib/05-verify.sh' 'demo: cabecalho do teste de vazamento bate com o estagio 5'

# O menu, que e a primeira coisa que o GIF mostra.
_demo_par '1) Instalacao completa'        'install.sh'         'demo: opcao 1 do menu bate com o install.sh'
_demo_par '6) Verificar / testar vazamento' 'install.sh'       'demo: opcao 6 do menu bate com o install.sh'
_demo_par 'Use: exegol start '            'install.sh'         'demo: mensagem final bate com o install.sh'

# E o mullvad-switch, cuja UI vive no payload.
_demo_par 'M U L L V A D   S W I T C H'   'payload/mullvad-switch.py' 'demo: banner do switch bate com o payload'
_demo_par 'Multihop completo'             'payload/mullvad-switch.py' 'demo: modo multihop bate com o payload'
_demo_par 'Single-hop'                    'payload/mullvad-switch.py' 'demo: modo single-hop bate com o payload'
_demo_par 'confirmando a saida'         'payload/mullvad-switch.py' 'demo: espera de conexao bate com o payload'
_demo_par 'Saindo pela Mullvad'           'payload/mullvad-switch.py' 'demo: linha de saida bate com o payload'

# O mockup nao pode tocar nada: sem docker, systemctl, iptables, wg-quick.
# Olha POSICAO DE COMANDO (inicio de linha, eventualmente com sudo), nao a
# palavra em qualquer lugar: o mockup IMPRIME textos que contem "docker",
# "iptables" e "exegol" -- e o ponto dele e' justamente parecer com a saida real.
# A primeira versao deste teste falhava nesses printf, acusando o mockup de algo
# que ele nao faz.
_demo_sem_efeito() {
  local cmd="$1"
  local achou
  achou="$(grep -cE "^[[:space:]]*(sudo[[:space:]]+)?${cmd}([[:space:]]|\$)" "$MOCKUP" || true)"
  afirmar_igual 0 "$achou" "demo: o mockup nao invoca ${cmd}"
}
_demo_sem_efeito 'docker'
_demo_sem_efeito 'systemctl'
_demo_sem_efeito 'iptables'
_demo_sem_efeito 'wg-quick'
_demo_sem_efeito 'exegol'

# --- nada versionado pode carregar a identidade da maquina -------------------
#
# Um `git add -A` ja varreu para dentro do repo uma gravacao crua da raiz, com
# machineid, bootid e o prompt do usuario. O arquivo foi apagado do historico
# antes de ir para o remoto, mas o erro so foi visto porque alguem leu -- estes
# testes sao para ele nao voltar em silencio.
#
# Nao ha como testar "o nome do dono deste repo": ele varia. O que da para
# travar e' o que o mockup mostra, que e' o que vai parar no GIF do README.
_homes_estranhos="$(grep -oE '/home/[A-Za-z0-9_.-]+' "$MOCKUP" | grep -v '^/home/demon7$' | sort -u | tr '\n' ' ' || true)"
afirmar_igual "" "$_homes_estranhos" \
  "demo: todo /home/ do mockup e /home/demon7 (nunca o usuario real)"

# Identificadores de maquina nao podem existir em NENHUM arquivo versionado.
# O padrao e montado por concatenacao para o proprio teste nao casar consigo
# mesmo -- na primeira versao ele acusava este arquivo e nada mais.
_p1='machine''id='
_p2='boot''id='
_ids="$(git -C "$RAIZ" grep -lE "${_p1}|${_p2}" -- . 2>/dev/null | tr '\n' ' ' || true)"
afirmar_igual "" "$_ids" \
  "demo: nenhum arquivo versionado carrega machineid/bootid"

# Gravacao crua na raiz e o caminho pelo qual isso entrou. Fica ignorada.
afirmar_contem '/*.cast' "$(cat "$RAIZ/.gitignore")" \
  "demo: .cast na raiz e git-ignored (foi por ali que a gravacao crua entrou)"
unset _ids _p1 _p2 _homes_estranhos
