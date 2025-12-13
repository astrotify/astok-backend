#!/bin/bash
set -e

# This script creates multiple databases on the same PostgreSQL server
# It runs automatically when the PostgreSQL container starts for the first time

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    -- Create auth database
    SELECT 'CREATE DATABASE authdb'
    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'authdb')\gexec

    -- Create order database  
    SELECT 'CREATE DATABASE orderdb'
    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'orderdb')\gexec

    -- Create notification database (for future)
    SELECT 'CREATE DATABASE notificationdb'
    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'notificationdb')\gexec

    -- Create inventory database (for future)
    SELECT 'CREATE DATABASE inventorydb'
    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'inventorydb')\gexec

    -- Grant privileges
    GRANT ALL PRIVILEGES ON DATABASE authdb TO $POSTGRES_USER;
    GRANT ALL PRIVILEGES ON DATABASE orderdb TO $POSTGRES_USER;
    GRANT ALL PRIVILEGES ON DATABASE notificationdb TO $POSTGRES_USER;
    GRANT ALL PRIVILEGES ON DATABASE inventorydb TO $POSTGRES_USER;
EOSQL

echo "✅ All databases created successfully!"
