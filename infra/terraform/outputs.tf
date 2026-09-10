output "app_url" {
  description = "URL onde o Mural responde depois do apply."
  value       = "http://${var.ingress_host}"
}

output "cluster_name" {
  description = "Nome do cluster kind criado."
  value       = kind_cluster.default.name
}

output "kubeconfig_path" {
  description = "Caminho do kubeconfig do cluster kind (gerado pelo provider)."
  value       = kind_cluster.default.kubeconfig_path
}
