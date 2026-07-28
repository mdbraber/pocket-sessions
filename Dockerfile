# Build stage — pure-Go (CGO off), so the runtime image needs no toolchain or libc.
FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /pcsessions ./cmd/pcsessions

FROM alpine:3.21
# ca-certificates for outbound TLS (APNs, later the PC mirror); tzdata for sane logs.
RUN apk add --no-cache ca-certificates tzdata && adduser -D -u 1000 pcsessions
USER pcsessions
ENV PCS_LISTEN=:8080 PCS_DB=/data/pcsessions.db
EXPOSE 8080
COPY --from=build /pcsessions /usr/local/bin/pcsessions
ENTRYPOINT ["pcsessions"]
