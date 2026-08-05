
### Enabling observability for your service

Two flags in your values file, nothing else:

```yaml
metrics:
  enabled: true          # platform scrapes /metrics automatically
tracing:
  enabled: true          # platform injects OTEL_EXPORTER_OTLP_ENDPOINT + service identity
```

With `tracing.enabled`, a vanilla OpenTelemetry SDK exports traces with no further configuration — the platform supplies the endpoint, service name, and environment attributes. Alerts on your namespace route to your team's channel; ask the platform team to add the routing entry when you onboard.
