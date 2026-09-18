#!/bin/bash

# Gestor de Swap
# Versão: 2.3
# Xubuntu Minimal
# Kernel de referência: 6.17.0-14-generic

set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

readonly SWAPFILE_PATH="/swapfile"
readonly MIN_SWAP_SIZE=1
readonly MAX_SWAP_SIZE=32

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    case "$level" in
        INFO)
            echo -e "${BLUE}[INFO]${NC} $timestamp: $message"
            ;;
        WARN)
            echo -e "${YELLOW}[WARN]${NC} $timestamp: $message"
            ;;
        ERROR)
            echo -e "${RED}[ERROR]${NC} $timestamp: $message" >&2
            ;;
        SUCCESS)
            echo -e "${GREEN}[SUCCESS]${NC} $timestamp: $message"
            ;;
    esac
}

check_privileges() {
    if [[ $EUID -ne 0 ]]; then
        log "ERROR" "Este script precisa ser executado como root (sudo)."
        exit 1
    fi
}

check_disk_space() {
    local required_size_gb="$1"
    local available_space_gb

    available_space_gb=$(df / | awk 'NR==2 {print int($4/1024/1024)}')

    if [[ $available_space_gb -lt $((required_size_gb + 1)) ]]; then
        log "ERROR" "Espaço insuficiente. Necessário: ${required_size_gb}GB + 1GB livre. Disponível: ${available_space_gb}GB"
        return 1
    fi

    return 0
}

show_swap_status() {
    echo -e "\n${BLUE}════════════════════════════════════════${NC}"
    echo -e "${BLUE}           STATUS DA SWAP ATUAL          ${NC}"
    echo -e "${BLUE}════════════════════════════════════════${NC}"

    if swapon --show=NAME,SIZE,USED,PRIO,TYPE --noheadings | grep -q .; then
        echo -e "\n${GREEN}Dispositivos de swap ativos:${NC}"
        swapon --show=NAME,SIZE,USED,PRIO,TYPE

        echo -e "\n${BLUE}Uso da memória:${NC}"
        free -h | grep -E "^(Mem|Swap):"

        local swappiness
        swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo "N/A")

        echo -e "\nSwappiness atual: ${swappiness}"
    else
        echo -e "\n${YELLOW}Nenhuma swap ativa no momento.${NC}"
        echo -e "\n${BLUE}Uso da memória:${NC}"
        free -h | grep "^Mem:"
    fi

    if [[ -f "$SWAPFILE_PATH" ]]; then
        local swap_size
        swap_size=$(du -h "$SWAPFILE_PATH" 2>/dev/null | cut -f1)
        echo -e "\nArquivo de swap encontrado: $SWAPFILE_PATH (${swap_size})"
    fi

    echo -e "${BLUE}════════════════════════════════════════${NC}\n"
}

confirm_action() {
    local prompt="$1"
    local response

    while true; do
        read -r -p "$prompt (s/N): " response

        case "${response,,}" in
            s|sim|y|yes)
                return 0
                ;;
            n|não|nao|no|"")
                return 1
                ;;
            *)
                echo "Responda 's' ou 'n'."
                ;;
        esac
    done
}

clear_swap() {
    log "INFO" "Iniciando limpeza da swap..."

    local swap_devices
    swap_devices=$(swapon --show=NAME --noheadings)

    if [[ -z "$swap_devices" ]]; then
        log "WARN" "Nenhuma swap ativa."
        return 0
    fi

    echo -e "\n${YELLOW}⚠ A swap ativa será temporariamente desativada.${NC}"

    if ! confirm_action "Deseja continuar?"; then
        log "INFO" "Operação cancelada."
        return 0
    fi

    log "INFO" "Desativando as swaps atualmente ativas..."

    while IFS= read -r swap_device; do
        [[ -z "$swap_device" ]] && continue

        log "INFO" "Desativando: $swap_device"

        if ! swapoff "$swap_device"; then
            log "ERROR" "Falha ao desativar: $swap_device"
            return 1
        fi
    done < <(printf '%s\n' "$swap_devices")

    log "SUCCESS" "Swap desativada."

    log "INFO" "Reativando somente as mesmas áreas..."

    while IFS= read -r swap_device; do
        [[ -z "$swap_device" ]] && continue

        log "INFO" "Reativando: $swap_device"

        if ! swapon "$swap_device"; then
            log "ERROR" "Falha ao reativar: $swap_device"
            return 1
        fi
    done < <(printf '%s\n' "$swap_devices")

    log "SUCCESS" "Swap limpa e reativada."

    echo
    swapon --show
}

validate_swap_size() {
    local size_input="$1"
    local size_num
    local size_unit
    local size_gb

    if [[ $size_input =~ ^([0-9]+)([GgMm]?)$ ]]; then
        size_num="${BASH_REMATCH[1]}"
        size_unit="${BASH_REMATCH[2],,}"
    else
        log "ERROR" "Formato inválido. Use: 4G ou 512M"
        return 1
    fi

    case "$size_unit" in
        g|"")
            size_gb=$size_num
            ;;
        m)
            size_gb=$((size_num / 1024))
            ;;
        *)
            log "ERROR" "Unidade inválida."
            return 1
            ;;
    esac

    if [[ $size_gb -lt $MIN_SWAP_SIZE ]]; then
        log "ERROR" "Tamanho mínimo: ${MIN_SWAP_SIZE}G"
        return 1
    fi

    if [[ $size_gb -gt $MAX_SWAP_SIZE ]]; then
        log "ERROR" "Tamanho máximo: ${MAX_SWAP_SIZE}G"
        return 1
    fi

    return 0
}

backup_swap_config() {
    local backup_file="/tmp/swap_backup_$(date +%Y%m%d_%H%M%S)"

    {
        echo "# Backup da configuração de swap - $(date)"
        swapon --show 2>/dev/null || true
        grep swap /etc/fstab 2>/dev/null || true
    } > "$backup_file"

    log "INFO" "Backup salvo em: $backup_file"
}

resize_swap() {
    log "INFO" "Redimensionamento da swap..."

    echo
    echo -e "${BLUE}Redimensionamento da Swap${NC}"
    echo "  • Até 2GB RAM: 2x RAM"
    echo "  • 2-8GB RAM: igual à RAM"
    echo "  • Mais de 8GB RAM: 4-8GB"

    local new_size

    while true; do
        read -r -p "Novo tamanho da swap (ex: 4G, 512M): " new_size

        if validate_swap_size "$new_size"; then
            break
        fi
    done

    local size_gb

    if [[ $new_size =~ ^([0-9]+)[Gg]?$ ]]; then
        size_gb="${BASH_REMATCH[1]}"
    elif [[ $new_size =~ ^([0-9]+)[Mm]$ ]]; then
        size_gb=$((BASH_REMATCH[1] / 1024 + 1))
    fi

    if ! check_disk_space "$size_gb"; then
        return 1
    fi

    echo
    echo -e "${YELLOW}⚠ A swap atual será removida e recriada.${NC}"

    if ! confirm_action "Confirma o redimensionamento para $new_size?"; then
        log "INFO" "Cancelado."
        return 0
    fi

    backup_swap_config

    swapoff -a 2>/dev/null || true

    if [[ -f "$SWAPFILE_PATH" ]]; then
        rm -f "$SWAPFILE_PATH"
    fi

    log "INFO" "Criando novo arquivo swap de $new_size..."

    if command -v fallocate >/dev/null 2>&1; then
        if ! fallocate -l "$new_size" "$SWAPFILE_PATH"; then
            create_swap_with_dd "$new_size"
        fi
    else
        create_swap_with_dd "$new_size"
    fi

    chmod 600 "$SWAPFILE_PATH"
    mkswap "$SWAPFILE_PATH" >/dev/null
    swapon "$SWAPFILE_PATH"

    log "SUCCESS" "Nova swap de $new_size criada e ativada."

    log "INFO" "Configurando /etc/fstab..."

    if grep -qF "$SWAPFILE_PATH" /etc/fstab 2>/dev/null; then
        sed -i.bak "\|$SWAPFILE_PATH|c\\$SWAPFILE_PATH none swap sw 0 0" /etc/fstab
    else
        echo "$SWAPFILE_PATH none swap sw 0 0" >> /etc/fstab
    fi

    log "SUCCESS" "Configuração do /etc/fstab atualizada."
}

create_swap_with_dd() {
    local size="$1"

    dd if=/dev/zero \
       of="$SWAPFILE_PATH" \
       bs=1M \
       count="$(convert_to_mb "$size")" \
       status=progress

    log "SUCCESS" "Swap criada com dd."
}

convert_to_mb() {
    local size="$1"

    if [[ $size =~ ^([0-9]+)[Gg]?$ ]]; then
        echo $((BASH_REMATCH[1] * 1024))
    elif [[ $size =~ ^([0-9]+)[Mm]$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        return 1
    fi
}

adjust_swappiness() {
    local current_swappiness
    current_swappiness=$(cat /proc/sys/vm/swappiness)

    echo
    echo -e "${BLUE}Ajuste do Swappiness${NC}"
    echo "Swappiness atual: $current_swappiness"

    local new_swappiness

    read -r -p "Novo valor (0-100) ou Enter para manter: " new_swappiness

    if [[ -z "$new_swappiness" ]]; then
        log "INFO" "Swappiness mantido."
        return 0
    fi

    if [[ "$new_swappiness" =~ ^[0-9]+$ ]] &&
       [[ $new_swappiness -ge 0 ]] &&
       [[ $new_swappiness -le 100 ]]; then

        if confirm_action "Confirmar mudança para $new_swappiness?"; then
            echo "$new_swappiness" > /proc/sys/vm/swappiness
            log "SUCCESS" "Swappiness alterado para $new_swappiness."
        fi
    else
        log "ERROR" "Valor inválido. Use 0-100."
    fi
}

show_menu() {
    clear

    echo -e "${BLUE}"
    echo "╔════════════════════════════════════════╗"
    echo "║           GESTOR DE SWAP v2.3          ║"
    echo "╚════════════════════════════════════════╝"
    echo -e "${NC}"

    show_swap_status

    echo -e "${BLUE}Opções:${NC}"
    echo "  1. 🧹 Limpar Swap"
    echo "  2. 📏 Redimensionar Swap"
    echo "  3. ⚙  Ajustar Swappiness"
    echo "  4. 🔄 Atualizar Status"
    echo "  5. ❌ Sair"
}

main() {
    check_privileges

    log "INFO" "Iniciando Gestor de Swap..."

    while true; do
        show_menu

        read -r -p "Escolha uma opção (1-5): " option

        case "$option" in
            1)
                clear_swap
                read -r -p "Pressione Enter para continuar..."
                ;;
            2)
                resize_swap
                read -r -p "Pressione Enter para continuar..."
                ;;
            3)
                adjust_swappiness
                read -r -p "Pressione Enter para continuar..."
                ;;
            4)
                log "INFO" "Atualizando status..."
                sleep 1
                ;;
            5)
                log "INFO" "Saindo..."
                exit 0
                ;;
            *)
                log "WARN" "Opção inválida. Escolha 1-5."
                sleep 2
                ;;
        esac
    done
}

trap 'log "WARN" "Script interrompido."; exit 130' INT TERM

main "$@"
