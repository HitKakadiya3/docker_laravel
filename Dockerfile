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
	gettext \
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

# Nginx config template (runtime PORT substitution via envsubst)
RUN mkdir -p /run/nginx /var/log/nginx /etc/nginx/conf.d \
	&& cat > /etc/nginx/nginx.conf.template <<'NGINX_CONF'
events { worker_connections 1024; }
http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    sendfile        on;
    keepalive_timeout  65;
    server {
        listen ${PORT};
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

# Render provides PORT. Default to 8080 locally if not set.
ENV PORT=8080

# Generate nginx.conf from template with runtime PORT and start processes
CMD sh -c "envsubst '\$PORT' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf && exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf"

