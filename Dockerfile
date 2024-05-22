FROM mcr.microsoft.com/cbl-mariner/base/core:2.0 as mariner-elixir

WORKDIR /opt/app

RUN tdnf -y install \
       ca-certificates glibc-i18n tar build-essential make \
       openssl-devel ncurses-devel git unzip \ 
    && locale-gen.sh \
    && OTP_VERSION="27.0" \
    && OTP_DOWNLOAD_URL="https://github.com/erlang/otp/archive/OTP-${OTP_VERSION}.tar.gz" \
    && ELIXIR_VERSION="1.16.3" \
    && ELIXIR_DOWNLOAD_URL="https://github.com/elixir-lang/elixir/archive/refs/tags/v${ELIXIR_VERSION}.zip" \
    && curl -fSL -o "otp-OTP-${OTP_VERSION}.tar.gz" "$OTP_DOWNLOAD_URL" \
    && tar xvfz  "otp-OTP-${OTP_VERSION}.tar.gz" \
    && ( cd "otp-OTP-${OTP_VERSION}" \
      && export ERL_TOP=`pwd` \
      && ./configure \
      && make -j$(nproc) \
      && make install ) \
    && curl -fSL -o "elixir-${ELIXIR_VERSION}.zip" "${ELIXIR_DOWNLOAD_URL}" \
    && unzip  "elixir-${ELIXIR_VERSION}.zip" \
    && ( cd "elixir-${ELIXIR_VERSION}" && make && make install ) \
    && mix local.rebar --force \
    && mix local.hex --force \
    && tdnf -y remove tar build-essential make openssl-devel ncurses-devel unzip \
    && rm -rf "otp-OTP-${OTP_VERSION}.tar.gz" \
              "otp-OTP-${OTP_VERSION}" \
              "elixir-${ELIXIR_VERSION}.zip" \
              "elixir-${ELIXIR_VERSION}" 

FROM mariner-elixir

WORKDIR /opt/app

ADD mix.exs ./
ADD mix.lock ./

RUN tdnf -y install git \
    && mix deps.get \
    && mix deps.compile

COPY frontend/dist/ /opt/app/frontend/dist/
COPY config/        /opt/app/config/
COPY lib            /opt/app/lib/

CMD mix run --no-halt
