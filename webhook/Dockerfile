FROM golang:1.22-alpine AS builder
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download 2>/dev/null || true
COPY . .
RUN CGO_ENABLED=0 go build -o /webhook main.go

FROM alpine:3.19
RUN apk --no-cache add ca-certificates
COPY --from=builder /webhook /webhook
ENTRYPOINT ["/webhook"]
