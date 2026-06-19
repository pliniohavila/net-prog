#!/usr/bin/env bash
#
# setup_lab.sh
#
# Monta (ou desmonta) o laboratório de rede usado para desenvolver/testar
# a pilha de protocolos em C (ARP/IPv4/ICMP/UDP/TFTP/TCP/HTTP/DNS).
#
# Topologia criada:
#
#   [seu programa]  tap0          tap1  [seu programa / tcpdump]
#        host A   <------>  br0  <------>        host B
#
# - tap0 e tap1 NÃO recebem IP do kernel (propositalmente "burras").
#   O endereçamento (IP/MAC) é responsabilidade exclusiva do SEU código C.
# - br0 funciona como um switch de camada 2 isolado: não tem rota para a
#   internet nem para a LAN real do Windows/WSL.
#
# Uso:
#   ./setup_lab.sh up       # cria tap0, tap1, br0 e conecta tudo
#   ./setup_lab.sh down     # remove tudo (idempotente, não falha se já não existir)
#   ./setup_lab.sh status   # mostra o estado atual do laboratório
#   ./setup_lab.sh test     # testa tap0 -> br0 -> tap1 escrevendo um frame
#                           # ARP cru direto no fd (sem libs externas)
#
# Requisitos: iproute2, bridge-utils (opcional, usamos 'ip' puro), python3 (para 'test')
#
# O script é IDEMPOTENTE: pode rodar "up" várias vezes seguidas sem erro,
# e "down" também, mesmo se nada existir ainda.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuração
# ---------------------------------------------------------------------------
TAP0="tap0"
TAP1="tap1"
BRIDGE="br0"
OWNER_USER="${SUDO_USER:-$USER}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() {
    printf '[setup_lab] %s\n' "$1"
}

require_root_actions() {
    # As operações de rede exigem privilégio. Se não formos root, reexecuta
    # via sudo preservando o argumento original.
    if [[ "$(id -u)" -ne 0 ]]; then
        log "Privilégio de root necessário, reexecutando com sudo..."
        exec sudo --preserve-env=SUDO_USER -- "$0" "$@"
    fi
}

iface_exists() {
    ip link show "$1" &>/dev/null
}

iface_is_tap() {
    # Verifica se a interface existe E é um device tun/tap
    [[ -d "/sys/class/net/$1" ]] && [[ -f "/sys/class/net/$1/tun_flags" ]]
}

iface_master() {
    # Imprime o "master" (bridge) atual de uma interface, se houver
    ip -o link show "$1" 2>/dev/null | grep -oP 'master \K\S+' || true
}

# ---------------------------------------------------------------------------
# Ações
# ---------------------------------------------------------------------------

create_tap() {
    local tap="$1"
    if iface_exists "$tap"; then
        if iface_is_tap "$tap"; then
            log "Interface '$tap' já existe (tap) — pulando criação."
        else
            log "AVISO: '$tap' já existe mas não parece ser um device TAP. Não vou tocar nela."
            return 1
        fi
    else
        log "Criando interface TAP '$tap' (owner: $OWNER_USER)..."
        ip tuntap add dev "$tap" mode tap user "$OWNER_USER"
    fi

    # Desabilita IPv6 nesta interface. Sem isso, o kernel gera tráfego
    # automático de ICMPv6 (Router Solicitation, Neighbor Discovery,
    # multicast de grupo) toda vez que o carrier sobe — ruído que poluiu
    # as primeiras capturas de teste (pacotes de 110/90 bytes antes do
    # frame ARP esperado). Isso é só ruído de protocolo do kernel, não
    # bug nosso, mas deixar desabilitado mantém as capturas limpas para
    # você focar no tráfego que seu próprio código gera.
    local ipv6_sysctl_path="/proc/sys/net/ipv6/conf/$tap/disable_ipv6"
    if [[ -w "$ipv6_sysctl_path" ]]; then
        if [[ "$(cat "$ipv6_sysctl_path" 2>/dev/null)" != "1" ]]; then
            log "Desabilitando IPv6 em '$tap' (evita ruído de ICMPv6/multicast nas capturas)..."
            sysctl -qw "net.ipv6.conf.${tap}.disable_ipv6=1"
        else
            log "IPv6 já está desabilitado em '$tap' — pulando."
        fi
    else
        log "AVISO: não foi possível acessar '$ipv6_sysctl_path' para desabilitar IPv6 em '$tap' (sem suporte a IPv6 no kernel, ou caminho ainda não existe)."
    fi

    # Garante que está sem IP (kernel não deve ser "dono" do endereço)
    if ip addr show "$tap" | grep -q 'inet '; then
        log "AVISO: '$tap' tem IP atribuído pelo kernel. Removendo (endereçamento é responsabilidade do seu código)..."
        ip addr flush dev "$tap"
    fi

    log "Subindo '$tap' (link up)..."
    ip link set "$tap" up
}

create_bridge() {
    if iface_exists "$BRIDGE"; then
        log "Bridge '$BRIDGE' já existe — pulando criação."
    else
        log "Criando bridge '$BRIDGE'..."
        ip link add name "$BRIDGE" type bridge
    fi

    if ip addr show "$BRIDGE" | grep -q 'inet '; then
        log "AVISO: '$BRIDGE' tem IP atribuído. Removendo (deve ficar isolada, sem IP)..."
        ip addr flush dev "$BRIDGE"
    fi

    log "Subindo '$BRIDGE' (link up)..."
    ip link set "$BRIDGE" up
}

attach_to_bridge() {
    local tap="$1"
    local current_master
    current_master="$(iface_master "$tap")"

    if [[ "$current_master" == "$BRIDGE" ]]; then
        log "'$tap' já está conectada a '$BRIDGE' — pulando."
    else
        log "Conectando '$tap' à bridge '$BRIDGE'..."
        ip link set "$tap" master "$BRIDGE"
    fi
}

do_up() {
    require_root_actions up
    log "=== Montando laboratório ==="
    create_bridge
    create_tap "$TAP0"
    create_tap "$TAP1"
    attach_to_bridge "$TAP0"
    attach_to_bridge "$TAP1"
    log "=== Laboratório pronto ==="
    do_status
    cat <<EOF

Próximos passos sugeridos:
  - Capturar tráfego:        sudo tcpdump -i $BRIDGE -e -vv
  - Teste de sanidade:       ./setup_lab.sh test
  - Seu programa C deve abrir /dev/net/tun e fazer ioctl(TUNSETIFF) com
    ifr_name = "$TAP0" (ou "$TAP1") e flags IFF_TAP | IFF_NO_PI.
EOF
}

do_down() {
    require_root_actions down
    log "=== Desmontando laboratório ==="

    for tap in "$TAP0" "$TAP1"; do
        if iface_exists "$tap"; then
            log "Removendo '$tap'..."
            ip link set "$tap" down 2>/dev/null || true
            ip tuntap del dev "$tap" mode tap
        else
            log "'$tap' não existe — nada a remover."
        fi
    done

    if iface_exists "$BRIDGE"; then
        log "Removendo bridge '$BRIDGE'..."
        ip link set "$BRIDGE" down 2>/dev/null || true
        ip link delete "$BRIDGE" type bridge
    else
        log "'$BRIDGE' não existe — nada a remover."
    fi

    log "=== Laboratório desmontado ==="
}

do_status() {
    echo
    echo "--- Interfaces ---"
    for iface in "$BRIDGE" "$TAP0" "$TAP1"; do
        if iface_exists "$iface"; then
            local state master carrier carrier_label
            state="$(ip -o link show "$iface" | grep -oP '(?<=state )\S+')"
            master="$(iface_master "$iface")"
            carrier="$(cat "/sys/class/net/$iface/carrier" 2>/dev/null || echo '?')"
            case "$carrier" in
                1) carrier_label="UP (alguém tem o fd aberto)" ;;
                0) carrier_label="DOWN (ninguém tem o fd aberto — normal se nenhum programa estiver rodando)" ;;
                *) carrier_label="desconhecido" ;;
            esac
            printf '  %-6s existe   state=%-8s master=%-10s carrier=%s\n' "$iface" "$state" "${master:-(nenhum)}" "$carrier_label"
        else
            printf '  %-6s NÃO existe\n' "$iface"
        fi
    done

    echo
    echo "--- Endereços IP (esperado: nenhum 'inet' em nenhuma delas) ---"
    for iface in "$BRIDGE" "$TAP0" "$TAP1"; do
        if iface_exists "$iface"; then
            local addr
            addr="$(ip addr show "$iface" | grep 'inet ' || echo '    (sem IP — correto)')"
            printf '  %s:\n%s\n' "$iface" "$addr"
        fi
    done

    echo
    echo "--- IPv6 (esperado: desabilitado em tap0/tap1, evita ruído nas capturas) ---"
    for iface in "$TAP0" "$TAP1"; do
        if iface_exists "$iface"; then
            local v6_path="/proc/sys/net/ipv6/conf/$iface/disable_ipv6"
            local v6_status
            v6_status="$(cat "$v6_path" 2>/dev/null || echo '?')"
            if [[ "$v6_status" == "1" ]]; then
                printf '  %-6s IPv6 desabilitado (correto)\n' "$iface"
            else
                printf '  %-6s IPv6 HABILITADO (pode gerar ruído ICMPv6 nas capturas)\n' "$iface"
            fi
        fi
    done

    if iface_exists "$BRIDGE"; then
        echo
        echo "--- Portas da bridge $BRIDGE ---"
        bridge link show 2>/dev/null | grep "$BRIDGE" || echo "  (bridge utils não mostrou portas — confira com 'ip link show master $BRIDGE')"
    fi
    echo
}

do_test() {
    if ! iface_exists "$TAP0" || ! iface_exists "$TAP1"; then
        log "ERRO: laboratório não está montado. Rode './setup_lab.sh up' primeiro."
        exit 1
    fi

    # Precisa de privilégio para abrir /dev/net/tun.
    # IMPORTANTE: esta checagem vem ANTES de qualquer log de progresso,
    # porque o "exec sudo" reinicia o script do zero — logar antes disso
    # faz a mensagem aparecer duplicada (uma vez sem privilégio, outra com).
    if [[ "$(id -u)" -ne 0 ]]; then
        log "Privilégio de root necessário para o teste, reexecutando com sudo..."
        exec sudo -- "$0" test
    fi

    # -------------------------------------------------------------------
    # PASSO 1: abrir tap1 via /dev/net/tun como "listener" e MANTER ABERTO.
    #
    # Uma interface TAP só fica com "carrier" (link operacional up) quando
    # algum processo tem o file descriptor de /dev/net/tun aberto para ela.
    # Sem isso, a interface fica administrativamente UP mas operacionalmente
    # DOWN (NO-CARRIER), e a bridge descarta qualquer frame que chegue
    # por essa porta.
    #
    # Estes scripts Python usam o MESMO ioctl (TUNSETIFF / IFF_TAP) que o
    # seu programa C vai usar depois — então também servem de referência.
    #
    # Por que NÃO usamos scapy.sendp() para o envio:
    # sendp(iface="tap0") injeta o frame via AF_PACKET diretamente na
    # interface de rede do kernel. Esse caminho é DIFERENTE do caminho
    # que o seu programa C vai usar (escrever bytes no fd retornado por
    # /dev/net/tun). Na prática, um frame injetado via AF_PACKET pode não
    # ser repassado pela bridge para a porta vizinha (apareceu em tap0,
    # mas nunca em br0/tap1), enquanto escrever diretamente no fd do tun
    # é o caminho real de transmissão e É repassado pela bridge
    # corretamente. Por isso este teste escreve o frame Ethernet/ARP cru
    # direto no fd — exatamente o que seu código C fará.
    # -------------------------------------------------------------------
    local sender_script="/tmp/lab_tap_sender_$$.py"
    cat > "$sender_script" <<'PYEOF'
import fcntl
import struct
import sys

TUNSETIFF = 0x400454ca
IFF_TAP = 0x0002
IFF_NO_PI = 0x1000

ifname = sys.argv[1]

tun = open("/dev/net/tun", "r+b", buffering=0)
ifr = struct.pack("16sH", ifname.encode(), IFF_TAP | IFF_NO_PI)
fcntl.ioctl(tun, TUNSETIFF, ifr)
print("READY", flush=True)

# Monta um frame Ethernet + ARP request "à mão", em bytes puros — sem
# scapy — exatamente como seu código C fará. Isso também testa que os
# offsets/campos estão certos sem depender de nenhuma lib externa.
#
# Ethernet header (14 bytes): dst_mac(6) + src_mac(6) + ethertype(2)
dst_mac = b"\xff\xff\xff\xff\xff\xff"          # broadcast
src_mac = b"\xaa\xbb\xcc\xdd\xee\x01"
ethertype = b"\x08\x06"                        # ARP

# ARP packet (28 bytes): hw_type(2) proto_type(2) hw_len(1) proto_len(1)
# opcode(2) sender_mac(6) sender_ip(4) target_mac(6) target_ip(4)
arp = (
    b"\x00\x01"               # hardware type: Ethernet
    + b"\x08\x00"              # protocol type: IPv4
    + b"\x06"                  # hardware address length
    + b"\x04"                  # protocol address length
    + b"\x00\x01"              # opcode: request
    + src_mac                  # sender MAC
    + bytes([10, 0, 0, 1])     # sender IP: 10.0.0.1
    + b"\x00\x00\x00\x00\x00\x00"  # target MAC: unknown
    + bytes([10, 0, 0, 2])     # target IP: 10.0.0.2
)

frame = dst_mac + src_mac + ethertype + arp
written = tun.write(frame)
print(f"[sender] escreveu {written} bytes (frame ARP) em {ifname}", flush=True)
PYEOF

    local listener_script="/tmp/lab_tap_listener_$$.py"
    cat > "$listener_script" <<'PYEOF'
import fcntl
import struct
import sys

TUNSETIFF = 0x400454ca
IFF_TAP = 0x0002
IFF_NO_PI = 0x1000

ifname = sys.argv[1]

tun = open("/dev/net/tun", "r+b", buffering=0)
ifr = struct.pack("16sH", ifname.encode(), IFF_TAP | IFF_NO_PI)
fcntl.ioctl(tun, TUNSETIFF, ifr)
print("READY", flush=True)

try:
    while True:
        data = tun.read(4096)
        print(f"[listener] recebeu {len(data)} bytes em {ifname}: {data.hex()}", flush=True)
except KeyboardInterrupt:
    pass
PYEOF

    log "Abrindo '$TAP1' como listener via /dev/net/tun (levanta o carrier)..."
    python3 "$listener_script" "$TAP1" > "/tmp/lab_listener_${TAP1}.log" 2>&1 &
    local holder1_pid=$!

    # holder0_pid não existe ainda (o sender em tap0 só roda mais abaixo,
    # de forma curta). O trap referencia por nome (expansão tardia), e
    # 'kill ""' com variável vazia não falha por causa do '|| true'.
    local holder0_pid=""
    local sender_log="/tmp/lab_sender_${TAP0}.log"
    trap 'kill "$holder0_pid" "$holder1_pid" 2>/dev/null || true; rm -f "$sender_script" "$listener_script" "/tmp/lab_listener_${TAP1}.log" "$sender_log"' RETURN

    # Espera ativa até o carrier de tap1 subir (precisa de alguém com o
    # fd aberto — o listener que acabamos de lançar).
    log "Aguardando carrier subir em '$TAP1'..."
    local waited=0
    local max_wait_ms=3000
    while true; do
        if ! kill -0 "$holder1_pid" 2>/dev/null; then
            log "ERRO: processo listener de '$TAP1' morreu prematuramente. Log:"
            cat "/tmp/lab_listener_${TAP1}.log" | sed 's/^/    /'
            exit 1
        fi

        local carrier1
        carrier1="$(cat "/sys/class/net/$TAP1/carrier" 2>/dev/null || echo 0)"
        if [[ "$carrier1" == "1" ]]; then
            break
        fi

        sleep 0.05
        waited=$((waited + 50))
        if [[ "$waited" -ge "$max_wait_ms" ]]; then
            log "ERRO: carrier de '$TAP1' não subiu após ${max_wait_ms}ms."
            exit 1
        fi
    done
    log "Carrier OK em '$TAP1' (aguardado ~${waited}ms)."

    # -------------------------------------------------------------------
    # PASSO 2: roda o sender em tap0 — abre o fd, escreve o frame
    # Ethernet/ARP cru (mesmo caminho do seu futuro programa C) e
    # encerra. A bridge deve repassar o frame para tap1 enquanto ambas
    # as portas têm carrier ativo.
    # -------------------------------------------------------------------
    log "Disparando sender em '$TAP0' (escreve frame ARP cru no fd, sem scapy)..."
    python3 "$sender_script" "$TAP0" > "$sender_log" 2>&1
    log "Saída do sender:"
    sed 's/^/    /' "$sender_log"

    # Janela curta para o listener processar e logar o que recebeu.
    sleep 0.3

    log "Verificando o que '$TAP1' recebeu..."
    if grep -q "\[listener\] recebeu" "/tmp/lab_listener_${TAP1}.log" 2>/dev/null; then
        log "OK: tap1 recebeu o frame. tap0 -> br0 -> tap1 está funcionando."
        log "Detalhe:"
        sed 's/^/    /' "/tmp/lab_listener_${TAP1}.log"
    else
        log "FALHA: tap1 não recebeu nada. Verifique a topologia com './setup_lab.sh status'."
        log "Log do listener (pode estar vazio):"
        sed 's/^/    /' "/tmp/lab_listener_${TAP1}.log" 2>/dev/null || true
    fi
}

usage() {
    cat <<EOF
Uso: $0 {up|down|status|test}

  up      Cria tap0, tap1, br0 e conecta tudo (idempotente)
  down    Remove tudo (idempotente, não falha se já não existir)
  status  Mostra o estado atual do laboratório
  test    Teste de sanidade: escreve um frame ARP cru direto no fd de
          tap0 e confirma recepção em tap1 (sem dependências externas)
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

case "${1:-}" in
    up)     do_up ;;
    down)   do_down ;;
    status) do_status ;;
    test)   do_test ;;
    *)      usage; exit 1 ;;
esac