FROM golang:1.24-alpine AS builder
WORKDIR /app
COPY main.go .
RUN CGO_ENABLED=0 go build -o provider-sim main.go

FROM gcr.io/distroless/static:nonroot
COPY --from=builder /app/provider-sim /provider-sim
ENTRYPOINT ["/provider-sim"]
