#!/usr/bin/env bash
# demo/mockup.sh -- encena uma sessao completa do Mulltainer para gravacao.
#
# NAO instala nada, nao toca em container, rede, iptables nem systemd. Sao
# printf e sleep. Existe para gerar o GIF do README sem precisar de uma maquina
# limpa e de uma conta Mullvad real a cada regravacao.
#
# Fidelidade: este script SOURCEIA o lib/common.sh de verdade, entao o banner,
# as cores e o formato de info/ok/aviso/erro vem das funcoes reais do
# instalador, nao de imitacao. As mensagens foram copiadas dos estagios
# (lib/01..05) -- se um estagio mudar o texto, este mockup fica desatualizado e
# o teste demo/test_mockup.sh acusa.
#
# Os DADOS sao ficticios: numero de conta, chaves, IPs de saida e contadores.
# Os hostnames de relay sao reais porque a lista da Mullvad e publica.
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${RAIZ}/lib/common.sh"

# Ritmo. DEMO_RAPIDO=1 zera as pausas (usado pelo teste).
p() { [[ "${DEMO_RAPIDO:-0}" == "1" ]] || sleep "$1"; }

# O verify usa um formato proprio; reproduzido aqui igual ao lib/05-verify.sh.
_passa() { printf '  %s[PASSA]%s %s\n' "$VERDE" "$RESET" "$1"; p 0.35; }

# Prompt encenado: mostra a pergunta e a resposta como se digitada.
responde() { printf '%s[?]%s %s %s%s%s\n' "$AMARELO" "$RESET" "$1" "$NEGRITO" "$2" "$RESET"; p 0.5; }

linha() { printf '    %-18s %s\n' "$1" "$2"; }

# Faixa de titulo do mullvad-switch: amarelo em negrito sobre o azul da marca,
# igual ao cabecalho() do payload. O azul entra como FUNDO -- como texto ele nao
# contrasta com terminal escuro.
faixa() { printf '\n%s%s%s%s%s\n\n' "$AZUL_FUNDO" "$AMARELO$NEGRITO" \
  "$(printf ' %-77s' "$1")" "$RESET" ""; }

# Centraliza em 78 colunas, para as faixas do banner do switch.
centrar() {
  local t="$1" larg=78 pad
  pad=$(( (larg - ${#t}) / 2 ))
  printf '%*s%s%*s' "$pad" '' "$t" "$(( larg - pad - ${#t} ))" ''
}

# Item de menu do switch: numero em amarelo.
item() { printf '  %s%3d)%s %s\n' "$AMARELO" "$1" "$RESET" "$2"; }

# Rotulo pontilhado do status: rotulo em azul claro, valor na cor padrao.
rotulo() { printf '  %s%s%s %s\n' "$CINZA" "$1" "$RESET" "$2"; }

# ---------------------------------------------------------------------------
# 1) Abertura: banner e painel de estado num host que nao tem nada
# ---------------------------------------------------------------------------
clear 2>/dev/null || true
printf '%s$%s sudo bash install.sh\n' "$CINZA" "$RESET"; p 0.8

tput() { echo 100; }   # forca o banner largo na gravacao
banner
unset -f tput

linha "Distro"        "arch"
linha "Docker"        "ok, ativo"
linha "Exegol"        "v5.1.11"
linha "Imagem"        "free nao instalada"
linha "Config Mullvad" "nenhuma encontrada"
linha "Container"     "nao existe"
linha "Kill switch"   "inativo"
linha "Watcher"       "inativo"
printf '\n'
p 1.0

printf '    1) Instalacao completa   <- faz tudo, do zero\n'
printf '    2) So dependencias\n'
printf '    3) So config Mullvad\n'
printf '    4) So o container\n'
printf '    5) So o kill switch\n'
printf '    6) Verificar / testar vazamento\n'
printf '    7) Desinstalar\n'
printf '    0) Sair\n\n'
p 1.2
responde "escolha>" "1"

# ---------------------------------------------------------------------------
# 2) Estagio 1: dependencias
# ---------------------------------------------------------------------------
printf '\n%s>>> Dependencias%s\n' "$NEGRITO" "$RESET"; p 0.4
info "Distro detectada: arch"; p 0.4
ok "docker: presente"
ok "pipx: presente"
aviso "wg: ausente -> pacote wireguard-tools"
ok "iptables: presente"
ok "curl: presente"
ok "python3: presente"
p 0.5
info "Vou rodar: pacman -S --needed --noconfirm wireguard-tools"
responde "Instalar os pacotes que faltam? [S/n]" "s"
p 0.8
ok "docker.service ativo"
ok "exegol: v5.1.11"
p 0.6

printf '\n%sImagens do Exegol%s\n\n' "$NEGRITO" "$RESET"
printf '  %sfree%s   gratuita, sem assinatura -- e o padrao aqui\n' "$AMARELO" "$RESET"
printf '  as demais aparecem marcadas "Pro / Enterprise only" na tabela abaixo\n\n'
printf '  ┌─────────┬──────────┬───────────────────────┐\n'
printf '  │ Image   │ Size     │ Status                │\n'
printf '  ├─────────┼──────────┼───────────────────────┤\n'
printf '  │ free    │ ~42 GB   │ Not installed         │\n'
printf '  │ full    │ 45.09 GB │ Pro / Enterprise only │\n'
printf '  └─────────┴──────────┴───────────────────────┘\n\n'
p 1.0
printf '  Espaco livre em /var/lib/docker: 214 GB\n'
responde "Baixar agora? [S/n]" "s"
p 0.8
printf '  %s[i]%s baixando nwodtuhs/exegol:free ... (alguns minutos)%s\n' "$CINZA" "$RESET" "$RESET"
p 1.2
ok "imagem free instalada"
p 0.6

# ---------------------------------------------------------------------------
# 3) Estagio 2: config da Mullvad
# ---------------------------------------------------------------------------
printf '\n%s>>> Config Mullvad%s\n' "$NEGRITO" "$RESET"; p 0.4
printf '\n%sConfig da Mullvad%s\n\n' "$NEGRITO" "$RESET"
printf '  1) Ja tenho um .conf\n'
printf '  2) Gerar pelo numero da conta\n'
printf '  0) Voltar\n\n'
p 0.9
responde "escolha>" "2"
p 0.5
printf '%s[?]%s numero da conta Mullvad (16 digitos): %s\n' "$AMARELO" "$RESET" ""
p 0.7
info "Conta ************4712: consultando..."
p 1.0
ok "Conta valida. Expira em: 2027-03-14"
p 0.5
aviso "Vou registrar uma chave nova. A Mullvad permite 5 por conta."
responde "Continuar? [S/n]" "s"
p 0.9
ok "Chave registrada. Endereco atribuido: 10.68.4.219/32"
p 0.6

printf '\n%sPais de saida%s\n\n' "$NEGRITO" "$RESET"
printf '   12) Brazil\n   47) Sweden\n   49) Switzerland\n'
printf '  %s... 50 paises, 553 relays%s\n\n' "$CINZA" "$RESET"
p 0.9
responde "pais>" "12"
printf '\n%sRelay em Brazil%s\n\n' "$NEGRITO" "$RESET"
printf '    1) br-for-wg-001  (Fortaleza)\n    2) br-sao-wg-101  (Sao Paulo)\n\n'
p 0.8
responde "relay>" "2"
p 0.8
ok "Conf gerado: /etc/wireguard/mullvad/br-sao-wg-101.conf"
p 0.6

# ---------------------------------------------------------------------------
# 4) Estagio 3: container
# ---------------------------------------------------------------------------
printf '\n%s>>> Container%s\n' "$NEGRITO" "$RESET"; p 0.4
info "Criando a rede exegol-vpn-net (172.30.30.0/24)..."
p 0.7
ok "rede criada"
info "Criando exegol-mullvad com capabilities de VPN..."
p 1.1
ok "capabilities conferidas: NET_ADMIN + src_valid_mark"
info "Fixando 172.30.30.10 em exegol-vpn-net..."
p 0.8
ok "IP fixo: 172.30.30.10"
ok "payload instalado em /home/demon7/.exegol/my-resources/bin"
ok "conf instalado em /etc/wireguard/wg0.conf dentro do container"
ok "alias mullvad-switch instalado"
p 0.6

# ---------------------------------------------------------------------------
# 5) Estagio 4: kill switch
# ---------------------------------------------------------------------------
printf '\n%s>>> Kill switch%s\n' "$NEGRITO" "$RESET"; p 0.4
ok "scripts do host instalados em /usr/local/sbin"
p 0.7
ok "exegol-mullvad-killswitch-watcher.service: ativo e habilitado no boot"
p 0.5
info "Estado atual da chain EXEGOL-MULLVAD-KS:"
printf 'Chain EXEGOL-MULLVAD-KS (1 references)\n'
printf ' pkts bytes target  prot opt in  out  source        destination\n'
printf '    0     0 DROP    all  --  *   *    172.30.30.10  0.0.0.0/0\n'
printf '    0     0 DROP    all  --  *   *    0.0.0.0/0     172.30.30.10\n'
p 1.0
info "Subindo o tunel pela primeira vez..."
p 1.3

# ---------------------------------------------------------------------------
# 6) Estagio 5: verificacao com teste de vazamento
# ---------------------------------------------------------------------------
printf '\n%s>>> Verificacao%s\n' "$NEGRITO" "$RESET"; p 0.4
printf '\n%sVerificacao%s\n\n' "$NEGRITO" "$RESET"
_passa "handshake do wg0 estabelecido"
_passa "saindo pela Mullvad: 45.134.140.77 (Sao Paulo, Brazil)"
_passa "resolv.conf aponta para o DNS da Mullvad (10.64.0.1)"
_passa "IPv6 bloqueado"
_passa "watcher da camada 2 ativo (exegol-mullvad-killswitch-watcher.service)"
p 0.5
printf '\n%sTeste de vazamento -- derrubando o tunel de proposito%s\n\n' "$NEGRITO" "$RESET"
p 0.9
_passa "camada 1: sem tunel, nada sai do container"
p 0.5
_passa "camada 2: descartou o trafego com a camada 1 desativada (0 -> 7)"
p 0.5
info "Restaurando o tunel..."
p 1.0
_passa "tunel restaurado e saindo pela Mullvad"
printf '\n'
ok "Tudo passou. O kill switch esta protegendo nas duas camadas."
printf '\n'
p 0.8
ok "Pronto. Use: exegol start mullvad   e dentro dele: mullvad-switch"
p 1.6

# ---------------------------------------------------------------------------
# 7) Troca de relay, de dentro do container
# ---------------------------------------------------------------------------
clear 2>/dev/null || true
printf '%s$%s exegol start mullvad\n' "$CINZA" "$RESET"; p 1.0
# O prompt que o estagio 3 instala: demon7 em vermelho, sect em branco.
printf '%sdemon7%s@%ssect%s ~ $ mullvad-switch\n' \
  "$VERMELHO" "$RESET" "$BRANCO" "$RESET"; p 0.9

printf '\n%s%s%s%s\n' "$AZUL_FUNDO" "$AMARELO$NEGRITO" \
  "$(centrar 'M U L L V A D   S W I T C H')" "$RESET"
printf '%s%s%s\n' "$AZUL_FUNDO$CINZA" \
  "$(centrar 'container Exegol que so sai pela Mullvad')" "$RESET"
printf '\n%s553 relays disponiveis.%s\n' "$CINZA" "$RESET"
p 0.8
faixa "modo"
item 1 "Trocar so a saida  (mantem a entrada br-sao-wg-101)"
item 2 "Multihop completo  (escolher entrada e saida)"
item 3 "Single-hop  (um relay so)"
item 4 "Ver status"
p 1.0
responde "modo>" "2"
p 0.6
faixa "ENTRADA / pais"
item 47 "Sweden  (23 relays)"
p 0.7
responde "ENTRADA / pais>" "47"
item 1 "se-got-wg-007  Gothenburg"
p 0.6
responde "ENTRADA / Sweden>" "1"
p 0.6
faixa "SAIDA / pais"
item 49 "Switzerland  (11 relays)"
p 0.7
responde "SAIDA / pais>" "49"
item 3 "ch-zrh-wg-503  Zurich"
p 0.6
responde "SAIDA / Switzerland>" "3"
p 0.7

printf '\nMultihop: se-got-wg-007 -> ch-zrh-wg-503 (Zurich, Switzerland)\n'
p 0.8
printf '%sconfirmando a saida (ate 10s)...%s\n' "$CINZA" "$RESET"
p 1.8
ok "conectado"
printf '\n'
rotulo "IP de saida ........." "185.213.155.74"
rotulo "Localizacao ........." "Zurich, Switzerland"
printf '  %sSaindo pela Mullvad .%s %ssim%s\n\n' "$CINZA" "$RESET" "$VERDE" "$RESET"
p 2.2
