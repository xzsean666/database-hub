#!/usr/bin/env bash
# ==============================================================================
# Database Hub - Summary & Presentation Module
# ==============================================================================

print_connection_summary() {
    local host="$1"
    local env_file="$2"
    local selected_dbs="${3:-all}"

    # Read variables from env file
    local pg_port pg_user pg_pass pg_db
    local my_port my_root_pass my_user my_pass my_db
    local mongo_port mongo_user mongo_pass mongo_db
    local redis_port redis_pass

    pg_port=$(grep -E '^POSTGRES_PORT=' "$env_file" 2>/dev/null | cut -d= -f2- || echo "5432")
    pg_port="${pg_port:-5432}"
    pg_user=$(grep -E '^POSTGRES_USER=' "$env_file" 2>/dev/null | cut -d= -f2- || echo "postgres")
    pg_user="${pg_user:-postgres}"
    pg_pass=$(grep -E '^POSTGRES_PASSWORD=' "$env_file" 2>/dev/null | cut -d= -f2- || echo "postgres_secure_pass")
    pg_pass="${pg_pass:-postgres_secure_pass}"
    pg_db=$(grep -E '^POSTGRES_DB=' "$env_file" 2>/dev/null | cut -d= -f2- || echo "app_db")
    pg_db="${pg_db:-app_db}"

    my_port=$(grep -E '^MYSQL_PORT=' "$env_file" 2>/dev/null | cut -d= -f2- || echo "3306")
    my_port="${my_port:-3306}"
    my_root_pass=$(grep -E '^MYSQL_ROOT_PASSWORD=' "$env_file" 2>/dev/null | cut -d= -f2- || echo "mysql_root_secure_pass")
    my_root_pass="${my_root_pass:-mysql_root_secure_pass}"
    my_user=$(grep -E '^MYSQL_USER=' "$env_file" 2>/dev/null | cut -d= -f2- || echo "app_user")
    my_user="${my_user:-app_user}"
    my_pass=$(grep -E '^MYSQL_PASSWORD=' "$env_file" 2>/dev/null | cut -d= -f2- || echo "mysql_user_secure_pass")
    my_pass="${my_pass:-mysql_user_secure_pass}"
    my_db=$(grep -E '^MYSQL_DATABASE=' "$env_file" 2>/dev/null | cut -d= -f2- || echo "app_db")
    my_db="${my_db:-app_db}"

    mongo_port=$(grep -E '^MONGO_PORT=' "$env_file" 2>/dev/null | cut -d= -f2- || echo "27017")
    mongo_port="${mongo_port:-27017}"
    mongo_user=$(grep -E '^MONGO_INITDB_ROOT_USERNAME=' "$env_file" 2>/dev/null | cut -d= -f2- || echo "root")
    mongo_user="${mongo_user:-root}"
    mongo_pass=$(grep -E '^MONGO_INITDB_ROOT_PASSWORD=' "$env_file" 2>/dev/null | cut -d= -f2- || echo "mongo_root_secure_pass")
    mongo_pass="${mongo_pass:-mongo_root_secure_pass}"
    mongo_db=$(grep -E '^MONGO_INITDB_DATABASE=' "$env_file" 2>/dev/null | cut -d= -f2- || echo "app_db")
    mongo_db="${mongo_db:-app_db}"

    redis_port=$(grep -E '^REDIS_PORT=' "$env_file" 2>/dev/null | cut -d= -f2- || echo "6379")
    redis_port="${redis_port:-6379}"
    redis_pass=$(grep -E '^REDIS_PASSWORD=' "$env_file" 2>/dev/null | cut -d= -f2- || echo "redis_secure_pass")
    redis_pass="${redis_pass:-redis_secure_pass}"

    local inst_id
    inst_id=$(grep -E '^INSTANCE_ID=' "$env_file" 2>/dev/null | cut -d= -f2- || echo "database-hub")
    inst_id="${inst_id:-database-hub}"

    echo ""
    echo -e "\033[0;32m\033[1m========================================================================\033[0m"
    echo -e "\033[0;32m\033[1m               DATABASE DEPLOYMENT SUMMARY & ACCESS INFO                \033[0m"
    echo -e "\033[0;32m\033[1m========================================================================\033[0m"
    echo -e "Host: \033[0;36m${host}\033[0m  |  Instance ID: \033[0;36m${inst_id}\033[0m\n"

    if [[ "$selected_dbs" == *"postgres"* ]] || [ "$selected_dbs" = "all" ]; then
        echo -e "\033[1m[PostgreSQL 18]\033[0m"
        echo -e "  Port:      ${pg_port}"
        echo -e "  Database:  ${pg_db}"
        echo -e "  User:      ${pg_user}"
        echo -e "  Password:  ${pg_pass}"
        echo -e "  URI:       \033[0;36mpostgresql://${pg_user}:${pg_pass}@${host}:${pg_port}/${pg_db}\033[0m"
        echo -e "  CLI:       psql -h ${host} -p ${pg_port} -U ${pg_user} -d ${pg_db}\n"
    fi

    if [[ "$selected_dbs" == *"mysql"* ]] || [ "$selected_dbs" = "all" ]; then
        echo -e "\033[1m[MySQL 8.4 LTS]\033[0m"
        echo -e "  Port:      ${my_port}"
        echo -e "  Database:  ${my_db}"
        echo -e "  User:      ${my_user} (or root)"
        echo -e "  Password:  ${my_pass} (root: ${my_root_pass})"
        echo -e "  URI:       \033[0;36mmysql://${my_user}:${my_pass}@${host}:${my_port}/${my_db}\033[0m"
        echo -e "  CLI:       mysql -h ${host} -P ${my_port} -u ${my_user} -p\n"
    fi

    if [[ "$selected_dbs" == *"mongo"* ]] || [ "$selected_dbs" = "all" ]; then
        echo -e "\033[1m[MongoDB 8.0]\033[0m"
        echo -e "  Port:      ${mongo_port}"
        echo -e "  Database:  ${mongo_db}"
        echo -e "  User:      ${mongo_user}"
        echo -e "  Password:  ${mongo_pass}"
        echo -e "  URI:       \033[0;36mmongodb://${mongo_user}:${mongo_pass}@${host}:${mongo_port}/${mongo_db}?authSource=admin\033[0m"
        echo -e "  CLI:       mongosh \"mongodb://${mongo_user}:${mongo_pass}@${host}:${mongo_port}/${mongo_db}?authSource=admin\"\n"
    fi

    if [[ "$selected_dbs" == *"redis"* ]] || [ "$selected_dbs" = "all" ]; then
        echo -e "\033[1m[Redis 7.4]\033[0m"
        echo -e "  Port:      ${redis_port}"
        echo -e "  Password:  ${redis_pass}"
        echo -e "  URI:       \033[0;36mredis://:${redis_pass}@${host}:${redis_port}\033[0m"
        echo -e "  CLI:       redis-cli -h ${host} -p ${redis_port} -a ${redis_pass}\n"
    fi
    echo -e "\033[0;32m========================================================================\033[0m"
}
