{{/* Expand the name of the chart. */}}
{{- define "sports-store.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Build an image reference with an optional global registry prefix. */}}
{{- define "sports-store.image" -}}
{{- $registry := trimSuffix "/" (default "" .root.Values.global.applicationImageRegistry) -}}
{{- $repository := trimPrefix "/" .repository -}}
{{- if and $registry (not (hasPrefix (printf "%s/" $registry) $repository)) -}}
{{- printf "%s/%s:%s" $registry $repository .tag -}}
{{- else -}}
{{- printf "%s:%s" $repository .tag -}}
{{- end -}}
{{- end }}

{{/* Create a fully qualified app name. */}}
{{- define "sports-store.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/* Create the chart name and version label. */}}
{{- define "sports-store.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Common labels. */}}
{{- define "sports-store.labels" -}}
helm.sh/chart: {{ include "sports-store.chart" . }}
{{ include "sports-store.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/* Selector labels. */}}
{{- define "sports-store.selectorLabels" -}}
app.kubernetes.io/name: {{ include "sports-store.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* Create the name of the service account to use. */}}
{{- define "sports-store.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "sports-store.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
