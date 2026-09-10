# Mural de Recados — Docker + Kubernetes + Terraform

Solução do desafio: **um único `terraform apply` sobe um cluster kind do zero, builda e
carrega as imagens da app, instala o Traefik e implanta o Mural de Recados via Helm** —
sem nenhum passo manual de `kubectl`/`helm` fora do Terraform.

**Pré-requisitos: Docker e Terraform.** Só. Nada de `kind`, `kubectl` ou `helm`
instalados no host — o cluster sai do provider `tehcyx/kind`, o Helm roda dentro do
provider `hashicorp/helm`, e o que precisa de linha de comando (`ctr`, `kubectl`) é
executado dentro do próprio container do node, que já traz os dois.

```bash
cd infra/terraform
terraform init
terraform apply   # do zero até a app responder em http://mural.localtest.me
```

Rodar `terraform apply` de novo dá `0 added, 0 changed, 0 destroyed`. `terraform destroy`
remove o cluster e tudo dentro dele.

## O que foi entregue

- **`app/docker/api.Dockerfile`**: multi-stage — builda um binário Go estático
  (`CGO_ENABLED=0`) em `golang:1.23-alpine` e descarta a toolchain no estágio final,
  que é `gcr.io/distroless/static-debian12:nonroot` (sem shell, sem package manager,
  já roda non-root).
- **`app/docker/web.Dockerfile`**: `nginx:1.27-alpine` servindo os estáticos, com
  `API_UPSTREAM` parametrizável via `envsubst` (template oficial do nginx) — a mesma
  imagem serve no compose e no cluster sem recompilar.
- **`infra/helm/mural/`**: chart com `Deployment` (api/web), `StatefulSet+PVC`
  (postgres), `Service`s, `Ingress`, `Secret` (credencial do banco), `ConfigMap` das
  migrations e o `Job` de migração como hook.
- **`infra/terraform/`**: cluster kind (`tehcyx/kind`) + build/load das imagens +
  Traefik (`hashicorp/helm`) + deploy do chart — tudo amarrado num `apply` idempotente.

### Tamanho da imagem da API: antes/depois

| Imagem | Tamanho |
|---|---|
| `golang:1.23-alpine` (rodando `go run main.go`, como no compose) | **370 MB** |
| `mural-api` final (multi-stage → `distroless/static-debian12`) | **18.9 MB** |

Redução de ~95%. A imagem final carrega só o binário estático — sem toolchain Go, sem
código-fonte, sem shell.

## Decisões e porquês

### Job de migração: hook `post-install,post-upgrade`, não `pre-install`

Essa foi a parte mais sutil do desafio. A primeira tentativa óbvia — hook
`pre-install` — não funciona: hooks `pre-install` rodam **antes** de qualquer recurso
do chart existir, então numa instalação limpa o Postgres nem teria sido criado ainda
para o Job se conectar.

A segunda armadilha, menos óbvia: com o Job como hook `post-install`/`post-upgrade` e
o Terraform pedindo pro Helm **esperar os recursos ficarem `Ready`** (`wait = true` /
`wait_for_jobs = true`), o `helm_release` **trava para sempre**. O Helm, com `--wait`,
espera os Deployments ficarem `Ready` *antes* de disparar os hooks `post-install` — e a
API só fica `Ready` depois que a migração (o próprio hook) rodar. Deadlock: a API nunca
fica pronta → o hook nunca dispara → a API nunca fica pronta.

A solução: no `helm_release.mural` (`infra/terraform/main.tf`), `wait = false`. O Helm
aplica os manifests e dispara os hooks sem esperar nada ficar pronto. Quem garante que o
`apply` só termina com a app de fato respondendo é um `null_resource` separado
(`wait_for_rollout`) que roda `kubectl rollout status` nos Deployments da API e do front
**depois** do `helm_release` — nesse ponto o Job já rodou e a readiness passa.

O Job em si (`infra/helm/mural/templates/migrate-job.yaml`) espera o Postgres responder
com um loop de `pg_isready` antes de aplicar as migrations (o Service headless já existe
quando o hook dispara — só o Postgres pode ainda estar de boot). `hook-delete-policy:
before-hook-creation,hook-succeeded` garante que cada `helm upgrade` recria o Job do
zero e limpa o anterior.

### Probes: liveness ≠ readiness

`livenessProbe` da API aponta para `/healthz` (nunca toca no banco — um pod não deve
morrer só porque o Postgres está lento); `readinessProbe` aponta para `/readyz` (só
passa com schema pronto). Invertê-las causa CrashLoop, como o enunciado avisa.

### Secret, não hardcode

`DATABASE_URL`, usuário e senha do Postgres vivem só no `Secret` gerado a partir de
`values.postgres.*` (`infra/helm/mural/templates/secret.yaml`). Nenhum outro template
(`Deployment`, `ConfigMap`) contém a credencial — todos injetam via `secretKeyRef`.

### Ingress: `/api` direto pra API, `/` pro front

Seguindo `docs/arquitetura.md`, o Ingress tem duas regras: `/api` → Service da API,
`/` → Service do front. O nginx continua com seu próprio proxy `/api` parametrizado por
`API_UPSTREAM` (só não é exercitado dentro do cluster porque o Ingress já intercepta o
path antes — mas a mesma imagem funciona idêntica fora do cluster, com o nginx fazendo
o proxy).

### Carregar as imagens no cluster sem o CLI do kind

O caminho óbvio para injetar uma imagem local num cluster kind é
`kind load docker-image`. O problema é que isso reintroduz uma dependência que o
provider `tehcyx/kind` justamente elimina: o provider cria o cluster com a biblioteca
do kind embutida, mas o `kind load` é o **binário** — ou seja, a solução voltaria a
exigir o CLI no `PATH`, numa versão suficientemente nova (as antigas erram a detecção
do snapshotter do containerd com node images recentes).

Então o `local-exec` faz o que o `kind load` faz por baixo, direto:

```
docker save mural-api:dev | docker exec -i mural-control-plane \
  ctr --namespace=k8s.io images import --all-platforms --digests -
```

Exporta a imagem do daemon e importa no containerd do node, no namespace `k8s.io` (o
que o CRI enxerga). O `ctr` já vem na node image, então não há nada a instalar. Dois
detalhes que não são opcionais:

- **`--all-platforms`**: o buildx do Docker Desktop exporta um índice OCI com um
  manifesto de *attestation* ao lado do manifesto real. Sem a flag, o `ctr` importa só
  o manifesto default e a imagem não fica resolvível pelo kubelet.
- **`-` (stdin)**: evita materializar um tarball de ~90 MB no disco a cada `apply`.

Pelo mesmo motivo, o `wait_for_rollout` roda `kubectl` **de dentro do node**
(`docker exec ... kubectl --kubeconfig /etc/kubernetes/admin.conf rollout status`), que
a node image também já traz — assim nem o `kubectl` precisa estar instalado no host.

Detalhe de portabilidade que sobrevive nos dois casos: um `local-exec` do Terraform com
múltiplas linhas separadas por quebra de linha, no `cmd.exe` do Windows, **só executa a
primeira linha** — as demais são silenciosamente ignoradas (diferente do `sh -c`, que
roda todas). Por isso os comandos são encadeados com `&&` numa única linha (montada com
`join(" && ", ...)` só para ficar legível no `.tf`), que funciona igual em `cmd.exe` e
em `sh`/`bash`.

### Ambiente de teste

Toda a solução foi validada de ponta a ponta nesta máquina (Windows 11 + Docker Desktop,
node image `kindest/node:v1.35.0`): `terraform apply` do zero com o cluster inexistente,
app respondendo `200` em `http://mural.localtest.me` e em `/api/messages`, `apply`
repetido com `0 added, 0 changed, 0 destroyed`, e `terraform destroy` limpando tudo —
tudo isso sem `kind`, `kubectl` ou `helm` instalados no host.

## Rodando localmente (docker-compose, só para entender a app)

```bash
docker compose up --build
# abra http://localhost:8080
```

## Estrutura

```
app/docker/          Dockerfiles (api.Dockerfile, web.Dockerfile)
infra/helm/mural/     Chart do Mural (Deployment, StatefulSet, Ingress, Secret, Job)
infra/terraform/      Maestro: kind + Traefik + helm_release do chart
docs/arquitetura.md   Diagrama do estado-alvo
```

## Bônus (não implementado)

HPA + teste de carga e automação via Makefile ficaram de fora — o foco foi fechar o
obrigatório (Docker + Helm + Terraform) com o ciclo `apply → apply → destroy`
validado de ponta a ponta.
