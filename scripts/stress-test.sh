#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
context=${1:-$(kubectl config current-context)}
if ! kubectl config get-contexts -o name | grep -Fxq -- "$context"; then
  printf 'Context "%s" is not configured. Available contexts:\n' "$context" >&2
  kubectl config get-contexts >&2
  exit 1
fi
printf 'Testing pod scaling in context: %s\n' "$context"
if ! kubectl --context "$context" -n voting top pods -l app=voting-app; then
  echo 'CPU metrics are unavailable. Install/fix Metrics Server first; see load-test/README.md.' >&2
  exit 1
fi
kubectl --context "$context" -n voting rollout status deployment/voting-app --timeout=120s
baseline=$(kubectl --context "$context" -n voting get deployment voting-app -o jsonpath='{.status.readyReplicas}')
baseline=${baseline:-0}
if ((baseline >= 4)); then
  echo 'Already at the test maximum (4 replicas). Wait for idle scale-down before testing scale-up.' >&2
  exit 1
fi
kubectl --context "$context" apply -f k8s/hpa.yaml
kubectl --context "$context" -n voting create configmap voting-load-script \
  --from-file=voting.js=load-test/voting.js --dry-run=client -o yaml |
  kubectl --context "$context" apply -f -
job=$(kubectl --context "$context" create -f load-test/job.yaml -o name)
printf 'Started %s. This six-minute test adds votes; baseline=%s ready replicas.\n' "$job" "$baseline"
printf 'Cancel: kubectl --context %s -n voting delete %s\n' "$context" "$job"
printf 'Watch: kubectl --context %s -n voting get hpa voting-app -w\n' "$context"
maximum=$baseline
result=timeout
# Observe the Job and actual ready replicas together. A desired replica increase
# alone does not prove scaling works: unschedulable pods are not ready replicas.
for ((attempt=0; attempt<60; attempt++)); do
  ready=$(kubectl --context "$context" -n voting get deployment voting-app -o jsonpath='{.status.readyReplicas}')
  ready=${ready:-0}
  if ((ready > maximum)); then maximum=$ready; fi
  status=$(kubectl --context "$context" -n voting get "$job" -o jsonpath='{.status.succeeded},{.status.failed}')
  printf 'Ready app replicas: %s (highest observed: %s)\n' "$ready" "$maximum"
  case "$status" in
    1,*) result=passed; break ;;
    *,1) result=failed; break ;;
  esac
  sleep 10
done
kubectl --context "$context" -n voting logs "$job" || true
printf '\nScaling result: %s → %s ready replicas. Load test: %s.\n' "$baseline" "$maximum" "$result"
echo 'HPA remains enabled. Watch it return to two replicas after the idle cooldown.'
if [[ "$result" != passed ]]; then
  echo 'Inspect Job events and the k6 summary; traffic thresholds or Job execution failed.' >&2
  exit 1
fi
if ((maximum <= baseline)); then
  echo 'No ready-replica increase was observed. Inspect HPA CPU metrics and pod scheduling before increasing load.' >&2
  exit 1
fi
