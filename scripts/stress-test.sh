#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
context=${1:-podpoll}
# Explicit context prevents accidentally targeting a different current cluster.
kubectl --context "$context" -n voting create configmap voting-load-script \
  --from-file=voting.js=load-test/voting.js --dry-run=client -o yaml |
  kubectl --context "$context" apply -f -
job=$(kubectl --context "$context" create -f load-test/job.yaml -o name)
printf 'Started %s in context %s. This test adds real votes.\n' "$job" "$context"
printf 'Cancel: kubectl --context %s -n voting delete %s\n' "$context" "$job"
kubectl --context "$context" -n voting wait --for=condition=Ready pod \
  -l "job-name=${job#job.batch/}" --timeout=120s
kubectl --context "$context" -n voting logs -f "$job"
# Propagate failed thresholds as a non-zero script exit.
for ((attempt=0; attempt<30; attempt++)); do
  status=$(kubectl --context "$context" -n voting get "$job" -o jsonpath='{.status.succeeded},{.status.failed}')
  case "$status" in
    1,*) exit 0 ;;
    *,1) echo 'Load test failed; inspect the k6 summary above.' >&2; exit 1 ;;
  esac
  sleep 1
done
echo 'Job has not reached a terminal status; inspect it with kubectl describe.' >&2
exit 1
