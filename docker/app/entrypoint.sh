#!/usr/bin/env bash
set -euo pipefail

cd /var/www

# Ensure permissions for Laravel writable dirs
chown -R www-data:www-data storage bootstrap/cache || true
chmod -R ug+rwx storage bootstrap/cache || true

# Create .env if missing
if [ ! -f .env ]; then
  if [ -f .env.example ]; then
    cp .env.example .env
  else
    touch .env
  fi
fi

# Helper to set or update a key in .env only when a non-empty ENV var is provided
set_env_var_if_provided() {
  local key="$1"
  local value="$2"
  if [ -n "${value}" ]; then
    if grep -q "^${key}=" .env; then
      sed -i "s#^${key}=.*#${key}=${value}#" .env
    else
      echo "${key}=${value}" >> .env
    fi
  fi
}

# Set PORT for Laravel (useful for built-in server)
if ! grep -q '^PORT=' .env; then
  echo "PORT=${PORT:-8080}" >> .env
else
  set_env_var_if_provided PORT "${PORT}"
fi

if ! grep -q '^DB_CONNECTION=' .env; then
  echo "DB_CONNECTION=${DB_CONNECTION:-mysql}" >> .env
else
  set_env_var_if_provided DB_CONNECTION "${DB_CONNECTION}"
fi

set_env_var_if_provided DB_HOST "${DB_HOST}"
set_env_var_if_provided DB_PORT "${DB_PORT}"
set_env_var_if_provided DB_DATABASE "${DB_DATABASE}"
set_env_var_if_provided DB_USERNAME "${DB_USERNAME}"
set_env_var_if_provided DB_PASSWORD "${DB_PASSWORD}"

if ! grep -q '^CACHE_DRIVER=' .env; then
  echo "CACHE_DRIVER=${CACHE_DRIVER:-file}" >> .env
else
  set_env_var_if_provided CACHE_DRIVER "${CACHE_DRIVER}"
fi

# Install dependencies when bind-mounted without vendor
if [ ! -d vendor ]; then
  composer install --no-interaction --prefer-dist
fi

# Generate app key if missing
if ! grep -q "APP_KEY=" .env 2>/dev/null || grep -q "^APP_KEY=\s*$" .env; then
  php artisan key:generate --force
fi

php artisan config:clear || true
# php artisan cache:clear || true  # Commented out - cache table may not exist yet during initial deployment

# Clear file-based cache if that's what we're using
if [ -n "${CACHE_STORE+x}" ] && php -r 'exit(getenv("CACHE_STORE")==="file"?0:1);'; then
  echo "CACHE_STORE=file detected; clearing file-based cache..."
  # Test if cache directories are writable
  if [ -w "storage/framework/cache/data" ]; then
    echo "Cache directory is writable, clearing cache..."
    php artisan cache:clear || true
  else
    echo "Warning: Cache directory is not writable"
    ls -la storage/framework/cache/ || true
  fi
fi

# Clear file-based sessions if that's what we're using
if [ -n "${SESSION_DRIVER+x}" ] && php -r 'exit(getenv("SESSION_DRIVER")==="file"?0:1);'; then
  echo "SESSION_DRIVER=file detected; clearing file-based sessions..."
  if [ -w "storage/framework/sessions" ]; then
    echo "Sessions directory is writable, clearing sessions..."
    php artisan session:table || true
  else
    echo "Warning: Sessions directory is not writable"
    ls -la storage/framework/sessions/ || true
  fi
fi

# Optionally run database migrations on container start
if [ "${MIGRATE_ON_START:-false}" = "true" ]; then
  echo "Running database migrations (MIGRATE_ON_START=true)"
  # If database cache store is configured, ensure cache table migration exists
  if [ -n "${CACHE_STORE+x}" ] && php -r 'exit(getenv("CACHE_STORE")==="database"?0:1);'; then
    echo "CACHE_STORE=database detected; ensuring cache table migration exists"
    php artisan cache:table || true
  fi
  
  # If database session driver is configured, ensure sessions table migration exists
  if php -r 'exit(getenv("SESSION_DRIVER")==="database"?0:1);'; then
    echo "SESSION_DRIVER=database detected; ensuring sessions table migration exists"
    php artisan session:table || true
  fi
  
  attempts=0
  max_attempts=${MIGRATE_MAX_ATTEMPTS:-20}
  sleep_seconds=${MIGRATE_RETRY_SECONDS:-3}
  until php artisan migrate --force; do
    attempts=$((attempts+1))
    if [ "$attempts" -ge "$max_attempts" ]; then
      echo "Migrations failed after $attempts attempts"
      break
    fi
    echo "Migration attempt $attempts failed. Retrying in ${sleep_seconds}s..."
    sleep "$sleep_seconds"
  done
fi

# Create storage symlink if missing
if [ ! -L public/storage ]; then
  php artisan storage:link || true
fi

# Create necessary cache directories for file-based caching
mkdir -p storage/framework/cache/data || true
mkdir -p storage/framework/sessions || true
mkdir -p storage/framework/views || true
mkdir -p storage/framework/testing || true
chown -R www-data:www-data storage/framework || true
chmod -R ug+rwx storage/framework || true

# If this is the main process (not a command), start the web server
if [ "$1" = "php-fpm" ] || [ "$1" = "php" ]; then
  echo "Starting Laravel web server on port ${PORT:-8080}..."
  exec php -S 0.0.0.0:${PORT:-8080} -t public public/index.php
fi

exec "$@"

# #!/bin/bash
# set -e

# # Wait for database if needed
# if [ ! -z "$DATABASE_URL" ]; then
#     echo "Waiting for database..."
#     /usr/bin/wait-for-it.sh ${DATABASE_HOST:-database}:${DATABASE_PORT:-5432} -t 60
# fi

# # Clear config cache
# php artisan config:clear

# # Run migrations
# php artisan migrate --force

# # Start the application
# exec "$@"


