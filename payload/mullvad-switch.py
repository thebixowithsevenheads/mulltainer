#!/usr/bin/env python3
"""Troca o relay Mullvad ativo, de dentro do container.

Autonomo: reescreve /etc/wireguard/wg0.conf e reconecta sem envolver o host. O
PostUp reaplica a camada 1 do kill switch e reescreve o state.json; o watcher do
host reage em ate 1 segundo. Nao existe mais protocolo request/response.

Rollback: guarda o conf anterior e, se a sonda de conectividade (sondar_saida)
nao confirmar a saida esperada dentro de ESPERA_HANDSHAKE segundos, volta pra
ele e reconecta. Uma troca que falha nao deixa o container sem internet.

Nao valida pelo handshake do WireGuard: ele e lazy -- so ocorre quando ha
trafego pra mandar, entao um tunel recem-criado e ocioso fica com
latest-handshakes = 0 mesmo funcionando perfeitamente. A sonda GERA o
trafego (um curl) que dispara o handshake e, de quebra, confirma que a saida
e a esperada -- ver sondar_saida().

O modo rapido NAO tem relay chumbado: reusa a entrada que estiver no state.json.
"""
import json
import os
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import mullvad_api as api
import wgconf

CONF = "/etc/wireguard/wg0.conf"
CONF_BACKUP = "/etc/wireguard/wg0.conf.rollback"
ARQ_ESTADO = "/workspace/.mullvad/state.json"
ESPERA_HANDSHAKE = 10
# Um tunel parado por horas precisa de uma requisicao pra reacordar, e ela
# costuma falhar antes do handshake terminar -- ver buscar_relays_com_retentativa.
TENTATIVAS_RELAYS = 3
ESPERA_ENTRE_TENTATIVAS = 4

# Paleta da Mullvad: amarelo #FFD524 e azul escuro #294D73.
#
# O azul escuro entra so como FUNDO. Como cor de TEXTO ele fica praticamente
# ilegivel num terminal de fundo escuro -- 41,77,115 sobre 16,20,28 e' quase
# nenhum contraste. Onde o azul precisa aparecer escrito, usa-se o AZUL_CLARO,
# que e a mesma familia levantada ate dar pra ler.
AMARELO = "\033[38;2;255;213;36m"
AZUL_FUNDO = "\033[48;2;41;77;115m"
AZUL_CLARO = "\033[38;2;108;137;168m"
VERMELHO = "\033[31m"
VERDE = "\033[32m"
NEGRITO = "\033[1m"
RESET = "\033[0m"

# Largura maxima das barras. Acompanha o terminal, mas nao passa disso pra nao
# virar uma faixa gigante numa janela larga.
LARGURA_MAX = 78


def _largura():
    return min(shutil.get_terminal_size((80, 24)).columns, LARGURA_MAX)


def cabecalho(titulo):
    """Titulo de secao: amarelo em negrito sobre a faixa azul da marca."""
    print("\n%s%s%s%s%s" % (
        AZUL_FUNDO, AMARELO + NEGRITO, (" " + titulo).ljust(_largura()), RESET, "\n"))


def diga(msg):
    print(msg)


def erro(msg):
    print("%s[-]%s %s" % (VERMELHO, RESET, msg), file=sys.stderr)


def ok(msg):
    print("%s[+]%s %s" % (VERDE, RESET, msg))


def banner():
    titulo = "M U L L V A D   S W I T C H"
    larg = _largura()
    print("\n%s%s%s%s" % (AZUL_FUNDO, AMARELO + NEGRITO, titulo.center(larg), RESET))
    print("%s%s%s" % (AZUL_CLARO, "container Exegol que so sai pela Mullvad".center(larg),
                      RESET))


def ler_estado():
    try:
        with open(ARQ_ESTADO) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def achar_fzf():
    """Resolve o fzf sem chumbar caminho. None -> cai pro menu numerado."""
    achado = shutil.which("fzf")
    if achado:
        return achado
    conhecido = "/opt/tools/fzf/bin/fzf"
    return conhecido if os.access(conhecido, os.X_OK) else None


FZF = achar_fzf()


# Mesma paleta do resto da UI, traduzida pros nomes que o fzf usa.
CORES_FZF = ",".join([
    "fg:-1", "bg:-1",
    "hl:#ffd524", "fg+:#ffd524", "bg+:#294d73", "hl+:#ffd524",
    "prompt:#ffd524", "pointer:#ffd524", "marker:#ffd524",
    "header:#6c89a8", "border:#294d73", "info:#6c89a8",
])


def escolher(opcoes, titulo):
    """Escolhe um item. opcoes: lista de (rotulo, valor). None se cancelou."""
    if not opcoes:
        return None
    if FZF:
        entrada = "\n".join(
            "%d\t%s" % (i, rotulo) for i, (rotulo, _) in enumerate(opcoes)
        )
        proc = subprocess.run(
            [FZF, "--layout=reverse", "--height=90%", "--border=rounded",
             "--color=" + CORES_FZF,
             "--delimiter=\t", "--with-nth=2", "--header=ESC cancela | " + titulo,
             "--prompt=%s> " % titulo],
            input=entrada, capture_output=True, text=True,
        )
        if proc.returncode != 0 or not proc.stdout.strip():
            return None
        return opcoes[int(proc.stdout.split("\t", 1)[0])][1]

    cabecalho(titulo)
    for i, (rotulo, _) in enumerate(opcoes, 1):
        print("  %s%3d)%s %s" % (AMARELO, i, RESET, rotulo))
    try:
        bruto = input("\n%s%s>%s " % (AMARELO, titulo, RESET)).strip()
    except (EOFError, KeyboardInterrupt):
        return None
    if not bruto.isdigit() or not (1 <= int(bruto) <= len(opcoes)):
        return None
    return opcoes[int(bruto) - 1][1]


def escolher_relay(relays, titulo, excluir=None):
    grupos = api.agrupar_por_pais(relays)
    while True:
        pais = escolher(
            [("%s  (%d relays)" % (p, len(grupos[p])), p) for p in sorted(grupos)],
            titulo + " / pais",
        )
        if pais is None:
            return None
        candidatos = [r for r in grupos[pais] if not excluir or r["hostname"] != excluir]
        escolhido = escolher(
            [("%s  %s" % (r["hostname"], r["cidade"]), r) for r in candidatos],
            titulo + " / " + pais,
        )
        if escolhido is not None:
            return escolhido
        # ESC no relay volta pro pais, em vez de cancelar tudo.


def wg(*args):
    return subprocess.run(["wg-quick", *args], capture_output=True, text=True)


def tem_handshake():
    """So pra exibicao no status -- NAO validar uma troca com isto.

    O handshake do WireGuard e lazy: so ocorre quando ha trafego pra mandar.
    Um tunel recem-criado e ocioso fica com latest-handshakes = 0 mesmo
    funcionando perfeitamente, entao usar isto em aplicar() faz a troca
    parecer que falhou e disparar rollback mesmo quando o relay novo esta
    bom. Quem valida uma troca e sondar_saida(), que gera trafego de
    proposito.
    """
    p = subprocess.run(["wg", "show", "wg0", "latest-handshakes"],
                       capture_output=True, text=True)
    if p.returncode != 0:
        return False
    for linha in p.stdout.strip().splitlines():
        partes = linha.split()
        if len(partes) == 2 and partes[1].isdigit() and int(partes[1]) > 0:
            return True
    return False


def diagnosticar_sem_rede():
    """Devolve uma dica sobre por que nao ha rede, ou None se nao souber.

    Existe porque, com o kill switch de pe, "sem rede" dentro do container
    quer dizer quase sempre "sem tunel" -- e a mensagem crua da urllib fala de
    resolucao de nome, que manda o usuario investigar DNS quando o problema e
    o tunel. Visto em campo: `Temporary failure in name resolution` num
    container cujo wg0 estava de pe mas com o ultimo handshake de 12h atras.

    Aqui o handshake PODE ser usado como sinal, ao contrario de aplicar(): so
    chamamos isto depois de uma requisicao ter falhado de verdade, entao o
    caso "tunel ocioso e sadio com handshake 0" ja esta descartado.
    """
    p = subprocess.run(["wg", "show", "wg0", "latest-handshakes"],
                       capture_output=True, text=True)
    if p.returncode != 0:
        return ("o wg0 nao esta de pe. Sem tunel, o kill switch bloqueia tudo "
                "-- e e' por isso que nao ha rede.\n"
                "      sobe com: wg-quick up wg0")

    agora = int(time.time())
    idades = []
    for linha in p.stdout.strip().splitlines():
        partes = linha.split()
        if len(partes) == 2 and partes[1].isdigit():
            quando = int(partes[1])
            idades.append(None if quando == 0 else agora - quando)

    if not idades:
        return None
    if all(i is None for i in idades):
        return ("o wg0 esta de pe, mas nunca houve handshake com o relay.\n"
                "      o endpoint pode estar inalcancavel; reconecta com: "
                "wg-quick down wg0 && wg-quick up wg0")

    mais_novo = min(i for i in idades if i is not None)
    if mais_novo > 180:
        # Nao dizer "morto": um tunel assim reacorda sozinho na primeira
        # requisicao. Se chegamos aqui, as retentativas ja nao bastaram.
        return ("o wg0 esta de pe, mas o ultimo handshake foi ha %d min. Um "
                "tunel tanto tempo ocioso precisa reacordar, e as tentativas "
                "acima nao bastaram.\n"
                "      reconecta com: wg-quick down wg0 && wg-quick up wg0"
                % (mais_novo // 60))
    return None


def buscar_relays_com_retentativa(dormir=None):
    """Busca a lista de relays tolerando um tunel ocioso.

    O handshake do WireGuard e lazy e as chaves de sessao expiram. Depois de
    horas parado, a PRIMEIRA requisicao e' a que acorda o tunel -- e ela
    costuma estourar o timeout antes do handshake terminar, enquanto a
    seguinte passa.

    Visto em campo: um container com o ultimo handshake de 12h40m deu
    "Temporary failure in name resolution" no mullvad-switch, e a requisicao
    seguinte funcionou sem nenhuma intervencao -- foi a propria requisicao que
    falhou que acordou o tunel. Morrer na primeira falha transformava um tunel
    sadio-mas-ocioso em erro fatal.

    Este e o mesmo motivo pelo qual sondar_saida() gera trafego em vez de
    olhar o handshake; aqui a busca de relays e a primeira operacao de rede do
    programa, entao e ela que paga o custo de acordar.
    """
    # Resolvido na chamada, nao no def: `dormir=time.sleep` como default
    # captura a funcao real na definicao do modulo, e ai um mock em time.sleep
    # nao pega -- a suite passava esperando 4 segundos de verdade.
    if dormir is None:
        dormir = time.sleep
    ultimo = None
    for n in range(1, TENTATIVAS_RELAYS + 1):
        try:
            return api.buscar_relays()
        except api.ErroMullvad as e:
            ultimo = e
            if n < TENTATIVAS_RELAYS:
                diga("%stunel ocioso? acordando (tentativa %d de %d)...%s"
                     % (AZUL_CLARO, n, TENTATIVAS_RELAYS, RESET))
                dormir(ESPERA_ENTRE_TENTATIVAS)
    raise ultimo


def sondar_saida(saida_esperada=None):
    """Sonda a conectividade pelo tunel. Devolve (ok, hostname_de_saida).

    E esta funcao que valida uma troca, nao o handshake: o curl GERA o trafego
    que dispara o handshake, e de quebra confirma que a saida e a esperada.

    mullvad_exit_ip por si so nao basta: um container sem tunel nenhum (wg0
    fora, iptables em ACCEPT) ainda sai pela Mullvad se o HOST estiver na
    Mullvad -- so o hostname da saida prova que e o tunel do container, e nao
    o do host, que esta sendo usado.
    """
    p = subprocess.run(
        ["curl", "-s", "--max-time", "8", "https://am.i.mullvad.net/json"],
        capture_output=True, text=True,
    )
    try:
        d = json.loads(p.stdout)
    except ValueError:
        return False, None
    host = d.get("mullvad_exit_ip_hostname")
    if not d.get("mullvad_exit_ip"):
        return False, host
    if saida_esperada and host != saida_esperada:
        return False, host
    return True, host


def aplicar(pubkey, ip, porta, modo, entrada_hostname, saida_hostname, estado_anterior):
    """Reescreve o conf, reconecta e confirma a saida via sondar_saida. Rollback se falhar.

    estado_anterior e o state.json de antes da troca -- se precisar de
    rollback, o rollback() usa ele para re-setar as env vars do PostUp em vez
    de deixar os valores do relay novo (que falhou) poluindo o state.json.
    """
    with open(CONF) as f:
        antes = f.read()
    shutil.copyfile(CONF, CONF_BACKUP)
    os.chmod(CONF_BACKUP, 0o600)

    with open(CONF, "w") as f:
        f.write(wgconf.trocar_peer(antes, pubkey, ip, porta))

    # O PostUp le estas env vars para gravar entrada/saida/modo no state.json.
    os.environ["MULLVAD_MODO"] = modo
    os.environ["MULLVAD_ENTRADA"] = entrada_hostname
    os.environ["MULLVAD_SAIDA"] = saida_hostname

    try:
        wg("down", "wg0")
        subida = wg("up", "wg0")
        if subida.returncode != 0:
            erro("wg-quick up falhou:\n" + subida.stderr.strip())
            return rollback(estado_anterior)

        diga("%sconfirmando a saida (ate %ds)...%s" % (AZUL_CLARO, ESPERA_HANDSHAKE, RESET))
        host_visto = None
        for _ in range(ESPERA_HANDSHAKE):
            ok_saida, host_visto = sondar_saida(saida_hostname)
            if ok_saida:
                return True
            time.sleep(1)

        if host_visto and host_visto != saida_hostname:
            erro("saindo por %s, nao por %s -- a troca nao pegou" % (
                host_visto, saida_hostname))
        else:
            erro("sem conectividade pelo tunel em %ds apos a troca" % ESPERA_HANDSHAKE)
        return rollback(estado_anterior)
    except KeyboardInterrupt:
        erro("interrompido -- desfazendo a troca e voltando pro relay anterior")
        return rollback(estado_anterior)


def rollback(estado_anterior):
    """Restaura o conf anterior e as env vars do PostUp que o descrevem.

    Sem isso, o state.json ficaria com entry/exit/mode do relay que acabou de
    falhar mesmo depois do conf voltar ao normal -- e o modo rapido reusaria
    essa entrada quebrada na proxima troca.
    """
    if not os.path.exists(CONF_BACKUP):
        erro("nao ha backup pra voltar. O tunel esta fora.")
        return False
    diga("%svoltando pro relay anterior...%s" % (AMARELO, RESET))
    shutil.copyfile(CONF_BACKUP, CONF)
    os.environ["MULLVAD_MODO"] = estado_anterior.get("mode") or "desconhecido"
    os.environ["MULLVAD_ENTRADA"] = estado_anterior.get("entry_hostname") or ""
    os.environ["MULLVAD_SAIDA"] = estado_anterior.get("exit_hostname") or ""
    wg("down", "wg0")
    if wg("up", "wg0").returncode == 0:
        ok("rollback feito: o relay anterior esta de volta")
    else:
        erro("o rollback tambem falhou. O tunel esta fora -- rode 'wg-quick up wg0'")
    return False


def mostrar_saida():
    p = subprocess.run(
        ["curl", "-s", "--max-time", "10", "https://am.i.mullvad.net/json"],
        capture_output=True, text=True,
    )
    try:
        d = json.loads(p.stdout)
    except ValueError:
        erro("nao consegui confirmar a saida em am.i.mullvad.net")
        return
    pela_mullvad = d.get("mullvad_exit_ip")
    print("\n  %sIP de saida .........%s %s" % (AZUL_CLARO, RESET, d.get("ip", "?")))
    print("  %sLocalizacao .........%s %s, %s" % (
        AZUL_CLARO, RESET, d.get("city", "?"), d.get("country", "?")))
    print("  %sSaindo pela Mullvad .%s %s\n" % (
        AZUL_CLARO, RESET,
        "%ssim%s" % (VERDE, RESET) if pela_mullvad else "%sNAO%s" % (VERMELHO, RESET)
    ))


def status(estado, relays):
    entrada = estado.get("entry_hostname") or "?"
    saida = estado.get("exit_hostname") or "?"
    print("\n  %sModo .......%s %s" % (AZUL_CLARO, RESET, estado.get("mode") or "?"))
    print("  %sEntrada ....%s %s" % (AZUL_CLARO, RESET, entrada))
    print("  %sSaida ......%s %s" % (AZUL_CLARO, RESET, saida))
    print("  %sEndpoint ...%s %s:%s" % (
        AZUL_CLARO, RESET,
        estado.get("endpoint_ip", "?"), estado.get("endpoint_port", "?")
    ))
    print("  %sHandshake ..%s %s" % (
        AZUL_CLARO, RESET, "sim" if tem_handshake() else "NAO"))
    mostrar_saida()


def main():
    if os.geteuid() != 0:
        erro("roda como root dentro do container")
        return 1

    banner()
    estado = ler_estado()
    try:
        relays = buscar_relays_com_retentativa()
    except api.ErroMullvad as e:
        erro(str(e))
        dica = diagnosticar_sem_rede()
        if dica:
            diga("  %s->%s %s" % (AMARELO, RESET, dica))
        return 1
    diga("%s%d relays disponiveis.%s" % (AZUL_CLARO, len(relays), RESET))

    entrada_atual = api.achar_por_hostname(relays, estado.get("entry_hostname") or "")

    opcoes = []
    if entrada_atual:
        opcoes.append(
            ("Trocar so a saida  (mantem a entrada %s)" % entrada_atual["hostname"],
             "rapido")
        )
    opcoes.append(("Multihop completo  (escolher entrada e saida)", "multihop"))
    opcoes.append(("Single-hop  (um relay so)", "singlehop"))
    opcoes.append(("Ver status", "status"))

    modo = escolher(opcoes, "modo")
    if modo is None:
        diga("cancelado.")
        return 1

    if modo == "status":
        status(estado, relays)
        return 0

    if modo == "singlehop":
        relay = escolher_relay(relays, "SAIDA")
        if relay is None:
            diga("cancelado.")
            return 1
        ip, porta, pubkey = api.endpoint_singlehop(relay)
        alvo = (pubkey, ip, porta, "singlehop", relay["hostname"], relay["hostname"])
        diga("\nSingle-hop -> %s (%s, %s)" % (
            relay["hostname"], relay["cidade"], relay["pais"]))
    else:
        if modo == "rapido":
            entrada = entrada_atual
        else:
            entrada = escolher_relay(relays, "ENTRADA")
            if entrada is None:
                diga("cancelado.")
                return 1
        saida = escolher_relay(relays, "SAIDA", excluir=entrada["hostname"])
        if saida is None:
            diga("cancelado.")
            return 1
        try:
            ip, porta, pubkey = api.endpoint_multihop(entrada, saida)
        except api.ErroMullvad as e:
            erro(str(e))
            return 1
        alvo = (pubkey, ip, porta, "multihop", entrada["hostname"], saida["hostname"])
        diga("\nMultihop: %s -> %s (%s, %s)" % (
            entrada["hostname"], saida["hostname"], saida["cidade"], saida["pais"]))

    if not aplicar(*alvo, estado):
        return 1
    ok("conectado")
    mostrar_saida()
    return 0


if __name__ == "__main__":
    sys.exit(main())
