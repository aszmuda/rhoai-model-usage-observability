FROM registry.access.redhat.com/ubi9/go-toolset:1.27.3 AS builder
WORKDIR /opt/app-root/src
COPY go.mod ./
COPY cmd/ ./cmd/
COPY internal/ ./internal/
RUN CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /opt/app-root/src/bin/external-metering-simulator ./cmd/external-metering-simulator

FROM registry.access.redhat.com/ubi9/ubi-micro:9.6
COPY --from=builder --chmod=0555 /opt/app-root/src/bin/external-metering-simulator /usr/local/bin/external-metering-simulator
USER 1001
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/external-metering-simulator"]
