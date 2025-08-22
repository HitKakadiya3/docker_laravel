# ---------- Stage 1: Frontend build (Vite) ----------
FROM node:20-alpine AS frontend

WORKDIR /app

# Install deps using lockfile for reproducible builds
COPY package.json package-lock.json ./
RUN npm ci

# Copy only what Vite needs and ensure out dir exists
COPY resources ./resources
COPY vite.config.ts ./vite.config.ts
RUN mkdir -p public

# Build assets (outputs to public/build via laravel-vite-plugin)
RUN npm run build

# ---------- Stage 2: Composer vendor (no dev, no scripts) ----------
FROM composer:2 AS vendor

WORKDIR /app
COPY composer.json composer.lock ./
RUN composer install --prefer-dist --no-interaction --no-scripts --no-progress

# ---------- Stage 3: Runtime (PHP + built-in server) ----------
FROM php:8.2-cli-alpine AS runtime

# Install system dependencies and PHP extensions
RUN apk add --no-cache \
	bash \
	icu-dev \
	libzip-dev \
	oniguruma-dev \
	freetype-dev \
	libjpeg-turbo-dev \
	libpng-dev \
	postgresql-dev \
	$PHPIZE_DEPS \
	&& docker-php-ext-configure gd --with-freetype --with-jpeg \
	&& docker-php-ext-install -j$(nproc) \
		pdo \
		pdo_mysql \
		pdo_pgsql \
		mbstring \
		zip \
		gd \
		intl \
		opcache \
	&& apk del $PHPIZE_DEPS

ENV COMPOSER_ALLOW_SUPERUSER=1 \
	PHP_OPCACHE_VALIDATE_TIMESTAMPS=0 \
	PHP_OPCACHE_MAX_ACCELERATED_FILES=30000 \
	PHP_OPCACHE_MEMORY_CONSUMPTION=128

# Working directory
WORKDIR /var/www/html

# Copy app code
COPY . .

# Copy vendor from composer stage and built assets from node stage
COPY --from=vendor /app/vendor ./vendor
COPY --from=frontend /app/public/build ./public/build

# Minimal php.ini (production oriented)
RUN printf "\
opcache.enable=1\n\
opcache.enable_cli=1\n\
opcache.memory_consumption=${PHP_OPCACHE_MEMORY_CONSUMPTION}\n\
opcache.max_accelerated_files=${PHP_OPCACHE_MAX_ACCELERATED_FILES}\n\
opcache.validate_timestamps=${PHP_OPCACHE_VALIDATE_TIMESTAMPS}\n\
memory_limit=256M\n\
upload_max_filesize=50M\n\
post_max_size=50M\n\
display_errors=0\n\
log_errors=1\n\
" > /usr/local/etc/php/conf.d/app.ini

# Permissions for storage and cache
RUN addgroup -g 1000 -S www \
	&& adduser -u 1000 -S www -G www \
	&& chown -R www:www /var/www/html \
	&& chmod -R ug+rwx storage bootstrap/cache

# Render provides PORT. Default to 8080 locally if not set.
ENV PORT=8080

# Expose the port
EXPOSE 8080

# Start PHP's built-in server (more reliable for debugging)
CMD php -S 0.0.0.0:$PORT -t public public/index.php 

