FROM debian:stable AS builder
MAINTAINER "Cédric Verstraeten" <hello@cedric.ws>

ARG APP_ENV=master
ENV APP_ENV ${APP_ENV}
ARG PHP_VERSION=7.1
ARG FFMPEG_VERSION=3.1

#################################
# Surpress Upstart errors/warning

RUN dpkg-divert --local --rename --add /sbin/initctl
RUN ln -sf /bin/true /sbin/initctl

#############################################
# Let the container know that there is no tty

ENV DEBIAN_FRONTEND noninteractive

#########################################
# Update base image
# Add sources for latest nginx and cmake
# Install software requirements

RUN apt-get update && apt-get install -y apt-transport-https wget lsb-release && \
    wget -O /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg && \
    echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list && \
    apt -y update && \
    apt -y install software-properties-common libssl-dev git supervisor curl \
    subversion libcurl4-openssl-dev cmake dh-autoreconf autotools-dev autoconf automake gcc g++ \
    build-essential libtool make nasm zlib1g-dev tar apt-transport-https \
    ca-certificates wget nginx php${PHP_VERSION}-cli php${PHP_VERSION}-gd php${PHP_VERSION}-mcrypt php${PHP_VERSION}-curl \
    php${PHP_VERSION}-mbstring php${PHP_VERSION}-dom php${PHP_VERSION}-zip php${PHP_VERSION}-fpm pwgen && \
    curl -sL https://deb.nodesource.com/setup_9.x | bash - && apt-get install -y nodejs npm

RUN wget http://www.nasm.us/pub/nasm/releasebuilds/2.14.02/nasm-2.14.02.tar.bz2 && \
    tar xjvf nasm-2.14.02.tar.bz2  && \
    cd nasm-2.14.02  && \
    ./autogen.sh  && \
    ./configure  && \
    make  && \
    make install

RUN apt-get install nasm

############################
# Clone and build x264

RUN git clone https://code.videolan.org/videolan/x264 /tmp/x264 && \
    cd /tmp/x264 && \
    git checkout df79067c && \
    ./configure --prefix=/usr --enable-shared --enable-static --enable-pic && make && make install

############################
# Clone and build ffmpeg

# Get latest userland tools and build. Clean up unused stuff at the end
RUN cd \
    && git clone --depth 1 https://github.com/raspberrypi/userland.git \
    && cd userland \
    && sed -i 's/sudo//g' ./buildme \
    && ./buildme \
    && rm -rf ../userland
RUN apt-get install libomxil-bellagio-dev -y
RUN apt-get install -y pkg-config && git clone https://github.com/FFmpeg/FFmpeg && \
    cd FFmpeg && git checkout remotes/origin/release/${FFMPEG_VERSION} && \
    ./configure --enable-nonfree --enable-libx264 --enable-gpl && make && \
    make install && \
    cd .. && rm -rf FFmpeg

############################
# Clone and build machinery

RUN apt-get install -y libglib2.0-dev libbluetooth-dev libdbus-1-dev
RUN git clone https://github.com/psigio/machinery.git /tmp/machinery && \
    cd /tmp/machinery && git checkout 1a6542e72f5c178c82b3c10618ce802a9b0e6854 && \
    mkdir build && cd build && \
    cmake .. && make && make check && make install && \
    rm -rf /tmp/machinery && \
    chown -Rf www-data.www-data /etc/opt/kerberosio && \
    chmod -Rf 777 /etc/opt/kerberosio/config

#####################
# Clone and build web

RUN git clone https://github.com/psigio/web.git /var/www/web && cd /var/www/web && git checkout ef12b6333902489d806ee8394a528fbd0dd6dbe7 && \
    chown -Rf www-data.www-data /var/www/web && curl -sSk https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer && \
    cd /var/www/web && \
    composer install --prefer-source && \
    npm config set unsafe-perm true && \
    npm config set registry http://registry.npmjs.org/ && \
    npm config set strict-ssl=false && \
    npm install -g bower && \
    cd public && \
    sed -i 's/https/http/g' .bowerrc && \
    bower --allow-root install

RUN rm /var/www/web/public/capture && \
    ln -s /etc/opt/kerberosio/capture/ /var/www/web/public/capture

# Fixes, because we are now combining the two docker images.
# Docker is aware of both web and machinery.

RUN sed -i -e "s/'insideDocker'/'insideDocker' => false,\/\//" /var/www/web/app/Http/Controllers/SystemController.php
RUN sed -i -e "s/service kerberosio status/supervisorctl status machinery \| grep \"RUNNING\"';\/\//" /var/www/web/app/Http/Repositories/System/OSSystem.php

# Let's create a /dist folder containing just the files necessary for runtime.
# Later, it will be copied as the / (root) of the output image.

WORKDIR /dist
RUN mkdir -p ./etc/opt && cp -r /etc/opt/kerberosio ./etc/opt/
RUN mkdir -p ./usr/bin && cp /usr/bin/kerberosio ./usr/bin/
RUN mkdir -p ./var/www && cp -r /var/www/web ./var/www/
RUN test -d /opt/vc && mkdir -p ./usr/lib && cp -r /opt/vc/lib/* ./usr/lib/ || echo "not found"
RUN cp /usr/local/bin/ffmpeg ./usr/bin/ffmpeg

# Optional: in case your application uses dynamic linking (often the case with CGO),
# this will collect dependent libraries so they're later copied to the final image
# NOTE: make sure you honor the license terms of the libraries you copy and distribute
RUN ldd /usr/bin/kerberosio | tr -s '[:blank:]' '\n' | grep '^/' | \
    xargs -I % sh -c 'mkdir -p $(dirname ./%); cp % ./%;'

FROM debian:stable-slim

#################################
# Copy files from previous images
COPY --chown=0:0 --from=builder /dist/etc/opt /etc/opt
COPY --chown=0:0 --from=builder /dist/usr/bin /usr/bin
COPY --chown=0:0 --from=builder /dist/var/www /var/www
COPY --chown=0:0 --from=builder /dist/usr/lib /usr/lib
COPY --chown=0:0 --from=builder /dist/usr/bin/ffmpeg /usr/bin/ffmpeg

RUN apt-get -y update && apt-get install -y apt-transport-https wget curl lsb-release && \
    wget -O /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg && \
    echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list && apt update -y

####################################
# ADD supervisor and STARTUP script

RUN apt-get install -y supervisor && mkdir -p /var/log/supervisor/
ADD ./supervisord.conf /etc/supervisord.conf
ADD ./run.sh /run.sh
RUN chmod 755 /run.sh && chmod +x /run.sh

######################
# INSTALL Nginx

RUN apt-get install -y nginx && mkdir -p /run/nginx
RUN rm -Rf /etc/nginx/conf.d/* && rm -Rf /etc/nginx/sites-available/default  && rm -Rf /etc/nginx/sites-enabled/default  && mkdir -p /etc/nginx/ssl
ADD ./web.conf /etc/nginx/sites-available/default.conf
RUN ln -s /etc/nginx/sites-available/default.conf /etc/nginx/sites-enabled/default.conf

RUN chmod -R 777 /var/www/web/bootstrap/cache/ && \
    chmod -R 777 /var/www/web/storage && \
    chmod 777 /var/www/web/config/kerberos.php && \
    chmod -R 777 /etc/opt/kerberosio/config

######################
# INSTALL PHP

ARG PHP_VERSION=7.1

RUN  apt -y install php${PHP_VERSION}-cli php${PHP_VERSION}-gd php${PHP_VERSION}-mcrypt php${PHP_VERSION}-curl \
    php${PHP_VERSION}-mbstring php${PHP_VERSION}-dom php${PHP_VERSION}-zip php${PHP_VERSION}-fpm

########################################
# Force both nginx and PHP-FPM to run in the foreground
# This is a requirement for supervisor

RUN echo "daemon off;" >> /etc/nginx/nginx.conf
RUN sed -i -e "s/;daemonize\s*=\s*yes/daemonize = no/g" /etc/php/${PHP_VERSION}/fpm/php-fpm.conf
RUN sed -i 's/"GPCS"/"EGPCS"/g' /etc/php/${PHP_VERSION}/fpm/php.ini
RUN sed -i 's/"--daemonize/"--daemonize --allow-to-run-as-root/g' /etc/init.d/php${PHP_VERSION}-fpm
RUN sed -i 's/www-data/root/g' /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf
RUN sed -i 's/www-data/root/g' /etc/nginx/nginx.conf
RUN sed -i -e "s/;listen.mode = 0660/listen.mode = 0750/g" /etc/php/${PHP_VERSION}/fpm/pool.d/www.conf && \
    find /etc/php/${PHP_VERSION}/cli/conf.d/ -name "*.ini" -exec sed -i -re 's/^(\s*)#(.*)/\1;\2/g' {} \;
    
############################
# Dbus binaries
RUN apt -y install dbus
############################

############################
# COPY template folder

# Copy the config template to filesystem
ADD ./config /etc/opt/kerberosio/template
ADD ./webconfig /var/www/web/template

########################################################
# Exposing web on port 80 and livestreaming on port 8889

EXPOSE 8889
EXPOSE 80

############################
# Volumes

VOLUME ["/etc/opt/kerberosio/capture"]
VOLUME ["/etc/opt/kerberosio/config"]
VOLUME ["/etc/opt/kerberosio/logs"]
VOLUME ["/var/www/web/config"]

# DBUS socket
RUN mkdir -p /var/run/dbus
VOLUME /var/run/dbus

CMD ["bash", "/run.sh"]
