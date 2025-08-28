# ============================
# Stage 1 — Frontend build (Vite)
# ============================
FROM node:20-alpine AS frontend
WORKDIR /app

# Install deps
COPY package*.json ./
RUN npm ci

# Copy all source files needed for Vite
COPY resources ./resources
COPY vite.config.* tailwind.config.* postcss.config.* ./
COPY public ./public

# Build assets (outputs to public/build via laravel-vite-plugin)
RUN npm run build

# ============================
# Stage 2 — Composer vendor
# ============================
FROM composer:2 AS vendor
WORKDIR /app
COPY composer.json composer.lock ./
COPY . . 
RUN composer install --optimize-autoloader --no-interaction

# ============================
# Stage 3 — Final PHP Runtime
# ============================
FROM php:8.2-cli

# Install system dependencies
RUN apt-get update && apt-get install -y \
    git unzip dos2unix libpng-dev libjpeg62-turbo-dev libfreetype6-dev libonig-dev libxml2-dev zip libzip-dev postgresql-client libpq-dev \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) pdo_mysql pdo_pgsql mbstring bcmath gd exif pcntl zip

# Configure PHP
RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini" \
    && sed -i 's/memory_limit = 128M/memory_limit = 512M/g' "$PHP_INI_DIR/php.ini" \
    && sed -i 's/max_execution_time = 30/max_execution_time = 120/g' "$PHP_INI_DIR/php.ini"

# Install Composer runtime
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# Copy entrypoint
COPY docker/app/entrypoint.sh /usr/local/bin/app-entrypoint
RUN dos2unix /usr/local/bin/app-entrypoint || true && chmod +x /usr/local/bin/app-entrypoint

WORKDIR /var/www

# Copy app source
COPY . .

# Copy vendor from composer stage
COPY --from=vendor /app/vendor ./vendor

# Copy built Vite assets from frontend stage
COPY --from=frontend /app/public/build ./public/build

# Remove the key generation command as it will be handled by docker-compose
# Ensure storage directories exist and are writable
RUN mkdir -p /var/www/storage/framework/cache/data /var/www/storage/framework/sessions

# Fix permissions
RUN chown -R www-data:www-data /var/www/storage /var/www/bootstrap/cache \
    && chmod -R 775 /var/www/storage /var/www/bootstrap/cache

# Render provides PORT (default 8080)
ENV PORT=8080
EXPOSE $PORT

ENTRYPOINT ["/usr/local/bin/app-entrypoint"]
CMD ["php", "-S", "0.0.0.0:8080", "-t", "public"]

# Render provides PORT (default 8080)
ENV PORT=8080
EXPOSE $PORT

ENTRYPOINT ["/usr/local/bin/app-entrypoint"]
CMD ["php", "-S", "0.0.0.0:8080", "-t", "public"]
