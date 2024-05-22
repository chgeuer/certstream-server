FROM mcr.microsoft.com/cbl-mariner/base/core:2.0 as mariner-elixir

WORKDIR /opt/app

ENV OTP_VERSION="27.0" ELIXIR_VERSION="1.16.3"

RUN tdnf -y install ca-certificates glibc-i18n build-essential make openssl-devel ncurses-devel git tar unzip \ 
    && locale-gen.sh \
    && OTP_DOWNLOAD_URL="https://github.com/erlang/otp/archive/OTP-${OTP_VERSION}.tar.gz" \
    && curl --fail --show-error --location --output "otp-OTP-${OTP_VERSION}.tar.gz" --url "$OTP_DOWNLOAD_URL" \
    && tar xvfz  "otp-OTP-${OTP_VERSION}.tar.gz" \
    && ( cd "otp-OTP-${OTP_VERSION}" \
      && export ERL_TOP=`pwd` \
      && ./configure \
      && make -j$(nproc) \
      && make install ) \
    && rm -rf "otp-OTP-${OTP_VERSION}.tar.gz" "otp-OTP-${OTP_VERSION}" \
    && ELIXIR_DOWNLOAD_URL="https://github.com/elixir-lang/elixir/archive/refs/tags/v${ELIXIR_VERSION}.zip" \
    && curl --fail --show-error --location --output "elixir-${ELIXIR_VERSION}.zip" --url "${ELIXIR_DOWNLOAD_URL}" \
    && unzip "elixir-${ELIXIR_VERSION}.zip" \
    && ( cd "elixir-${ELIXIR_VERSION}" && make && make install ) \
    && rm -rf "elixir-${ELIXIR_VERSION}.zip"  "elixir-${ELIXIR_VERSION}" \
    && mix local.rebar --force && mix local.hex --force

FROM mariner-elixir as build

WORKDIR /opt/app

ADD mix.exs ./
ADD mix.lock ./

RUN mix deps.get && mix deps.compile

COPY frontend/dist/ /opt/app/frontend/dist/
COPY config/        /opt/app/config/
COPY lib            /opt/app/lib/

RUN MIX_ENV=prod mix release app

FROM mcr.microsoft.com/cbl-mariner/base/core:2.0

WORKDIR /opt/app

RUN tdnf -y install ca-certificates

COPY --from=build /opt/app/_build/prod .

EXPOSE 4000/tcp

ENTRYPOINT ["./rel/app/bin/app"]
CMD ["start"]
