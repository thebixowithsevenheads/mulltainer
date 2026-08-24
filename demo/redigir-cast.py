#!/usr/bin/env python3
"""Redige um .cast de gravacao REAL, removendo tudo que identifique a maquina.

Existe porque o GIF de prova de conceito e gravado numa instalacao de verdade,
com conta Mullvad de verdade. O mockup nao tem esse problema (os dados dele sao
inventados); este tem, e um vazamento aqui e permanente -- o GIF vai pro README.

Politica: o que PROVA a ferramenta fica, o que identifica a maquina sai.

  Fica:
    - hostnames de relay (br-sao-wg-101, se-got-wg-007): a lista da Mullvad e
      publica.
    - IP de saida e cidade/pais do ipinfo: sao os IPs COMPARTILHADOS dos relays
      da Mullvad, nao o seu. Sao exatamente a prova de que o IP mudou.

  Sai:
    - numero da conta Mullvad, inclusive na forma ja mascarada (os 4 digitos
      finais sao informacao).
    - chaves WireGuard (base64 de 44 chars).
    - endereco atribuido no tunel (10.x/fc00:) -- identifica o slot de device.
    - validade da conta (data correlacionavel).
    - nome de usuario, home e hostname da maquina.
    - IPs privados e MACs.

Uso:
  python3 demo/redigir-cast.py entrada.cast saida.cast [--usuario SEU_USUARIO] [--host SEU_HOST]

O comando SEMPRE roda a varredura no fim e sai != 0 se sobrar suspeita. Um
arquivo que nao passa na varredura nao deve ser publicado.
"""
import argparse
import json
import re
import sys

# Cada regra: (nome, regex compilada, substituicao).
# A ordem importa: as mais especificas primeiro, senao uma geral come a outra.
def montar_regras(usuario, host, como_usuario="demon7", como_host="sect"):
    regras = []

    # Chave WireGuard: base64 de 43 chars + '='. Antes de tudo, porque uma
    # chave pode conter sequencias que outras regras tentariam casar.
    regras.append((
        "chave WireGuard",
        re.compile(r"(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{43}=(?![A-Za-z0-9+/=])"),
        "<chave-ocultada-------------------------->=",
    ))

    # Senha de root do container, que o Exegol imprime no resumo:
    #     |      Credentials | root : qP6ilZqdz7vqjPTFZoBncZczDvQ3MO |
    # Encontrada lendo a gravacao a mao, DEPOIS da varredura ter passado --
    # sao 30 chars, nao casam com o padrao de chave WireGuard (44 com '=') e
    # nenhuma outra regra a pegava. E' uma credencial de verdade.
    #
    # A mascara tem o mesmo comprimento do achado para nao desalinhar a tabela
    # de box-drawing em que ela aparece.
    regras.append((
        "senha de root do container",
        # Tolerante a ANSI no meio: o Exegol COLORE o valor, entao o texto real
        # e `root` ESC[0m ` : ` ESC[38;5;32m <senha>. Um `root\s*:\s*` simples
        # nao casa nada -- foi a heuristica de entropia da varredura que
        # denunciou isso, depois desta regra ter falhado em silencio.
        re.compile(r"(root(?:\s|\x1b\[[0-9;]*m)*:(?:\s|\x1b\[[0-9;]*m)*)"
                   r"([A-Za-z0-9+/]{16,})"),
        lambda m: m.group(1) + "*" * len(m.group(2)),
    ))

    # Conta Mullvad ja mascarada pelo instalador: os 4 digitos finais que ele
    # mostra sao informacao, entao aqui vira mascara inteira.
    regras.append((
        "conta mascarada",
        re.compile(r"\*{8,}\d{2,6}"),
        "*" * 16,
    ))

    # Conta crua: 16 digitos seguidos. Nao deveria aparecer (o instalador le
    # com `read -s`, sem eco), mas se um dia aparecer, sai aqui.
    regras.append((
        "conta em claro",
        re.compile(r"(?<!\d)\d{16}(?!\d)"),
        "*" * 16,
    ))

    # Endereco atribuido no tunel: identifica o slot de device na conta.
    #
    # 10.64.0.1 fica de fora de proposito: e' o DNS da Mullvad, igual para todo
    # assinante, e aparece na verificacao ("resolv.conf aponta para o DNS da
    # Mullvad (10.64.0.1)"). Mascarar aquilo estragaria a demonstracao sem
    # proteger nada.
    regras.append((
        "endereco WireGuard v4",
        re.compile(r"(?<![\d.])(?!10\.64\.0\.1(?![\d]))"
                   r"10\.(6[4-9]|7[0-9])\.\d{1,3}\.\d{1,3}(/\d{1,2})?"),
        "10.x.x.x/32",
    ))
    regras.append((
        "endereco WireGuard v6",
        re.compile(r"fc00:[0-9a-f:]+(/\d{1,3})?", re.I),
        "fc00:<ocultado>/128",
    ))

    # Validade da conta: data correlacionavel com a compra.
    regras.append((
        "validade da conta",
        re.compile(r"(Expira em:\s*)\d{4}-\d{2}-\d{2}"),
        r"\g<1>AAAA-MM-DD",
    ))

    # Identidade da maquina. O usuario e o hostname reais saem, e no lugar entra
    # a MESMA identidade que o instalador poe no prompt do container
    # (PROMPT_USUARIO/PROMPT_HOST, demon7@sect). Assim a gravacao fica coerente
    # de ponta a ponta em vez de misturar "user@host" com "demon7@sect".
    if usuario:
        regras.append((
            "home do usuario",
            re.compile(r"/home/" + re.escape(usuario) + r"\b"),
            "/home/" + como_usuario,
        ))
        regras.append((
            "nome de usuario",
            re.compile(r"(?<![A-Za-z0-9_-])" + re.escape(usuario) + r"(?![A-Za-z0-9_-])"),
            como_usuario,
        ))
    if host:
        regras.append((
            "hostname da maquina",
            re.compile(r"(?<![A-Za-z0-9_-])" + re.escape(host) + r"(?![A-Za-z0-9_-])"),
            como_host,
        ))

    # Endereco MAC.
    regras.append((
        "MAC",
        re.compile(r"(?<![0-9a-f:])([0-9a-f]{2}:){5}[0-9a-f]{2}(?![0-9a-f:])", re.I),
        "xx:xx:xx:xx:xx:xx",
    ))

    return regras


# Padroes que NAO podem sobrar no arquivo final. A varredura e' separada das
# regras de proposito: se uma regra falhar em casar, e' a varredura que avisa,
# nao o silencio.
def montar_varredura(usuario, host):
    v = [
        ("chave WireGuard", re.compile(r"(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{43}=(?![A-Za-z0-9+/=])")),
        ("16 digitos seguidos", re.compile(r"(?<!\d)\d{16}(?!\d)")),
        ("endereco de tunel Mullvad",
         re.compile(r"(?<![\d.])(?!10\.64\.0\.1(?![\d]))"
                    r"10\.(6[4-9]|7[0-9])\.\d{1,3}\.\d{1,3}")),
        ("endereco fc00::", re.compile(r"fc00:[0-9a-f]{2,}", re.I)),
        ("MAC", re.compile(r"(?<![0-9a-f:])([0-9a-f]{2}:){5}[0-9a-f]{2}(?![0-9a-f:])", re.I)),
        ("data de validade", re.compile(r"Expira em:\s*\d{4}")),
        ("credencial impressa", re.compile(r"root\s*:\s*[A-Za-z0-9+/]{16,}")),
        # Rede para o segredo que ninguem previu. A varredura original passou
        # limpa numa gravacao que continha a senha de root do container: ela so
        # achava o que eu tinha ensinado. Esta regra nao olha formato conhecido,
        # olha CARA DE ALEATORIO -- 20+ chars misturando maiuscula, minuscula e
        # digito, o que texto humano e caminho de arquivo praticamente nunca faz.
        ("string com cara de segredo",
         re.compile(r"(?<![A-Za-z0-9+/=])"
                    r"(?=[A-Za-z0-9+/]{20,})"
                    r"(?=[A-Za-z0-9+/]*[a-z])"
                    r"(?=[A-Za-z0-9+/]*[A-Z])"
                    r"(?=[A-Za-z0-9+/]*[0-9])"
                    r"[A-Za-z0-9+/]{20,}(?![A-Za-z0-9+/=])")),
    ]
    if usuario:
        v.append(("nome de usuario",
                  re.compile(r"(?<![A-Za-z0-9_-])" + re.escape(usuario) + r"(?![A-Za-z0-9_-])")))
    if host:
        v.append(("hostname da maquina",
                  re.compile(r"(?<![A-Za-z0-9_-])" + re.escape(host) + r"(?![A-Za-z0-9_-])")))
    return v


def redigir_texto(texto, regras):
    contagem = {}
    for nome, rx, sub in regras:
        texto, n = rx.subn(sub, texto)
        if n:
            contagem[nome] = contagem.get(nome, 0) + n
    return texto, contagem


def processar(entrada, saida, regras):
    linhas = open(entrada, encoding="utf-8", errors="surrogateescape").read().splitlines()
    if not linhas:
        sys.exit("cast vazio")

    total = {}
    fora = []

    # Linha 1 e o cabecalho JSON: tem env, command, e as vezes o title -- que
    # carregam usuario e hostname tanto quanto a saida do terminal.
    cab = json.loads(linhas[0])
    cab.pop("env", None)          # SHELL/TERM/USER nao provam nada e identificam
    bruto_cab = json.dumps(cab, ensure_ascii=False)
    bruto_cab, c = redigir_texto(bruto_cab, regras)
    for k, v in c.items():
        total[k] = total.get(k, 0) + v
    fora.append(bruto_cab)

    for l in linhas[1:]:
        if not l.strip():
            continue
        try:
            ev = json.loads(l)
        except json.JSONDecodeError:
            continue
        if len(ev) >= 3 and isinstance(ev[2], str):
            ev[2], c = redigir_texto(ev[2], regras)
            for k, v in c.items():
                total[k] = total.get(k, 0) + v
        fora.append(json.dumps(ev, ensure_ascii=False))

    open(saida, "w", encoding="utf-8").write("\n".join(fora) + "\n")
    return total


def varrer(caminho, varredura):
    texto = open(caminho, encoding="utf-8", errors="surrogateescape").read()
    achados = []
    for nome, rx in varredura:
        for m in rx.finditer(texto):
            ini = max(0, m.start() - 40)
            achados.append((nome, m.group(0), texto[ini:m.end() + 20].replace("\n", " ")))
            if len(achados) > 40:
                return achados
    return achados


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("entrada")
    ap.add_argument("saida")
    ap.add_argument("--usuario", default="", help="nome de usuario do host a remover")
    ap.add_argument("--host", default="", help="hostname da maquina a remover")
    ap.add_argument("--como-usuario", default="demon7",
                    help="nome que entra no lugar do usuario real (padrao: a mesma "
                         "identidade que o instalador poe no prompt do container)")
    ap.add_argument("--como-host", default="sect",
                    help="nome que entra no lugar do hostname real")
    args = ap.parse_args()

    regras = montar_regras(args.usuario, args.host, args.como_usuario, args.como_host)
    total = processar(args.entrada, args.saida, regras)

    print("Redacoes aplicadas:")
    if total:
        for k in sorted(total):
            print("  %-26s %d" % (k, total[k]))
    else:
        print("  (nenhuma -- confira se --usuario e --host foram passados)")

    achados = varrer(args.saida, montar_varredura(args.usuario, args.host))
    print("\nVarredura do arquivo final:")
    if not achados:
        print("  limpo: nenhum padrao sensivel encontrado.")
        return 0
    print("  ATENCAO -- %d ocorrencia(s) sobraram. NAO publique este arquivo:" % len(achados))
    for nome, achado, ctx in achados[:20]:
        print("    [%s] %r" % (nome, achado))
        print("      contexto: ...%s..." % ctx[-70:])
    return 1


if __name__ == "__main__":
    sys.exit(main())
