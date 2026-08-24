#!/usr/bin/env python3
"""API publica da Mullvad.

Contratos verificados em 2026-08-23:
  GET  /public/relays/wireguard/v1/   -> lista de relays, expoe multihop_port
  POST /wg/  (account, pubkey)        -> endereco atribuido; HTTP 400 se conta invalida
  GET  /www/accounts/<n>/             -> dados da conta; HTTP 404 se nao existe

A API nova (app/v1/relays) NAO expoe multihop_port, por isso usamos a legada.
Apenas stdlib -- roda no host e dentro do container sem instalar nada.
"""
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

URL_RELAYS = "https://api.mullvad.net/public/relays/wireguard/v1/"
URL_WG = "https://api.mullvad.net/wg/"
URL_CONTA = "https://api.mullvad.net/www/accounts/%s/"
PORTA_SINGLEHOP = 51820
TIMEOUT = 15


class ErroMullvad(Exception):
    """Falha ao falar com a Mullvad ou dado invalido vindo dela."""


def parse_relays(dados):
    """Achata a arvore paises->cidades->relays numa lista ordenada."""
    relays = []
    for pais in dados.get("countries", []):
        for cidade in pais.get("cities", []):
            for r in cidade.get("relays", []):
                relays.append({
                    "hostname": r["hostname"],
                    "public_key": r["public_key"],
                    "ipv4_addr_in": r["ipv4_addr_in"],
                    "multihop_port": r["multihop_port"],
                    "pais": pais["name"],
                    "cidade": cidade["name"],
                })
    relays.sort(key=lambda r: (r["pais"], r["cidade"], r["hostname"]))
    return relays


def endpoint_singlehop(relay):
    """(ip, porta, pubkey) para conexao direta a um relay."""
    return relay["ipv4_addr_in"], PORTA_SINGLEHOP, relay["public_key"]


def endpoint_multihop(entrada, saida):
    """(ip, porta, pubkey) para multihop.

    Conecta no IP da ENTRADA, na porta multihop_port PROPRIA da SAIDA,
    autenticando com a chave publica da SAIDA.
    """
    if entrada["hostname"] == saida["hostname"]:
        raise ErroMullvad("entrada e saida nao podem ser o mesmo relay")
    return entrada["ipv4_addr_in"], saida["multihop_port"], saida["public_key"]


def agrupar_por_pais(relays):
    grupos = {}
    for r in relays:
        grupos.setdefault(r["pais"], []).append(r)
    return grupos


def _achar(relays, campo, valor):
    for r in relays:
        if r[campo] == valor:
            return r
    return None


def achar_por_hostname(relays, hostname):
    return _achar(relays, "hostname", hostname)


def achar_por_ip(relays, ip):
    return _achar(relays, "ipv4_addr_in", ip)


def achar_por_pubkey(relays, pubkey):
    return _achar(relays, "public_key", pubkey)


def buscar_relays(url=URL_RELAYS):
    try:
        with urllib.request.urlopen(url, timeout=TIMEOUT) as r:
            return parse_relays(json.load(r))
    except (urllib.error.URLError, ValueError, KeyError) as e:
        raise ErroMullvad("nao consegui buscar a lista de relays: %s" % e)


def info_conta(conta):
    """Dados da conta. Levanta ErroMullvad se nao existe."""
    try:
        with urllib.request.urlopen(URL_CONTA % conta, timeout=TIMEOUT) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            raise ErroMullvad("conta nao encontrada")
        raise ErroMullvad("erro HTTP %d ao consultar a conta" % e.code)
    except (urllib.error.URLError, ValueError) as e:
        raise ErroMullvad("nao consegui consultar a conta: %s" % e)


def registrar_chave(conta, pubkey):
    """Registra a chave publica na conta e devolve o endereco atribuido.

    Cada chave registrada ocupa um dos 5 slots de dispositivo da conta -- quem
    chama e responsavel por reaproveitar chave existente em vez de gerar nova.
    """
    dados = urllib.parse.urlencode({"account": conta, "pubkey": pubkey}).encode()
    try:
        with urllib.request.urlopen(URL_WG, data=dados, timeout=TIMEOUT) as r:
            endereco = r.read().decode().strip()
    except urllib.error.HTTPError as e:
        corpo = e.read().decode(errors="replace").strip()
        raise ErroMullvad(
            "a Mullvad recusou o registro da chave: %s" % (corpo or ("HTTP %d" % e.code))
        )
    except urllib.error.URLError as e:
        raise ErroMullvad("nao consegui falar com a API da Mullvad: %s" % e)
    if not endereco:
        raise ErroMullvad("a Mullvad aceitou o registro mas nao devolveu endereco")
    return endereco


def do_ambiente(nome):
    """Le um segredo do ambiente. Levanta ErroMullvad se ausente ou vazio.

    /proc/<pid>/cmdline e' -r--r--r-- (world-readable) enquanto
    /proc/<pid>/environ e' -r-------- (so do dono) -- medido neste host, sem
    hidepid. Por isso o numero da conta, que e' a UNICA credencial da conta
    Mullvad, entra por aqui e NUNCA por argv: em argv qualquer usuario local,
    qualquer processo com o /proc do host montado, e qualquer `ps` numa
    gravacao de tela o captura.
    """
    valor = os.environ.get(nome, "")
    if not valor:
        raise ErroMullvad("variavel de ambiente %s ausente ou vazia" % nome)
    return valor


def main(argv):
    if len(argv) < 2:
        print(
            "uso: mullvad_api.py relays\n"
            "     mullvad_api.py conta <numero>            (numero em argv -- NAO usar com conta real)\n"
            "     mullvad_api.py conta-env                 (numero em MULLVAD_CONTA)\n"
            "     mullvad_api.py registrar <numero> <pubkey>  (idem: NAO usar com conta real)\n"
            "     mullvad_api.py registrar-env <pubkey>    (numero em MULLVAD_CONTA)",
            file=sys.stderr,
        )
        return 2
    cmd = argv[1]
    try:
        if cmd == "relays":
            json.dump(buscar_relays(), sys.stdout)
        elif cmd == "conta":
            json.dump(info_conta(argv[2]), sys.stdout)
        elif cmd == "conta-env":
            json.dump(info_conta(do_ambiente("MULLVAD_CONTA")), sys.stdout)
        elif cmd == "registrar":
            print(registrar_chave(argv[2], argv[3]))
        elif cmd == "registrar-env":
            # A pubkey continua em argv de proposito: chave PUBLICA nao e' segredo.
            print(registrar_chave(do_ambiente("MULLVAD_CONTA"), argv[2]))
        else:
            print("comando desconhecido: %s" % cmd, file=sys.stderr)
            return 2
    except (ErroMullvad, IndexError) as e:
        print("erro: %s" % e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
