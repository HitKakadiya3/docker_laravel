# 1) Build PHP dependencies
FROM composer:2 AS vendor
WORKDIR /app
COPY composer.json composer.lock ./
RUN composer install --no-dev --prefer-dist --no-progress --no-interaction
COPY . ./
RUN composer dump-autoload -o

# 2) Runtime with PHP-FPM + Caddy
FROM php:8.2-fpm-alpine AS app
WORKDIR /var/www/html

# System deps
RUN apk add --no-cache bash curl icu-libs icu-data-full libpq \
    oniguruma libzip zlib

# PHP extensions
RUN apk add --no-cache icu-dev libzip-dev oniguruma-dev postgresql-dev $PHPIZE_DEPS && \
    docker-php-ext-configure intl && \
    docker-php-ext-install intl mbstring pdo pdo_pgsql zip opcache && \
    apk del $PHPIZE_DEPS icu-dev libzip-dev oniguruma-dev postgresql-dev

# Copy app
COPY --from=vendor /app /var/www/html

# Caddy for static + PHP-FPM proxy
RUN apk add --no-cache caddy

# Caddyfile
RUN printf '{\n    auto_https off\n}\n:8080 {\n    root * /var/www/html/public\n    encode zstd gzip\n    php_fastcgi localhost:9000\n    file_server\n}\n' > /etc/caddy/Caddyfile

# Permissions
RUN chown -R www-data:www-data /var/www/html/storage /var/www/html/bootstrap/cache

# Expose Caddy port
EXPOSE 8080

# Start both PHP-FPM and Caddy
CMD php-fpm -D && caddy run --config /etc/caddy/Caddyfile --adapter caddyfile

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


# ---------- Stage 3: Runtime (Nginx + PHP-FPM) ----------
FROM php:8.2-fpm-alpine AS runtime

# Install system dependencies and PHP extensions
RUN apk add --no-cache \
	nginx \
	supervisor \
	bash \
	icu-dev \
	libzip-dev \
	oniguruma-dev \
	freetype-dev \
	libjpeg-turbo-dev \
	libpng-dev \
	postgresql-dev \
	&& docker-php-ext-configure gd --with-freetype --with-jpeg \
	&& docker-php-ext-install -j$(nproc) \
		pdo \
		pdo_mysql \
		pdo_pgsql \
		mbstring \
		zip \
		gd \
		intl \
		opcache

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

# Nginx config (use here-doc to preserve $ variables)
RUN mkdir -p /run/nginx /var/log/nginx /etc/nginx/conf.d \
	&& cat > /etc/nginx/nginx.conf <<'NGINX_CONF'
events { worker_connections 1024; }
http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    sendfile        on;
    keepalive_timeout  65;
    server {
        listen 80;
        server_name _;
        root /var/www/html/public;
        index index.php index.html;
        location / {
            try_files $uri $uri/ /index.php?$query_string;
        }
        location ~ \.php$ {
            include fastcgi_params;
            fastcgi_pass 127.0.0.1:9000;
            fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
            fastcgi_param DOCUMENT_ROOT $document_root;
            fastcgi_index index.php;
        }
        location ~ /\.(?!well-known).* { deny all; }
        location ~* \.(?:css|js|jpg|jpeg|gif|png|svg|ico)$ {
            expires 7d;
            add_header Cache-Control "public, immutable";
        }
    }
}
NGINX_CONF

# Supervisor config to run php-fpm + nginx
RUN mkdir -p /etc/supervisor/conf.d \
	&& printf "[supervisord]\n" > /etc/supervisor/conf.d/supervisord.conf \
	&& printf "nodaemon=true\n\n" >> /etc/supervisor/conf.d/supervisord.conf \
	&& printf "[program:php-fpm]\ncommand=php-fpm -F\nautostart=true\nautorestart=true\npriority=5\n\n" >> /etc/supervisor/conf.d/supervisord.conf \
	&& printf "[program:nginx]\ncommand=nginx -g 'daemon off;'\nautostart=true\nautorestart=true\npriority=10\n" >> /etc/supervisor/conf.d/supervisord.conf

# Permissions for storage and cache
RUN addgroup -g 1000 -S www \
	&& adduser -u 1000 -S www -G www \
	&& chown -R www:www /var/www/html \
	&& chmod -R ug+rwx storage bootstrap/cache

EXPOSE 80

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]

