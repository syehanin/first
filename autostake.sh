#!/bin/bash
GREEN='\033[0;32m'
RED='\033[0;31m'
WITHOU_COLOR='\033[0m'
RPC=https://composable.rpc.kjnodes.com:443
SNAP_URL=https://snapshots.kjnodes.com/composable/snapshot_latest.tar.lz4
FEES=0

source $HOME/.profile
source $HOME/.bash_profile

for (( ;; )); do
    echo -e "======================== `date +"%Y-%m-%d %T"` =========================="

# Функція для відправки сповіщень в Telegram
send_telegram_notification() {
    local message=$1
    echo "send_tg: ${TIKER} ${message}"
}

# Функція для перевірки і обробки помилки AppHash
check_apphash_error() {
    end_time=$((SECONDS+60))
    while [ $SECONDS -lt $end_time ]; do
        if sudo journalctl -u ${TIKER} -n 100 --no-pager | grep AppHash; then
            send_telegram_notification "AppHash_Error"
            download_and_apply_snapshot urgent
            break
        fi
        sleep 5
    done
}



    # Перевірка стану ноди
    echo -e "${GREEN} Check refused ${WITHOU_COLOR}"
    NODE_STATUS=$(${TIKER} status 2>&1)
    if [[ ${NODE_STATUS} =~ "connection refused" ]]; then
        sudo systemctl restart ${TIKER} && sleep 60
        send_telegram_notification "ConnectionRefused"
    elif [[ ${NODE_STATUS} =~ '"catching_up":true' ]]; then
        sudo systemctl restart ${TIKER}
        check_apphash_error
    fi


    # Перевірка блоків
    echo -e "${GREEN} Check block ${WITHOU_COLOR}"
    LASTED_RPC_HEIGHT=$(curl -s $RPC/block | jq -r .result.block.header.height);
    LASTED_MY_HEIGHT=$(curl -s localhost:26657/block | jq -r .result.block.header.height)
    if [ -z "$LASTED_RPC_HEIGHT" ] || [ -z "$LASTED_MY_HEIGHT" ]; then
        send_telegram_notification "LASTED_RPC_HEIGHT: $LASTED_RPC_HEIGHT, LASTED_MY_HEIGHT: $LASTED_MY_HEIGHT"
    elif [ -n "$OLD_MY_HEIGHT" ] && [ "$LASTED_MY_HEIGHT" -eq "$OLD_MY_HEIGHT" ]; then
        echo -e "$LASTED_MY_HEIGHT == $OLD_MY_HEIGHT ${WITHOU_COLOR}"
        systemctl restart ${TIKER} && sleep 20
    elif [ $((LASTED_RPC_HEIGHT - 100)) -gt "$LASTED_MY_HEIGHT" ]; then
        echo -e "${RED} $LASTED_RPC_HEIGHT -gt $LASTED_MY_HEIGHT ${WITHOU_COLOR}"
        systemctl restart ${TIKER} && sleep 20
    else
        OLD_MY_HEIGHT=$LASTED_MY_HEIGHT
    fi

    # Забираем реварды
    echo -e "${GREEN} Get reward from Delegation ${WITHOU_COLOR}"
    ${TIKER} tx distribution withdraw-rewards --commission ${VALIDATOR} --from ${WALLET} --fees $FEES${TOKEN} -y
    sleep 60

    # Проверяем память
    echo -e "${GREEN} Check memory ${WITHOU_COLOR}"
    memory4=$(free -m | grep Mem | awk '{print $4}')
    memory7=$(free -m | grep Mem | awk '{print $7}')
    if [ $memory4 -lt "100" ] && [ $memory7 -lt "100" ]; then
        systemctl restart ${TIKER} && sleep 60
    fi

    # Перевірка диску
    DiskAvail=$(df / --output=avail -BG | grep -v Avail | tr -d 'G')
    if [[ "$DiskAvail" -lt 9 ]]; then
        if [ "$DiskAvail" -lt 1 ]; then
            send_telegram_notification "DiskAvail:${DiskAvail}"
        fi
        download_and_apply_snapshot
    fi

    # Проверяем открытый пропосал
    echo -e "${GREEN} Check proposal ${WITHOU_COLOR}"
    OPEN_PROPOSAL=$(${TIKER} q gov proposals --status VotingPeriod -o json 2>/dev/null | jq -r '.proposals[]|to_entries[]|select(.key|contains("id"))|.value')
    if [[ -n "$OPEN_PROPOSAL" ]] && [[ "${OPEN_PROPOSAL}" != "${PREV_PROPOSAL}" ]]; then
        PREV_PROPOSAL=$OPEN_PROPOSAL
        echo "OPEN_PROPOSAL=${OPEN_PROPOSAL}, PREV_PROPOSAL=${PREV_PROPOSAL}" && sleep 10
    fi

    # Делегируем в себя
    echo -e "${GREEN} Staking from my wallet ${WITHOU_COLOR}"
    BAL=$(${TIKER} q bank balances ${ADDRESS} -o json | jq -r --arg TOKEN $TOKEN '.balances[] | select(.denom==$TOKEN) | .amount');
    if (( BAL > 3000000 )); then
        BAL=$((BAL-2000000));
        echo -e "${GREEN} Balance for staking: ${BAL} $TOKEN ${WITHOU_COLOR}"
        ${TIKER} tx staking delegate ${VALIDATOR} ${BAL}${TOKEN} --from ${WALLET} --fees $FEES${TOKEN} -y
    else
        echo -e "${RED} Not enough for staking: ${BAL} $TOKEN ${WITHOU_COLOR}"
    fi

    for i in {3600..0}; do
        echo -ne "* sleep for: $i   \r";
        sleep 1
    done
done
