# Arquivos de teste sao sourcados pelo runner; nao definem 'set' por si mesmo.
#
# Segredos nunca em argv. /proc/<pid>/cmdline e' -r--r--r-- (world-readable) e
# /proc/<pid>/environ e' -r-------- (so do dono) -- medido no host de
# desenvolvimento, sem hidepid. Um segredo em argv fica visivel para qualquer
# usuario local, para qualquer processo com o /proc do host montado (o proprio
# container faz isso em outras montagens) e para qualquer `ps` que apareca numa
# gravacao de tela.
#
# Os dois segredos deste projeto: o numero da conta Mullvad (unica credencial
# da conta) e a chave privada do WireGuard.
#
# As linhas do lib sao JUNTADAS pelas continuacoes "\" antes do grep: o call
# site real e' quebrado em duas linhas, e um grep linha-a-linha nao veria um
# argv reintroduzido na linha de baixo.

_LIB_MULLVAD="$RAIZ/lib/02-mullvad.sh"
_juntado="$(sed -e :a -e '/\\$/N; s/\\\n//; ta' "$_LIB_MULLVAD")"

# --- o numero da conta ---
afirmar_igual 0 "$(grep -cE 'mullvad_api\.py[^|]*"\$conta"' <<< "$_juntado" || true)" \
  "segredo: numero da conta nunca vai em argv do mullvad_api.py"
afirmar_contem 'MULLVAD_CONTA="$conta"' "$_juntado" \
  "segredo: numero da conta vai por MULLVAD_CONTA no ambiente"
afirmar_contem 'mullvad_api.py" conta-env' "$_juntado" \
  "segredo: a consulta da conta usa o subcomando conta-env"
afirmar_contem 'mullvad_api.py" registrar-env "$pubkey"' "$_juntado" \
  "segredo: o registro usa registrar-env com so a pubkey em argv"

# --- a chave privada do WireGuard ---
afirmar_igual 0 "$(grep -cE 'wgconf\.py[^|]*"\$privkey"' <<< "$_juntado" || true)" \
  "segredo: chave privada nunca vai em argv do wgconf.py"
afirmar_contem 'WG_PRIVKEY="$privkey"' "$_juntado" \
  "segredo: chave privada vai por WG_PRIVKEY no ambiente"
afirmar_contem 'wgconf.py" construir-env' "$_juntado" \
  "segredo: a construcao do conf usa o subcomando construir-env"

# O endereco atribuido pela Mullvad identifica o dispositivo na conta; vai
# junto, pelo ambiente, no mesmo processo.
afirmar_igual 0 "$(grep -cE 'wgconf\.py[^|]*"\$endereco"' <<< "$_juntado" || true)" \
  "segredo: endereco atribuido nunca vai em argv do wgconf.py"

# --- os subcomandos com segredo em argv nao podem ser usados pelo instalador ---
# (continuam existindo no CLI, documentados como "NAO usar com conta real",
#  porque os testes de unidade os exercitam com valores de mentira)
# Ancorado no nome do script de proposito: "conta \"$conta\"" solto tambem casa
# com chamadas de FUNCAO do shell (mascarar_conta, _chave_e_desta_conta), que nao
# criam processo nenhum e portanto nao aparecem em /proc.
for _sub in 'wgconf\.py" construir "\$privkey"' 'mullvad_api\.py" conta "\$conta"' \
            'mullvad_api\.py" registrar "\$conta"'; do
  afirmar_igual 0 "$(grep -cE "$_sub" <<< "$_juntado" || true)" \
    "segredo: o instalador nao usa a forma posicional (${_sub})"
done
unset _sub _juntado _LIB_MULLVAD
