{{- define "rahi-chat-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "rahi-chat-app.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name (include "rahi-chat-app.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "rahi-chat-app.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | quote }}
app.kubernetes.io/name: {{ include "rahi-chat-app.name" . | quote }}
app.kubernetes.io/instance: {{ .Release.Name | quote }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service | quote }}
{{- end }}

{{- define "rahi-chat-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "rahi-chat-app.name" . | quote }}
app.kubernetes.io/instance: {{ .Release.Name | quote }}
{{- end }}
