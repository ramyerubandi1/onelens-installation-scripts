{{- define "job-cronjob.name" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "job-cronjob.jobName" -}}
{{- printf "%s-%s" (include "job-cronjob.name" .) .Values.job.name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "job-cronjob.cronjobName" -}}
{{- printf "%s-%s" (include "job-cronjob.name" .) .Values.cronjob.name | trunc 63 | trimSuffix "-" }}
{{- end }}
