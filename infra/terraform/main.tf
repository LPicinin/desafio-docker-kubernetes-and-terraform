# Maestro: cria o cluster kind, disponibiliza as imagens da app dentro dele,
# instala o Traefik (ingress) e implanta o chart do Mural. Um único `apply`
# sai do zero até a app respondendo; `apply` de novo não muda nada (idempotente).

provider "kind" {}

locals {
  api_repo      = split(":", var.api_image)[0]
  api_tag       = split(":", var.api_image)[1]
  web_repo      = split(":", var.web_image)[0]
  web_tag       = split(":", var.web_image)[1]
  postgres_repo = split(":", var.postgres_image)[0]
  postgres_tag  = split(":", var.postgres_image)[1]
}

# --- Cluster kind -----------------------------------------------------------
# Label ingress-ready=true no control-plane + port-mappings 80/443: é o que o
# Traefik (abaixo) usa via hostPort para responder em localhost sem tocar em
# /etc/hosts (host tipo *.localtest.me resolve para 127.0.0.1 sozinho).
resource "kind_cluster" "default" {
  name           = var.cluster_name
  wait_for_ready = true

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    node {
      role = "control-plane"

      labels = {
        "ingress-ready" = "true"
      }

      extra_port_mappings {
        container_port = 80
        host_port      = 80
        protocol       = "TCP"
      }

      extra_port_mappings {
        container_port = 443
        host_port      = 443
        protocol       = "TCP"
      }
    }
  }
}

provider "kubernetes" {
  host                   = kind_cluster.default.endpoint
  client_certificate     = kind_cluster.default.client_certificate
  client_key             = kind_cluster.default.client_key
  cluster_ca_certificate = kind_cluster.default.cluster_ca_certificate
}

provider "helm" {
  kubernetes {
    host                   = kind_cluster.default.endpoint
    client_certificate     = kind_cluster.default.client_certificate
    client_key             = kind_cluster.default.client_key
    cluster_ca_certificate = kind_cluster.default.cluster_ca_certificate
  }
}

# --- Imagens da app dentro do cluster ---------------------------------------
# kind não puxa de um registry externo por padrão: builda local e injeta no
# cluster. Em vez de `kind load docker-image`, que exigiria o binário do kind
# instalado no PATH além do provider, fazemos exatamente o que esse comando faz
# por baixo: exporta a imagem do daemon com `docker save` e importa direto no
# containerd do node com `ctr`, que já vem na node image. Com isso o
# pré-requisito da solução inteira é só Docker + Terraform.
locals {
  # O kind nomeia o container do node como "<cluster>-control-plane".
  kind_node    = "${kind_cluster.default.name}-control-plane"
  node_kubectl = "docker exec ${local.kind_node} kubectl --kubeconfig /etc/kubernetes/admin.conf"

  build_cmds = [
    "docker build -f app/docker/api.Dockerfile -t ${var.api_image} app/api",
    "docker build -f app/docker/web.Dockerfile -t ${var.web_image} app/web",
  ]

  # `--all-platforms` não é opcional: o buildx do Docker Desktop exporta um
  # índice OCI com um manifesto de attestation junto do manifesto real, e sem a
  # flag o `ctr` importa só o default e a imagem não fica resolvível pelo
  # kubelet. `-` lê do stdin, evitando tarball temporário no disco.
  load_cmds = [
    for img in [var.api_image, var.web_image] :
    "docker save ${img} | docker exec -i ${local.kind_node} ctr --namespace=k8s.io images import --all-platforms --digests -"
  ]
}

# Os triggers hasheiam Dockerfile + fonte, então um `apply` sem mudança de
# código não re-executa nada (idempotente).
resource "null_resource" "build_and_load_images" {
  triggers = {
    cluster             = kind_cluster.default.name
    api_dockerfile_hash = filesha1("${var.repo_root}/app/docker/api.Dockerfile")
    api_source_hash     = sha1(join("", [for f in fileset("${var.repo_root}/app/api", "**") : filesha1("${var.repo_root}/app/api/${f}")]))
    web_dockerfile_hash = filesha1("${var.repo_root}/app/docker/web.Dockerfile")
    web_source_hash     = sha1(join("", [for f in fileset("${var.repo_root}/app/web", "**") : filesha1("${var.repo_root}/app/web/${f}")]))
    api_image           = var.api_image
    web_image           = var.web_image
  }

  # Uma única linha com "&&": um `local-exec` multi-linha só roda o primeiro
  # comando no cmd.exe do Windows (quebras de linha não encadeiam comandos ali
  # como fazem no sh) — "&&" funciona em cmd.exe e em sh/bash. O `join` é só
  # para manter os comandos legíveis acima; o que sai daqui é uma linha só.
  provisioner "local-exec" {
    working_dir = var.repo_root
    command     = join(" && ", concat(local.build_cmds, local.load_cmds))
  }
}

# --- Ingress controller (Traefik) -------------------------------------------
# hostPort 80/443 no pod (nodeSelector ingress-ready=true) casa com os
# port-mappings do node kind acima: é o caminho recomendado para Ingress
# funcionar em localhost com kind, sem LoadBalancer externo.
resource "helm_release" "traefik" {
  name             = "traefik"
  repository       = "https://traefik.github.io/charts"
  chart            = "traefik"
  version          = var.traefik_chart_version
  namespace        = "traefik"
  create_namespace = true
  wait             = true
  timeout          = 300

  values = [
    yamlencode({
      ports = {
        web = {
          port     = 8000
          hostPort = 80
        }
        websecure = {
          port     = 8443
          hostPort = 443
        }
      }
      service = {
        type = "ClusterIP"
      }
      nodeSelector = {
        "ingress-ready" = "true"
      }
      tolerations = [
        {
          key      = "node-role.kubernetes.io/control-plane"
          operator = "Equal"
          effect   = "NoSchedule"
        },
        {
          key      = "node-role.kubernetes.io/master"
          operator = "Equal"
          effect   = "NoSchedule"
        }
      ]
    })
  ]

  depends_on = [kind_cluster.default]
}

# --- Chart do Mural -----------------------------------------------------------
resource "helm_release" "mural" {
  name             = "mural"
  chart            = "${var.repo_root}/infra/helm/mural"
  namespace        = var.namespace
  create_namespace = true

  # wait=false de propósito: o Helm, com --wait, espera os Deployments ficarem
  # Ready ANTES de disparar hooks post-install/post-upgrade — e a API só fica
  # Ready depois que o Job de migração (hook) rodar. Com wait=true isso é um
  # deadlock (API nunca fica Ready -> hook nunca dispara -> API nunca fica
  # Ready). Por isso não esperamos aqui: o rollout_status abaixo (kubectl)
  # é quem garante que o `apply` só termina com a app de fato respondendo.
  wait    = false
  timeout = 300

  set {
    name  = "image.api.repository"
    value = local.api_repo
  }
  set {
    name  = "image.api.tag"
    value = local.api_tag
  }
  set {
    name  = "image.web.repository"
    value = local.web_repo
  }
  set {
    name  = "image.web.tag"
    value = local.web_tag
  }
  set {
    name  = "image.postgres.repository"
    value = local.postgres_repo
  }
  set {
    name  = "image.postgres.tag"
    value = local.postgres_tag
  }
  set {
    name  = "ingress.host"
    value = var.ingress_host
  }
  set {
    name  = "postgres.user"
    value = var.postgres_user
  }
  set_sensitive {
    name  = "postgres.password"
    value = var.postgres_password
  }
  set {
    name  = "postgres.database"
    value = var.postgres_database
  }

  depends_on = [
    helm_release.traefik,
    null_resource.build_and_load_images,
  ]
}

# --- Confirma que a app está de pé --------------------------------------------
# Substitui o wait=true do helm_release (ver comentário acima): espera o
# rollout dos Deployments (api/web) via kubectl. Nesse ponto o Job de
# migração (hook) já rodou — é o que faz a readiness da API passar.
resource "null_resource" "wait_for_rollout" {
  triggers = {
    release_revision = helm_release.mural.metadata[0].revision
  }

  # O kubectl roda dentro do próprio node (a node image do kind já traz o
  # binário e o admin.conf), pelo mesmo motivo do `ctr` acima: não exigir nada
  # instalado no host além do Docker.
  provisioner "local-exec" {
    command = join(" && ", [
      "${local.node_kubectl} rollout status deployment/mural-api -n ${var.namespace} --timeout=180s",
      "${local.node_kubectl} rollout status deployment/mural-web -n ${var.namespace} --timeout=60s",
    ])
  }

  depends_on = [helm_release.mural]
}
