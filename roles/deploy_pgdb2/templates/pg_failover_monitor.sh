#!/bin/bash

# Конфигурационные параметры
PRIMARY_HOST="pgdb1"
PG_DATA="/var/lib/postgresql/16/main"
PROMOTE_TIMEOUT=60
CHECK_INTERVAL=5
LOCK_FILE="/tmp/pg_failover.lock"
LOG_FILE="/var/log/postgresql/failover.log"
BACKEND_SERVERS=("backend1" "backend2")
PRIMARY_IP="192.168.30.4"    # Исходный IP мастера
NEW_MASTER_IP="192.168.30.5" # IP реплики (нового мастера)
CONFIG_FILE="/opt/netbox/netbox/netbox/configuration.py"
REVERT_FLAG="/tmp/pg_failover_revert_flag"
SSH_TIMEOUT=2
SSH_OPTIONS="-o ConnectTimeout=$SSH_TIMEOUT -o StrictHostKeyChecking=no"

# Инициализация логгирования
exec > >(tee -a ${LOG_FILE}) 2>&1
mkdir -p $(dirname ${LOG_FILE})
touch ${LOG_FILE}
chown postgres:postgres ${LOG_FILE}

# Функция логирования
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a ${LOG_FILE}
}

# Функция проверки доступности сервера
check_ssh() {
    local server=$1
    if ! ssh ${SSH_OPTIONS} postgres@${server} true; then
        log "ОШИБКА: Не удалось подключиться к ${server}"
        return 1
    fi
    return 0
}

# Функция обновления конфигов на бэкендах
update_backend_configs() {
    local new_ip=$1
    local config_search="'HOST': '192.168.30.4',      # Database server"
    local config_replace="'HOST': '${new_ip}',      # Database server"
    
    log "ИНИЦИАЛИЗАЦИЯ: Начало обновления конфигурации на бэкендах (новый IP: ${new_ip})"
    
    for server in "${BACKEND_SERVERS[@]}"; do
        log "СЕРВЕР ${server}: Начало обработки"
        
        # Проверка доступности сервера
        if ! check_ssh "${server}"; then
            continue
        fi
        
        # Получаем текущие параметры файла
        local file_info=$(ssh ${SSH_OPTIONS} postgres@${server} \
            "stat -c '%U:%G %a %F' ${CONFIG_FILE} 2>&1")
        
        if [ $? -ne 0 ]; then
            log "ОШИБКА: Не удалось получить параметры файла на ${server}: ${file_info}"
            continue
        fi
        
        local file_owner=$(echo ${file_info} | awk '{print $1}')
        local file_perms=$(echo ${file_info} | awk '{print $2}')
        local file_type=$(echo ${file_info} | awk '{print $3}')
        
        log "СЕРВЕР ${server}: Текущие параметры - Владелец:${file_owner} Права:${file_perms} Тип:${file_type}"
        
        # Создаем резервную копию
        local backup_result=$(ssh ${SSH_OPTIONS} postgres@${server} \
            "sudo cp ${CONFIG_FILE} ${CONFIG_FILE}.bak && sudo chown ${file_owner} ${CONFIG_FILE}.bak")
        
        if [ $? -ne 0 ]; then
            log "ОШИБКА: Не удалось создать backup на ${server}"
            continue
        fi
        
        # Изменяем конфигурацию
        local change_result=$(ssh ${SSH_OPTIONS} postgres@${server} \
            "sudo sed -i -E 's/${PRIMARY_IP}/${NEW_MASTER_IP}/g' ${CONFIG_FILE}") #&& \
#             sudo chown ${file_owner} ${CONFIG_FILE} && \
#             sudo chmod ${file_perms} ${CONFIG_FILE}")
        
        if [ $? -ne 0 ]; then
            log "ОШИБКА: Не удалось изменить конфиг на ${server}"
            continue
        fi
        
        # Проверяем изменения
        local new_config_line=$(ssh ${SSH_OPTIONS} postgres@${server} \
            "grep -E \"${config_replace}\" ${CONFIG_FILE}")
        
        if [ -z "${new_config_line}" ]; then
            log "ОШИБКА: Конфиг не содержит новый IP на ${server}"
            continue
        fi
        
        log "СЕРВЕР ${server}: Успешно обновлено - ${new_config_line}"
        
        # Перезапуск службы
        local restart_result=$(ssh ${SSH_OPTIONS} postgres@${server} \
            "sudo systemctl restart netbox")
        
        if [ $? -eq 0 ]; then
            log "СЕРВЕР ${server}: Служба netbox успешно перезапущена"
        else
            log "ОШИБКА: Не удалось перезапустить netbox на ${server}"
        fi
        
        log "СЕРВЕР ${server}: Обработка завершена"
    done
    
    log "ФИНАЛИЗАЦИЯ: Обновление конфигурации на бэкендах завершено"
}

# Функция восстановления оригинального IP
#revert_backend_configs() {
#    log "ВОССТАНОВЛЕНИЕ: Начало возврата оригинального IP (${PRIMARY_IP})"
#    update_backend_configs "${PRIMARY_IP}"
#    if [ $? -eq 0 ]; then
#        rm -f "${REVERT_FLAG}"
#        log "ВОССТАНОВЛЕНИЕ: Успешно завершено"
#    else
#        log "ОШИБКА: Не удалось восстановить оригинальный IP"
#    fi
#}

# Функция проверки доступности мастера
check_primary() {
    if pg_isready -h ${PRIMARY_HOST} -p 5432 -t ${SSH_TIMEOUT} -q; then
        return 0
    else
        log "ПРОВЕРКА: Мастер ${PRIMARY_HOST} недоступен"
        return 1
    fi
}

# Функция перевода реплики в режим мастера
promote_if_needed() {
    if [ -f ${LOCK_FILE} ]; then
        log "ПРЕДУПРЕЖДЕНИЕ: Файл блокировки ${LOCK_FILE} существует"
        return 1
    fi

    touch ${LOCK_FILE}
    log "ИНИЦИАЛИЗАЦИЯ: Попытка перевода реплики в режим мастера"

    # Проверяем, что мы ещё реплика
    local in_recovery=$(psql -tAc "SELECT pg_is_in_recovery();")
    if [ "${in_recovery}" != "t" ]; then
        log "ПРЕДУПРЕЖДЕНИЕ: Узел уже в режиме мастера"
        rm -f ${LOCK_FILE}
        return 1
    fi

    # Пытаемся выполнить promote
    local promote_result=$(psql -tAc "SELECT pg_promote(true, ${PROMOTE_TIMEOUT});")
    if [ "${promote_result}" = "t" ]; then
        log "УСПЕХ: Реплика успешно переведена в режим мастера"
        
        # Обновляем конфиги на бэкендах
        update_backend_configs "${NEW_MASTER_IP}"
        
        # Устанавливаем флаг для возможного отката
        touch "${REVERT_FLAG}"
        
        return 0
    else
        log "ОШИБКА: Не удалось перевести реплику в режим мастера"
        rm -f ${LOCK_FILE}
        return 1
    fi
}

# Функция переконфигурации старого мастера как реплики
#reconfigure_old_primary() {
#    log "ВОССТАНОВЛЕНИЕ: Попытка переконфигурации старого мастера ${PRIMARY_HOST}"

#    if ! check_ssh "${PRIMARY_HOST}"; then
#        log "ОШИБКА: Старый мастер недоступен"
#        return 1
#    fi

    # Останавливаем PostgreSQL на старом мастере
#    local stop_result=$(ssh ${SSH_OPTIONS} postgres@${PRIMARY_HOST} \
#        "sudo systemctl stop postgresql@16-main")
    
#    if [ $? -ne 0 ]; then
#        log "ОШИБКА: Не удалось остановить PostgreSQL на старом мастере"
#        return 1
#    fi

    # Переконфигурируем как реплику
#    log "ВОССТАНОВЛЕНИЕ: Создание новой реплики из ${PRIMARY_HOST}"
#    local reconfigure_result=$(ssh ${SSH_OPTIONS} postgres@${PRIMARY_HOST} \
#        "sudo rm -rf ${PG_DATA}/* && \
#         sudo -u postgres pg_basebackup -h $(hostname) -U replicator -D ${PG_DATA} -P -R -X stream")
    
#    if [ $? -ne 0 ]; then
#        log "ОШИБКА: Не удалось создать реплику на ${PRIMARY_HOST}"
#        return 1
#    fi

    # Запускаем PostgreSQL
#    local start_result=$(ssh ${SSH_OPTIONS} postgres@${PRIMARY_HOST} \
#        "sudo systemctl start postgresql@16-main")
    
#    if [ $? -eq 0 ]; then
#        log "УСПЕХ: Старый мастер успешно переконфигурирован как реплика"
        
        # Если есть флаг отката, восстанавливаем оригинальные настройки
#        if [ -f "${REVERT_FLAG}" ]; then
#            sleep 10 # Даем время на инициализацию репликации
#            revert_backend_configs
#        fi
#        return 0
#    else
#        log "ОШИБКА: Не удалось запустить PostgreSQL на старом мастере"
#        return 1
#    fi
#}

# Основной цикл мониторинга
while true; do
    if ! check_primary; then
        promote_if_needed
    else
        # Если мастер доступен, удаляем lock file если существует
        [ -f ${LOCK_FILE} ] && rm -f ${LOCK_FILE}
        
        # Проверяем, не нужно ли восстановить оригинальный IP
#        if [ -f "${REVERT_FLAG}" ] && \
#           psql -h ${PRIMARY_HOST} -tAc "SELECT pg_is_in_recovery();" | grep -q "f"; then
#            log "ОБНАРУЖЕН: Оригинальный мастер восстановлен"
#            revert_backend_configs
#        fi
    fi
    sleep ${CHECK_INTERVAL}
done
