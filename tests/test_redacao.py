"""Testes do demo/redigir-cast.py.

Um vazamento aqui e permanente: o GIF vai pro README. Entao os testes cobrem os
DOIS lados, e o segundo importa tanto quanto o primeiro:

  1. cada tipo de segredo sai;
  2. o que PROVA a ferramenta sobrevive -- hostnames de relay, IPs de saida da
     Mullvad e o DNS 10.64.0.1. Um redator que apaga tudo passaria no lado 1 e
     entregaria um GIF que nao demonstra nada.
"""
import importlib.util
import json
import os
import tempfile
import unittest

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CAMINHO = os.path.join(RAIZ, "demo", "redigir-cast.py")

_spec = importlib.util.spec_from_file_location("redigir", CAMINHO)
red = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(red)

USUARIO = "joana"
HOST = "bancada"

# Uma sessao real condensada: tudo que o instalador imprime de sensivel, mais o
# que ele imprime de essencial.
LINHAS = [
    "[i] Conta ************4712: consultando...",
    "[+] Conta valida. Expira em: 2027-03-14",
    "[+] Chave registrada. Endereco atribuido: 10.68.4.219/32",
    "Address = 10.70.9.12/32,fc00:bbbb:bbbb:bb01::3:8009/128",
    "PublicKey = CiPqGvrQidRVmKc6T8TORsAAZtQbsGzNEAKyd1iVlWY=",
    "[+] payload instalado em /home/joana/.exegol/my-resources/bin",
    "joana@bancada ~ $ mullvad-switch",
    "link/ether a4:5e:60:c1:22:9f brd ff:ff:ff:ff:ff:ff",
    # As que TEM que sobreviver:
    "[+] resolv.conf aponta para o DNS da Mullvad (10.64.0.1)",
    "[+] saindo pela Mullvad: 185.213.155.74 (Zurich, Switzerland)",
    "Multihop: se-got-wg-007 -> ch-zrh-wg-503 (Zurich, Switzerland)",
    '{"ip": "45.134.140.77", "city": "Sao Paulo", "country": "BR"}',
]


def _cast(linhas, env=True):
    cab = {"version": 3, "term": {"cols": 80, "rows": 24}, "timestamp": 1787545468}
    if env:
        cab["env"] = {"SHELL": "/usr/bin/zsh", "USER": USUARIO}
    fora = [json.dumps(cab)]
    for l in linhas:
        fora.append(json.dumps([0.5, "o", l + "\r\n"]))
    d = tempfile.mkdtemp(prefix="redacao-")
    p = os.path.join(d, "e.cast")
    open(p, "w", encoding="utf-8").write("\n".join(fora) + "\n")
    return p, os.path.join(d, "s.cast")


def _redigir(linhas, env=True):
    ent, sai = _cast(linhas, env)
    regras = red.montar_regras(USUARIO, HOST)
    red.processar(ent, sai, regras)
    return open(sai, encoding="utf-8").read(), sai


class TestSegredosSaem(unittest.TestCase):
    def setUp(self):
        self.txt, self.arq = _redigir(LINHAS)

    def test_conta_mascarada_perde_os_4_digitos_finais(self):
        # Os 4 digitos que o instalador mostra sao informacao: reduzem em 10^4
        # o espaco de busca de uma credencial de 16 digitos.
        self.assertNotIn("4712", self.txt)

    def test_validade_da_conta_sai(self):
        self.assertNotIn("2027-03-14", self.txt)
        self.assertIn("AAAA-MM-DD", self.txt)

    def test_endereco_atribuido_sai(self):
        self.assertNotIn("10.68.4.219", self.txt)
        self.assertNotIn("10.70.9.12", self.txt)

    def test_endereco_v6_do_tunel_sai(self):
        self.assertNotIn("bb01::3:8009", self.txt)

    def test_chave_wireguard_sai(self):
        self.assertNotIn("CiPqGvrQidRVmKc6T8TORsAAZtQbsGzNEAKyd1iVlWY=", self.txt)

    def test_home_e_usuario_saem(self):
        self.assertNotIn("/home/joana", self.txt)
        self.assertNotIn("joana", self.txt)

    def test_hostname_sai(self):
        self.assertNotIn("bancada", self.txt)

    def test_mac_sai(self):
        self.assertNotIn("a4:5e:60:c1:22:9f", self.txt)

    def test_env_do_cabecalho_sai_inteiro(self):
        cab = json.loads(self.txt.splitlines()[0])
        self.assertNotIn("env", cab, "o env do cabecalho carrega USER e SHELL")

    def test_a_varredura_aprova_o_resultado(self):
        achados = red.varrer(self.arq, red.montar_varredura(USUARIO, HOST))
        self.assertEqual([], achados)


class TestProvaSobrevive(unittest.TestCase):
    """Sem isto, um redator que apagasse tudo passaria nos testes acima."""

    def setUp(self):
        self.txt, _ = _redigir(LINHAS)

    def test_dns_publico_da_mullvad_fica(self):
        # 10.64.0.1 e igual para todo assinante: mascarar nao protege ninguem e
        # tira um item da verificacao.
        self.assertIn("10.64.0.1", self.txt)

    def test_ips_de_saida_ficam(self):
        # Sao IPs COMPARTILHADOS dos relays, nao o do usuario -- e sao a prova
        # de que o IP mudou.
        self.assertIn("185.213.155.74", self.txt)
        self.assertIn("45.134.140.77", self.txt)

    def test_hostnames_de_relay_ficam(self):
        self.assertIn("se-got-wg-007", self.txt)
        self.assertIn("ch-zrh-wg-503", self.txt)

    def test_cidade_e_pais_ficam(self):
        self.assertIn("Zurich", self.txt)
        self.assertIn("Sao Paulo", self.txt)


class TestVarreduraAcusa(unittest.TestCase):
    """A varredura e a rede de seguranca: se uma REGRA falhar, e ela que avisa.
    Um redator que nao redige nada tem que reprovar, nao passar em silencio.
    """

    def _varrer_sem_redigir(self, linha):
        # env=False: o cabecalho do asciinema carrega USER=joana, e a varredura
        # acusa aquilo -- corretamente. Aqui queremos isolar SO a linha sob
        # teste, senao todo caso "nao pode alarmar" falharia pelo cabecalho.
        ent, _ = _cast([linha], env=False)
        return red.varrer(ent, red.montar_varredura(USUARIO, HOST))

    def test_acusa_chave(self):
        a = self._varrer_sem_redigir("PublicKey = CiPqGvrQidRVmKc6T8TORsAAZtQbsGzNEAKyd1iVlWY=")
        self.assertTrue(any(n == "chave WireGuard" for n, _, _ in a))

    def test_acusa_conta_em_claro(self):
        a = self._varrer_sem_redigir("conta 1234567890124712 digitada")
        self.assertTrue(any(n == "16 digitos seguidos" for n, _, _ in a))

    def test_acusa_endereco_de_tunel(self):
        a = self._varrer_sem_redigir("Address = 10.68.4.219/32")
        self.assertTrue(any(n == "endereco de tunel Mullvad" for n, _, _ in a))

    def test_acusa_usuario_e_hostname(self):
        a = self._varrer_sem_redigir("joana@bancada ~ $")
        nomes = {n for n, _, _ in a}
        self.assertIn("nome de usuario", nomes)
        self.assertIn("hostname da maquina", nomes)

    def test_nao_acusa_o_dns_publico(self):
        a = self._varrer_sem_redigir("DNS da Mullvad (10.64.0.1)")
        self.assertEqual([], a, "10.64.0.1 nao pode disparar alarme falso")

    def test_nao_acusa_ip_de_saida_publico(self):
        a = self._varrer_sem_redigir("saindo pela Mullvad: 185.213.155.74 (Zurich)")
        self.assertEqual([], a)


if __name__ == "__main__":
    unittest.main()


# A forma REAL em que a senha aparece: o Exegol colore o valor, entao ha
# sequencias ANSI entre "root :" e ela. Uma regra `root\s*:\s*` simples nao casa
# nada aqui -- foi assim que este vazamento passou pela varredura na primeira
# gravacao.
LINHA_SENHA = ("|      Credentials | root\x1b[0m : "
               "\x1b[38;5;32mqP6ilZqdz7vqjPTFZoBncZczDvQ3MO\x1b[0m |")


class TestSenhaDeRootDoContainer(unittest.TestCase):
    """Regressao do unico vazamento encontrado numa gravacao real.

    A varredura passou LIMPA num arquivo que continha a senha de root do
    container: 30 chars, sem '=', nao casava com o padrao de chave WireGuard e
    nenhuma outra regra a pegava. Achada lendo a gravacao a mao.
    """

    def test_a_senha_sai(self):
        txt, _ = _redigir([LINHA_SENHA])
        self.assertNotIn("qP6ilZqdz7vqjPTFZoBncZczDvQ3MO", txt)

    def test_a_mascara_tem_o_mesmo_tamanho(self):
        # A senha aparece dentro de uma tabela de box-drawing; trocar por uma
        # mascara de outro tamanho desalinharia a tabela inteira no GIF.
        txt, _ = _redigir([LINHA_SENHA])
        self.assertIn("*" * len("qP6ilZqdz7vqjPTFZoBncZczDvQ3MO"), txt)

    def test_a_varredura_acusa_a_senha_no_arquivo_cru(self):
        ent, _ = _cast([LINHA_SENHA], env=False)
        achados = red.varrer(ent, red.montar_varredura(USUARIO, HOST))
        self.assertTrue(achados, "a varredura tem que acusar a senha crua")


class TestHeuristicaDeSegredoDesconhecido(unittest.TestCase):
    """A licao da primeira gravacao: a varredura so achava o que eu ensinei.

    Esta regra nao olha formato conhecido, olha CARA DE ALEATORIO. Ela e o que
    denunciou a senha de root depois da regra especifica ter falhado em
    silencio, entao precisa continuar funcionando -- e nao pode gritar com o
    texto normal da sessao.
    """

    def _varrer(self, linha):
        ent, _ = _cast([linha], env=False)
        return red.varrer(ent, red.montar_varredura(USUARIO, HOST))

    def test_acusa_token_aleatorio_que_nenhuma_regra_conhece(self):
        a = self._varrer("Algum campo novo: Xk92MbQ7zLpR4vNtWs8y")
        self.assertTrue(any(n == "string com cara de segredo" for n, _, _ in a))

    def test_nao_acusa_hostname_de_relay(self):
        self.assertEqual([], self._varrer("  1) al-tia-wg-001  Tirana"))

    def test_nao_acusa_caminho_de_arquivo(self):
        self.assertEqual([], self._varrer("[+] Conf pronto: /etc/wireguard/mullvad/sego007-chzr003.conf"))

    def test_nao_acusa_texto_comum(self):
        self.assertEqual([], self._varrer("[+] Tudo passou. O kill switch esta protegendo nas duas camadas."))

    def test_nao_acusa_saida_do_ipinfo(self):
        self.assertEqual([], self._varrer("    Rede ...... AS43357 Owl Limited"))


class TestIdentidadeSubstituta(unittest.TestCase):
    """O usuario real sai, e no lugar entra a MESMA identidade que o instalador
    poe no prompt do container (demon7@sect). Sem isto a gravacao misturaria
    "user@host" nos caminhos com "demon7@sect" no prompt, o que fica incoerente
    -- e um leitor atento repara que sao duas maquinas diferentes.
    """

    LINHAS = [
        "[sudo] password for joana: ",
        "[+] payload instalado em /home/joana/.exegol/my-resources/bin",
        "joana@bancada ~ $ mullvad-switch",
    ]

    def test_padrao_e_demon7_e_sect(self):
        txt, _ = _redigir(self.LINHAS)
        self.assertNotIn("joana", txt)
        self.assertNotIn("bancada", txt)
        self.assertIn("password for demon7", txt)
        self.assertIn("/home/demon7/.exegol", txt)
        self.assertIn("demon7@sect", txt)

    def test_a_identidade_substituta_e_configuravel(self):
        ent, sai = _cast(self.LINHAS, env=False)
        red.processar(ent, sai, red.montar_regras(USUARIO, HOST, "alice", "lab"))
        txt = open(sai, encoding="utf-8").read()
        self.assertIn("alice@lab", txt)
        self.assertIn("/home/alice/", txt)
        self.assertNotIn("demon7", txt)
