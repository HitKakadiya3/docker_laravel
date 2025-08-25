#!/usr/bin/env sh
set -e

# Default PORT if not provided by Render
: "${PORT:=10000}"

# Prepare Laravel
php artisan key:generate --force || true
php artisan storage:link || true
php artisan migrate --force || true

# Cache configuration for performance
php artisan config:cache || true
php artisan route:cache || true
php artisan view:cache || true

echo "Starting Laravel on 0.0.0.0:${PORT}"
exec php -S 0.0.0.0:"${PORT}" -t public public/index.php


