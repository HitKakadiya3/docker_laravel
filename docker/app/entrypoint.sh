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

# Ensure APP_URL and DB settings are set from container env ONLY if provided; otherwise preserve existing .env
if ! grep -q '^APP_URL=' .env; then
  echo "APP_URL=${APP_URL:-http://localhost:8080}" >> .env
else
  set_env_var_if_provided APP_URL "${APP_URL}"
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

# Install dependencies when bind-mounted without vendor
if [ ! -d vendor ]; then
  composer install --no-interaction --prefer-dist
fi

# Generate app key if missing
if ! grep -q "APP_KEY=" .env 2>/dev/null || grep -q "^APP_KEY=\s*$" .env; then
  php artisan key:generate --force
fi

php artisan config:clear || true
php artisan cache:clear || true

# Optionally run database migrations on container start
if [ "${MIGRATE_ON_START:-false}" = "true" ]; then
  echo "Running database migrations (MIGRATE_ON_START=true)"
  # If database cache store is configured, ensure cache table migration exists
  if php -r 'exit(getenv("CACHE_STORE")==="database"?0:1);'; then
    echo "CACHE_STORE=database detected; ensuring cache table migration exists"
    php artisan cache:table || true
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

exec "$@"


