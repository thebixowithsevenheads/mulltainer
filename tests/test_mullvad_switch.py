import contextlib
import importlib.util
import io
import json
import os
import subprocess
import unittest
from unittest import mock

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CAMINHO_MS = os.path.join(RAIZ, "payload", "mullvad-switch.py")

# O arquivo tem hifen no nome -- nao e importavel como modulo normal.
_spec = importlib.util.spec_from_file_location("mullvad_switch", CAMINHO_MS)
ms = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ms)


@contextlib.contextmanager
def _sem_saida():
    """Suprime print()/diga()/erro() pra manter a saida da suite limpa."""
    with contextlib.redirect_stdout(io.StringIO()), \
         contextlib.redirect_stderr(io.StringIO()):
        yield


class TestLerEstado(unittest.TestCase):
    def test_arquivo_ausente_devolve_dict_vazio(self):
        with mock.patch.object(ms, "ARQ_ESTADO", "/caminho/que/nao/existe/state.json"):
            self.assertEqual(ms.ler_estado(), {})

    def test_json_invalido_devolve_dict_vazio_sem_estourar(self):
        import tempfile
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".json", delete=False
        ) as f:
            f.write("{ isso nao e json valido ]")
            caminho = f.name
        try:
            with mock.patch.object(ms, "ARQ_ESTADO", caminho):
                self.assertEqual(ms.ler_estado(), {})
        finally:
            os.unlink(caminho)

    def test_documento_valido_e_devolvido_intacto(self):
        import tempfile
        doc = {
            "mode": "multihop",
            "entry_hostname": "us-nyc-wg-001",
            "exit_hostname": "se-got-wg-007",
        }
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".json", delete=False
        ) as f:
            json.dump(doc, f)
            caminho = f.name
        try:
            with mock.patch.object(ms, "ARQ_ESTADO", caminho):
                self.assertEqual(ms.ler_estado(), doc)
        finally:
            os.unlink(caminho)


class TestAcharFzf(unittest.TestCase):
    def test_nenhum_fzf_disponivel_devolve_none(self):
        with mock.patch.object(ms.shutil, "which", return_value=None), \
             mock.patch.object(ms.os, "access", return_value=False):
            self.assertIsNone(ms.achar_fzf())

    def test_so_caminho_conhecido_disponivel_devolve_ele(self):
        with mock.patch.object(ms.shutil, "which", return_value=None), \
             mock.patch.object(ms.os, "access", return_value=True) as macesso:
            self.assertEqual(ms.achar_fzf(), "/opt/tools/fzf/bin/fzf")
            macesso.assert_called_once_with("/opt/tools/fzf/bin/fzf", os.X_OK)

    def test_fzf_no_path_tem_prioridade_e_evita_checar_caminho_conhecido(self):
        with mock.patch.object(ms.shutil, "which", return_value="/usr/bin/fzf"), \
             mock.patch.object(ms.os, "access") as macesso:
            self.assertEqual(ms.achar_fzf(), "/usr/bin/fzf")
            macesso.assert_not_called()


class TestEscolherMenuNumerado(unittest.TestCase):
    """Forca FZF = None pra exercitar so o menu numerado (input())."""

    def setUp(self):
        self._patch_fzf = mock.patch.object(ms, "FZF", None)
        self._patch_fzf.start()
        # opcoes com rotulo != valor: se escolher devolver o rotulo, ou usar
        # indice errado (off-by-one), o teste tem que falhar.
        self.opcoes = [
            ("Suecia (7 relays)", "se-relay"),
            ("Suica (3 relays)", "ch-relay"),
            ("Japao (1 relay)", "jp-relay"),
        ]

    def tearDown(self):
        self._patch_fzf.stop()

    def _escolher_com_input(self, texto_digitado):
        # o menu numerado imprime as opcoes em print() -- suprime pra nao
        # poluir a saida da suite.
        with mock.patch.object(ms, "input", return_value=texto_digitado, create=True), \
             _sem_saida():
            return ms.escolher(self.opcoes, "titulo")

    def test_escolha_numerica_valida_devolve_o_valor_certo_nao_o_rotulo(self):
        # opcao 2 (indice humano) -> "ch-relay", nao "Suica (3 relays)"
        self.assertEqual(self._escolher_com_input("2"), "ch-relay")

    def test_primeira_opcao_nao_sofre_off_by_one(self):
        self.assertEqual(self._escolher_com_input("1"), "se-relay")

    def test_ultima_opcao_nao_sofre_off_by_one(self):
        self.assertEqual(self._escolher_com_input("3"), "jp-relay")

    def test_fora_do_intervalo_devolve_none(self):
        self.assertIsNone(self._escolher_com_input("4"))

    def test_zero_devolve_none(self):
        self.assertIsNone(self._escolher_com_input("0"))

    def test_nao_numerico_devolve_none(self):
        self.assertIsNone(self._escolher_com_input("abc"))

    def test_entrada_vazia_devolve_none(self):
        self.assertIsNone(self._escolher_com_input(""))

    def test_lista_de_opcoes_vazia_devolve_none_sem_perguntar(self):
        with mock.patch.object(ms, "input", create=True) as mentrada:
            self.assertIsNone(ms.escolher([], "titulo"))
            mentrada.assert_not_called()


class TestEscolherFzf(unittest.TestCase):
    """Exercita o ramo real (FZF presente), mockando subprocess.run.

    Este e o ramo que de fato roda dentro do container -- lá o fzf sempre
    existe -- por isso precisa de cobertura tao boa quanto o fallback.
    """

    def setUp(self):
        self._patch_fzf = mock.patch.object(ms, "FZF", "/usr/bin/fzf")
        self._patch_fzf.start()
        # de novo, rotulo != valor: devolver o rotulo ou o indice errado tem
        # que quebrar o teste.
        self.opcoes = [
            ("Suecia (7 relays)", "se-relay"),
            ("Suica (3 relays)", "ch-relay"),
            ("Japao (1 relay)", "jp-relay"),
        ]

    def tearDown(self):
        self._patch_fzf.stop()

    def _rodar(self, returncode, stdout):
        completo = subprocess.CompletedProcess(
            args=["/usr/bin/fzf"], returncode=returncode, stdout=stdout, stderr="",
        )
        with mock.patch.object(ms.subprocess, "run", return_value=completo) as mrun:
            resultado = ms.escolher(self.opcoes, "titulo")
        return resultado, mrun

    def test_selecao_do_meio_devolve_valor_e_nao_rotulo(self):
        resultado, _ = self._rodar(0, "1\tSuica (3 relays)\n")
        self.assertEqual(resultado, "ch-relay")

    def test_primeiro_indice_sem_off_by_one(self):
        resultado, _ = self._rodar(0, "0\tSuecia (7 relays)\n")
        self.assertEqual(resultado, "se-relay")

    def test_ultimo_indice_sem_off_by_one(self):
        resultado, _ = self._rodar(0, "2\tJapao (1 relay)\n")
        self.assertEqual(resultado, "jp-relay")

    def test_entrada_passada_pro_fzf_tem_indice_tab_rotulo_por_linha(self):
        _, mrun = self._rodar(0, "0\tSuecia (7 relays)\n")
        entrada_passada = mrun.call_args.kwargs["input"]
        self.assertEqual(
            entrada_passada,
            "0\tSuecia (7 relays)\n1\tSuica (3 relays)\n2\tJapao (1 relay)",
        )

    def test_returncode_diferente_de_zero_e_cancelamento(self):
        # ESC no fzf sai com returncode != 0 -- tem que ser None, nao estourar
        resultado, _ = self._rodar(1, "")
        self.assertIsNone(resultado)

    def test_returncode_diferente_de_zero_cancela_mesmo_com_stdout_no_buffer(self):
        # se o returncode nao for checado (so a vacuidade do stdout), esta
        # troca teria stdout valido e teria sido aceita por engano.
        resultado, _ = self._rodar(1, "1\tSuica (3 relays)\n")
        self.assertIsNone(resultado)

    def test_stdout_vazio_ou_so_espacos_e_cancelamento(self):
        resultado, _ = self._rodar(0, "   \n")
        self.assertIsNone(resultado)


class TestEscolherRelayEscVoltaProPais(unittest.TestCase):
    """Comportamento nomeado explicitamente no brief: ESC no relay reapresenta
    a escolha de pais, em vez de cancelar a operacao inteira."""

    def setUp(self):
        self.relays = [
            {"hostname": "se-1-wg-001", "cidade": "Estocolmo", "pais": "Suecia",
             "public_key": "k1", "ipv4_addr_in": "1.1.1.1", "multihop_port": 1},
            {"hostname": "se-2-wg-002", "cidade": "Gotemburgo", "pais": "Suecia",
             "public_key": "k2", "ipv4_addr_in": "1.1.1.2", "multihop_port": 2},
        ]

    def test_esc_no_relay_reapresenta_pais_em_vez_de_cancelar_tudo(self):
        relay_escolhido = self.relays[1]
        # 1a chamada: escolhe o pais. 2a: ESC no relay (None). 3a: escolhe o
        # pais outra vez (prova que o loop voltou). 4a: escolhe o relay.
        respostas = ["Suecia", None, "Suecia", relay_escolhido]
        with mock.patch.object(ms, "escolher", side_effect=respostas) as mescolher:
            resultado = ms.escolher_relay(self.relays, "SAIDA")
        self.assertEqual(resultado, relay_escolhido)
        self.assertEqual(mescolher.call_count, 4)

    def test_esc_no_pais_cancela_tudo_devolvendo_none(self):
        with mock.patch.object(ms, "escolher", side_effect=[None]) as mescolher:
            resultado = ms.escolher_relay(self.relays, "SAIDA")
        self.assertIsNone(resultado)
        self.assertEqual(mescolher.call_count, 1)


class TestRollbackRestauraEnvVars(unittest.TestCase):
    """rollback() precisa re-setar MULLVAD_MODO/ENTRADA/SAIDA a partir do
    estado anterior -- senao o state.json fica com o relay que acabou de
    falhar mesmo depois do conf ter voltado ao normal."""

    NOMES = ("MULLVAD_MODO", "MULLVAD_ENTRADA", "MULLVAD_SAIDA")

    def setUp(self):
        self._env_original = {n: os.environ.get(n) for n in self.NOMES}

    def tearDown(self):
        for n, v in self._env_original.items():
            if v is None:
                os.environ.pop(n, None)
            else:
                os.environ[n] = v

    def test_rollback_restaura_env_vars_do_estado_anterior_nao_do_que_falhou(self):
        os.environ["MULLVAD_MODO"] = "multihop"
        os.environ["MULLVAD_ENTRADA"] = "entrada-que-falhou"
        os.environ["MULLVAD_SAIDA"] = "saida-que-falhou"
        estado_anterior = {
            "mode": "rapido",
            "entry_hostname": "entrada-boa",
            "exit_hostname": "saida-boa",
        }
        completo_ok = mock.Mock(returncode=0)
        with mock.patch.object(ms.os.path, "exists", return_value=True), \
             mock.patch.object(ms.shutil, "copyfile"), \
             mock.patch.object(ms, "wg", return_value=completo_ok), \
             _sem_saida():
            resultado = ms.rollback(estado_anterior)
        self.assertFalse(resultado)
        self.assertEqual(os.environ["MULLVAD_MODO"], "rapido")
        self.assertEqual(os.environ["MULLVAD_ENTRADA"], "entrada-boa")
        self.assertEqual(os.environ["MULLVAD_SAIDA"], "saida-boa")

    def test_rollback_com_estado_anterior_vazio_usa_modo_desconhecido(self):
        completo_ok = mock.Mock(returncode=0)
        with mock.patch.object(ms.os.path, "exists", return_value=True), \
             mock.patch.object(ms.shutil, "copyfile"), \
             mock.patch.object(ms, "wg", return_value=completo_ok), \
             _sem_saida():
            ms.rollback({})
        self.assertEqual(os.environ["MULLVAD_MODO"], "desconhecido")
        self.assertEqual(os.environ["MULLVAD_ENTRADA"], "")
        self.assertEqual(os.environ["MULLVAD_SAIDA"], "")

    def test_sem_backup_no_disco_nao_toca_env_vars_e_devolve_false(self):
        os.environ["MULLVAD_MODO"] = "multihop"
        with mock.patch.object(ms.os.path, "exists", return_value=False), \
             _sem_saida():
            resultado = ms.rollback({"mode": "rapido"})
        self.assertFalse(resultado)
        self.assertEqual(os.environ["MULLVAD_MODO"], "multihop")


class TestSondarSaida(unittest.TestCase):
    """sondar_saida e quem valida uma troca -- o handshake e lazy e nao serve
    pra isso (ver docstring de tem_handshake). Os testes aqui sempre checam o
    hostname devolvido, nao so o booleano: um teste que so olhasse pro
    booleano passaria mesmo se a comparacao de hostname fosse removida."""

    def _rodar(self, corpo_json, saida_esperada=None):
        completo = mock.Mock(stdout=corpo_json)
        with mock.patch.object(ms.subprocess, "run", return_value=completo):
            return ms.sondar_saida(saida_esperada)

    def test_saida_bate_com_a_esperada(self):
        corpo = json.dumps({
            "mullvad_exit_ip": True,
            "mullvad_exit_ip_hostname": "br-for-wg-001",
        })
        ok, host = self._rodar(corpo, "br-for-wg-001")
        self.assertTrue(ok)
        self.assertEqual(host, "br-for-wg-001")

    def test_mullvad_exit_ip_true_mas_hostname_de_outro_relay_e_falso(self):
        # este e o caso de "carona" no tunel do host: o host esta na Mullvad,
        # o container nao tem tunel nenhum, e mullvad_exit_ip ainda vem true.
        corpo = json.dumps({
            "mullvad_exit_ip": True,
            "mullvad_exit_ip_hostname": "se-got-wg-007",
        })
        ok, host = self._rodar(corpo, "br-for-wg-001")
        self.assertFalse(ok)
        self.assertEqual(host, "se-got-wg-007")

    def test_mullvad_exit_ip_false_e_falso_independente_do_hostname(self):
        corpo = json.dumps({
            "mullvad_exit_ip": False,
            "mullvad_exit_ip_hostname": "br-for-wg-001",
        })
        ok, host = self._rodar(corpo, "br-for-wg-001")
        self.assertFalse(ok)
        self.assertEqual(host, "br-for-wg-001")

    def test_corpo_nao_json_devolve_false_e_hostname_none(self):
        ok, host = self._rodar("isso nao e json", "br-for-wg-001")
        self.assertFalse(ok)
        self.assertIsNone(host)

    def test_sem_saida_esperada_aceita_qualquer_saida_da_mullvad(self):
        corpo = json.dumps({
            "mullvad_exit_ip": True,
            "mullvad_exit_ip_hostname": "qualquer-relay",
        })
        ok, host = self._rodar(corpo, saida_esperada=None)
        self.assertTrue(ok)
        self.assertEqual(host, "qualquer-relay")


class TestAplicarConfirmaPelaSonda(unittest.TestCase):
    """aplicar() tem que validar a troca com sondar_saida (que gera trafego),
    nunca com o handshake (que e lazy e fica em zero num tunel ocioso, mesmo
    saudavel -- isso e o bug de campo que motivou esta rodada)."""

    def _aplicar_com(self, sondar_side_effect, rollback_side_effect=None):
        completo_ok = mock.Mock(returncode=0)
        chamadas_rollback = []

        def rollback_padrao(estado_anterior):
            chamadas_rollback.append(estado_anterior)
            return False

        estado_anterior = {"mode": "rapido", "entry_hostname": "e", "exit_hostname": "s"}

        with mock.patch("builtins.open", mock.mock_open(read_data="conteudo-antigo")), \
             mock.patch.object(ms.shutil, "copyfile"), \
             mock.patch.object(ms.os, "chmod"), \
             mock.patch.object(ms.wgconf, "trocar_peer", return_value="conteudo-novo"), \
             mock.patch.object(ms, "wg", return_value=completo_ok), \
             mock.patch.object(ms, "sondar_saida", side_effect=sondar_side_effect), \
             mock.patch.object(ms, "rollback",
                                side_effect=rollback_side_effect or rollback_padrao), \
             mock.patch.object(ms.time, "sleep"), \
             _sem_saida():
            resultado = ms.aplicar(
                "pubkey-novo", "1.2.3.4", 51820, "multihop", "entrada-nova",
                "saida-nova", estado_anterior,
            )
        return resultado, chamadas_rollback, estado_anterior

    def test_sucesso_so_na_segunda_tentativa_nao_precisa_ser_na_primeira(self):
        # a primeira sondagem falha (tunel ainda subindo), a segunda confirma
        # -- se aplicar() so olhasse a primeira tentativa isto quebraria.
        resultado, chamadas_rollback, _ = self._aplicar_com(
            [(False, None), (True, "saida-nova")]
        )
        self.assertTrue(resultado)
        self.assertEqual(chamadas_rollback, [])

    def test_sonda_nunca_confirma_aciona_rollback(self):
        resultado, chamadas_rollback, estado_anterior = self._aplicar_com(
            [(False, "outro-relay")] * ms.ESPERA_HANDSHAKE
        )
        self.assertFalse(resultado)
        self.assertEqual(chamadas_rollback, [estado_anterior])

    def test_ctrl_c_durante_a_sonda_aciona_rollback_em_vez_de_propagar(self):
        resultado, chamadas_rollback, estado_anterior = self._aplicar_com(
            KeyboardInterrupt
        )
        self.assertFalse(resultado)
        self.assertEqual(chamadas_rollback, [estado_anterior])


if __name__ == "__main__":
    unittest.main()


class TestBuscarRelaysComRetentativa(unittest.TestCase):
    """Um tunel parado por horas falha na PRIMEIRA requisicao e passa na
    seguinte -- a propria requisicao que falha e' a que acorda o handshake.
    Visto em campo com o ultimo handshake de 12h40m. Morrer na primeira falha
    transformava um tunel sadio-mas-ocioso em erro fatal.
    """

    def test_sucesso_na_primeira_nao_dorme(self):
        dormiu = []
        with mock.patch.object(ms.api, "buscar_relays", return_value=["r"]):
            with _sem_saida():
                r = ms.buscar_relays_com_retentativa(dormir=dormiu.append)
        self.assertEqual(["r"], r)
        self.assertEqual([], dormiu, "nao deve esperar quando a primeira funciona")

    def test_falha_na_primeira_e_passa_na_segunda(self):
        chamadas = []

        def falso():
            chamadas.append(1)
            if len(chamadas) == 1:
                raise ms.api.ErroMullvad("Temporary failure in name resolution")
            return ["r1", "r2"]

        dormiu = []
        with mock.patch.object(ms.api, "buscar_relays", side_effect=falso):
            with _sem_saida():
                r = ms.buscar_relays_com_retentativa(dormir=dormiu.append)
        self.assertEqual(["r1", "r2"], r)
        self.assertEqual(2, len(chamadas), "devia ter tentado de novo")
        self.assertEqual([ms.ESPERA_ENTRE_TENTATIVAS], dormiu)

    def test_desiste_depois_do_limite_e_propaga_o_erro(self):
        dormiu = []
        with mock.patch.object(ms.api, "buscar_relays",
                               side_effect=ms.api.ErroMullvad("sem rede")):
            with _sem_saida():
                with self.assertRaises(ms.api.ErroMullvad):
                    ms.buscar_relays_com_retentativa(dormir=dormiu.append)
        # Espera entre tentativas, nunca depois da ultima.
        self.assertEqual(ms.TENTATIVAS_RELAYS - 1, len(dormiu))

    def test_tenta_mais_de_uma_vez(self):
        self.assertGreater(ms.TENTATIVAS_RELAYS, 1,
                           "com 1 tentativa a retentativa nao existe")


class TestDiagnosticarSemRede(unittest.TestCase):
    """A mensagem crua da urllib fala de resolucao de nome, o que manda o
    usuario investigar DNS quando o problema e' o tunel. O diagnostico traduz.
    """

    def _wg(self, returncode, stdout):
        return mock.patch.object(
            ms.subprocess, "run",
            return_value=subprocess.CompletedProcess([], returncode, stdout, ""))

    def test_wg0_ausente_manda_subir_o_tunel(self):
        with self._wg(1, ""):
            dica = ms.diagnosticar_sem_rede()
        self.assertIn("wg-quick up wg0", dica)
        self.assertIn("nao esta de pe", dica)

    def test_nunca_houve_handshake(self):
        with self._wg(0, "CHAVE\t0\n"):
            dica = ms.diagnosticar_sem_rede()
        self.assertIn("nunca houve handshake", dica)

    def test_handshake_velho_nao_afirma_que_o_tunel_morreu(self):
        import time as _t
        velho = int(_t.time()) - 12 * 3600
        with self._wg(0, "CHAVE\t%d\n" % velho):
            dica = ms.diagnosticar_sem_rede()
        self.assertIn("720 min", dica)
        # Um tunel assim reacorda sozinho; chamar de morto manda o usuario
        # atras do problema errado.
        self.assertNotIn("morto", dica)

    def test_handshake_recente_nao_gera_dica(self):
        import time as _t
        with self._wg(0, "CHAVE\t%d\n" % (int(_t.time()) - 5)):
            self.assertIsNone(ms.diagnosticar_sem_rede())


class TestMainUsaARetentativa(unittest.TestCase):
    """A retentativa pode existir perfeita e main() chamar api.buscar_relays
    direto, desfazendo tudo em silencio. Esta e' a unica coisa que pega isso:
    os testes da funcao em si passavam com main() ligado no caminho antigo.
    """

    def test_main_tolera_a_falha_do_tunel_ocioso(self):
        chamadas = []

        def falso():
            chamadas.append(1)
            if len(chamadas) == 1:
                raise ms.api.ErroMullvad("Temporary failure in name resolution")
            return [{"hostname": "se-got-wg-007", "cidade": "Gothenburg",
                     "pais": "Sweden", "ipv4": "1.2.3.4",
                     "pubkey": "K", "multihop_port": 3000}]

        with mock.patch.object(ms.os, "geteuid", return_value=0), \
             mock.patch.object(ms, "ler_estado", return_value={}), \
             mock.patch.object(ms, "buscar_relays_com_retentativa",
                               wraps=ms.buscar_relays_com_retentativa) as espia, \
             mock.patch.object(ms.api, "buscar_relays", side_effect=falso), \
             mock.patch.object(ms.time, "sleep"), \
             mock.patch.object(ms, "escolher", return_value=None):
            with _sem_saida():
                rc = ms.main()

        espia.assert_called_once()
        self.assertEqual(2, len(chamadas),
                         "main() precisa passar pela retentativa, nao chamar a API direto")
        self.assertEqual(1, rc, "cancelar no menu devolve 1")
