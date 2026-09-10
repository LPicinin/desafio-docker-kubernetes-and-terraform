variable "cluster_name" {
  description = "Nome do cluster kind."
  type        = string
  default     = "mural"
}

variable "namespace" {
  description = "Namespace onde o chart do Mural é implantado."
  type        = string
  default     = "mural"
}

variable "ingress_host" {
  description = "Host pelo qual o Mural responde (via Ingress). *.localtest.me resolve para 127.0.0.1 sem mexer em /etc/hosts."
  type        = string
  default     = "mural.localtest.me"
}

variable "traefik_chart_version" {
  description = "Versão do chart do Traefik (repo https://traefik.github.io/charts)."
  type        = string
  default     = "33.0.0"
}

variable "repo_root" {
  description = "Caminho da raiz do repositório (onde ficam app/ e infra/), relativo a infra/terraform."
  type        = string
  default     = "../.."
}

variable "api_image" {
  description = "Nome:tag da imagem da API construída localmente e carregada no kind."
  type        = string
  default     = "mural-api:dev"
}

variable "web_image" {
  description = "Nome:tag da imagem do front construída localmente e carregada no kind."
  type        = string
  default     = "mural-web:dev"
}

variable "postgres_image" {
  description = "Imagem oficial do Postgres usada pelo StatefulSet e pelo Job de migração."
  type        = string
  default     = "postgres:16-alpine"
}

variable "postgres_user" {
  description = "Usuário do Postgres."
  type        = string
  default     = "mural"
}

variable "postgres_password" {
  description = "Senha do Postgres. Vira Secret no cluster — não fica hardcoded em manifest versionado."
  type        = string
  default     = "mural"
  sensitive   = true
}

variable "postgres_database" {
  description = "Nome do banco do Postgres."
  type        = string
  default     = "mural"
}
