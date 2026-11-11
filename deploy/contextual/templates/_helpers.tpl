{{- define "contextual.labels" -}}
app.kubernetes.io/part-of: contextual
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{- define "contextual.image" -}}
{{ .root.Values.image.registry }}/{{ .root.Values.image.repository }}/{{ .name }}:{{ .root.Values.image.tag }}
{{- end }}

{{- define "contextual.valkey" -}}
sentinel://valkey-sentinel:26379/{{ .Values.valkey.masterName }}
{{- end }}

{{- /* How the crawler and online pods reach Valkey: password and CA. */ -}}
{{- define "contextual.valkeyEnv" -}}
- name: VALKEY_PASSWORD
  valueFrom:
    secretKeyRef: { name: valkey-auth, key: password }
- name: VALKEY_CA_CERT
  value: /etc/valkey-tls/ca.crt
{{- end }}

{{- define "contextual.valkeyCA" -}}
name: valkey-ca
secret:
  secretName: valkey-tls
  items: [{ key: ca.crt, path: ca.crt }]
{{- end }}

{{- define "contextual.securityContext" -}}
runAsNonRoot: true
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: [ALL]
{{- end }}
