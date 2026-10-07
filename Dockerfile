# Builds dll/OctoLogin.dll from source with MinGW-w64.
#
# The DLL is built for 32-bit Windows (i686)
#
# docker build --output type=local,dest=out .
#
# Outputes the DLL in out/OctoLogin.dll.

FROM debian:trixie-slim AS build
RUN apt-get update \
 && apt-get install -y --no-install-recommends gcc-mingw-w64-i686 binutils-mingw-w64-i686 \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY build.sh ./
COPY dll/octologin.c dll/octologin.rc dll/version.h dll/
# Remove possible CRLF line endings
RUN sed -i 's/\r$//' build.sh && sh build.sh

FROM scratch
COPY --from=build /src/dll/OctoLogin.dll /
