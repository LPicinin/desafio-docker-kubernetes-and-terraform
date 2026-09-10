{{/*
Nome base do release, usado como prefixo de todos os recursos.
*/}}
{{- define "mural.fullname" -}}
{{- .Release.Name -}}
{{- end -}}

{{/*
Labels comuns aplicados a todo recurso do chart.
*/}}
{{- define "mural.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/*
Selector labels de um componente específico (api, web, postgres).
Uso: {{ include "mural.selectorLabels" (dict "root" . "component" "api") }}
*/}}
{{- define "mural.selectorLabels" -}}
app.kubernetes.io/name: {{ .root.Chart.Name }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/*
DATABASE_URL montada a partir das credenciais em values.postgres e do
Service (headless) do Postgres. Vive só dentro do Secret.
*/}}
{{- define "mural.databaseURL" -}}
postgres://{{ .Values.postgres.user }}:{{ .Values.postgres.password }}@{{ include "mural.fullname" . }}-postgres:{{ .Values.postgres.port }}/{{ .Values.postgres.database }}?sslmode=disable
{{- end -}}
