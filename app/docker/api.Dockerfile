# Build context: ./app/api
# Multi-stage: builda um binário Go 100% estático (CGO_ENABLED=0) e descarta a
# toolchain golang:1.23-alpine (~300MB) no estágio final, restando só o binário
# numa imagem distroless (sem shell, sem package manager, superfície mínima).

FROM golang:1.23-alpine AS builder

WORKDIR /src

# Cache de dependências: só rebaixa se go.mod/go.sum mudarem.
COPY go.mod go.sum ./
RUN go mod download

COPY . .

# CGO_ENABLED=0 -> binário estático, sem depender de libc do sistema final.
# -trimpath e -ldflags "-s -w" removem paths de build e símbolos de debug (imagem menor).
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/api .

# distroless/static: não tem shell nem libc — só CA certs e o binário.
# "nonroot" já roda como usuário não-root (uid 65532), sem precisar de USER aqui.
FROM gcr.io/distroless/static-debian12:nonroot

WORKDIR /
COPY --from=builder /out/api /api

EXPOSE 8080
ENTRYPOINT ["/api"]
