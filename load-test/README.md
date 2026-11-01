# Stress testing Podpoll

Run from the project root after deploying. The k6 Job runs **inside the cluster** against the app Service, so traffic can reach both replicas without a port-forward bottleneck. It creates real votes. It shares the learning worker with the app, so generator CPU and node capacity affect results too.

## Start small

```sh
./scripts/stress-test.sh podpoll
```

For Docker Desktop use `./scripts/stress-test.sh docker-desktop` instead. The three-minute test ramps through 10, 25, and 50 concurrent virtual users, holds 50 for one minute, and ramps down. Each user votes, reads results, then waits one second. Virtual users are not requests per second; observe measured throughput.

Pass criteria: fewer than 1% HTTP failures, more than 99% successful response checks, and p95 latency below one second. These are initial learning targets, not a measured service guarantee. The script returns nonzero if the Job fails. Jobs are not retried, so failed thresholds do not generate another traffic run.

## Watch during the test

In separate terminals:

```sh
kubectl --context podpoll -n voting get pods -w
kubectl --context podpoll -n voting logs -f deployment/voting-app --all-pods=true --max-log-requests=10
kubectl --context podpoll -n voting top pods
kubectl --context podpoll top nodes
```

`top` requires Metrics Server, which this CDK stack does not install. If unavailable, inspect pod restarts, events, k6 latency/error metrics, and EC2 CPU in CloudWatch. On older kubectl versions without `--all-pods`, use `-l app=voting-app --prefix=true` for the logs command.

Read the k6 summary: `http_reqs` is throughput, `http_req_failed` is error rate, and `http_req_duration` includes p95 latency. Check for pod restarts, `OOMKilled`, or `Pending` pods:

```sh
kubectl --context podpoll -n voting get events --sort-by=.lastTimestamp
```

## Increase load and compare

Edit `PEAK_VUS` in `load-test/job.yaml` to 100 and then 200, rerunning the script each time. Run one test at a time. Stop increasing once errors or latency cross the thresholds. Inspect load-generator CPU too: a saturated generator cannot establish app capacity.

Try three app replicas, rerun the same load, and compare results:

```sh
kubectl --context podpoll -n voting scale deployment/voting-app --replicas=3
kubectl --context podpoll -n voting rollout status deployment/voting-app
./scripts/stress-test.sh podpoll
```

Extra pods share the same single node; this may not improve throughput if node CPU or Redis is the bottleneck. Neither an HPA nor Cluster Autoscaler is installed. A node group's `maxSize: 2` alone does not automatically add nodes. Reapplying the app manifests restores two replicas.

## Test recovery separately

During a fresh run, list the app pods and delete one by name:

```sh
kubectl --context podpoll -n voting get pods -l app=voting-app
kubectl --context podpoll -n voting delete pod <pod-name>
```

Watch the replacement and k6 errors. In-flight requests can fail, so the normal latency/error targets may fail during this experiment. Keep Redis running so this specifically tests app pod recovery.

The runner prints the command to cancel its Job. Finished Jobs expire after one hour. To remove all load-test Jobs immediately:

```sh
kubectl --context podpoll -n voting delete jobs -l app=voting-load
```

Reference: https://grafana.com/docs/k6/latest/using-k6/thresholds/
