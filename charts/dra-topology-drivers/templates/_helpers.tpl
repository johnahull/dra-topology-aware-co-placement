{{- define "dra-topology-drivers.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "dra-topology-drivers.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: dra-topology-drivers
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}
