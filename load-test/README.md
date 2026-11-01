# Test automatic pod scaling

This test sends real votes to the Kubernetes Service and verifies that the number of **ready app replicas increases**. It does not change EC2 node counts. The HPA scales from 2 to at most 4 replicas at 50% average CPU utilization, relative to the app's 100m CPU request (about 50m per pod). The target is deliberately low for this learning exercise.

## 1. Make CPU metrics available

Check your cluster first:

```sh
kubectl --context docker-desktop top pods -n voting
```

For Docker Desktop, if Metrics Server is missing, install the upstream release:

```sh
kubectl --context docker-desktop apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.8.0/components.yaml
kubectl --context docker-desktop -n kube-system rollout status deployment/metrics-server
```

Metrics Server 0.8 requires Kubernetes 1.31 or newer. If its logs report kubelet certificate validation errors on Docker Desktop, this local-only adjustment allows its self-signed kubelet certificates:

```sh
kubectl --context docker-desktop -n kube-system patch deployment metrics-server --type=json -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
```

Do not apply that TLS adjustment to AWS. Wait a minute for metrics collection, then retry `top pods`.

For AWS, the CDK stack now includes the `metrics-server` EKS add-on. Redeploy the stack to install it, then check:

```sh
kubectl --context podpoll -n voting top pods
```

## 2. Run the scaling test

From the project root:

```sh
./scripts/stress-test.sh docker-desktop
```

For AWS:

```sh
./scripts/stress-test.sh podpoll
```

Without an argument, the script uses and prints your current Kubernetes context. Run in the foreground to see progress. It checks CPU metrics, enables the HPA, and starts an in-cluster k6 Job. Run only one test at a time: active Jobs share the test ConfigMap.

Traffic ramps through 10, 50, and 100 concurrent users, holds peak load for three minutes, and ramps down, for six minutes total. Each iteration sends a vote and reads results, then waits 0.1 seconds. The script observes ready replicas while the Job runs and prints the k6 summary at the end. It exits nonzero if the Job fails or no ready-replica increase was observed. Existing votes are changed by the test.

### Vote preferences

Each run randomly favors cats or dogs, giving that side a 65–85% chance per vote. The preference is generated once in k6 `setup()` and shared by all virtual users; the k6 log prints it. Unlike equal-probability voting, large runs should visibly favor one side. The UI always shows real cumulative votes, so existing votes can dilute a new run's preference; they are not cleared automatically.

For a fixed preference, add `CAT_SHARE` to the container environment in `load-test/job.yaml`. For example, `value: "0.8"` means each vote has an 80% chance of choosing cats. `"0.2"` favors dogs, `"0.5"` restores equal odds, and `"0"`/`"1"` choose only one side. Omitting the setting restores randomized preferences per run. Start a new test Job after changes; a running Job keeps its original script and preference.

## 3. Watch the scaling

In another terminal (replace the context with `podpoll` for AWS):

```sh
kubectl --context docker-desktop -n voting get hpa voting-app -w
```

In a third terminal:

```sh
kubectl --context docker-desktop -n voting get pods -w
```

Expected sequence: CPU rises above the target, HPA increases desired replicas, new pods become ready, and traffic spreads across them. After traffic stops, the HPA should eventually return to two replicas. Scale-down has a 90-second stabilization window, with at most one pod removed per 30 seconds. Timing also depends on metrics collection and readiness.

Watch CPU snapshots with `kubectl --context docker-desktop -n voting top pods`. The HPA remains enabled after the test. Reapplying `k8s/app.yaml` can briefly reset the Deployment to two replicas; the HPA will reconcile it again.

## 4. Interpret the result

Scaling and service performance are separate results. The k6 targets are fewer than 1% HTTP errors, more than 99% valid response checks, and p95 latency below one second. Scaling can work while these performance targets fail. Conversely, low CPU might mean the app serves this workload without needing more replicas.

If scaling does not happen:

- HPA shows `<unknown>`: fix Metrics Server or wait for fresh samples.
- CPU stays below 50%: inspect CPU first, then increase `PEAK_VUS` in `load-test/job.yaml` (for example to 200) and rerun.
- Desired replicas increase but pods stay `Pending`: inspect pod events and node capacity. More load cannot solve scheduling failures.
- More ready replicas appear but errors remain: Redis, app handling, or node CPU may be the bottleneck.

Useful diagnostics:

```sh
kubectl --context docker-desktop -n voting describe hpa voting-app
kubectl --context docker-desktop -n voting get events --sort-by=.lastTimestamp
kubectl --context docker-desktop -n voting get jobs -l app=voting-load
```

The load generator shares the learning node and has a 500m CPU limit, so it can become a bottleneck. This experiment does not establish maximum production throughput. The single EKS worker also limits total capacity: HPA adds pods, but no Cluster Autoscaler or Karpenter is installed to add EC2 nodes.

## Cleanup

The runner prints a command to cancel its Job. To stop all test traffic and disable autoscaling:

```sh
kubectl --context docker-desktop -n voting delete jobs -l app=voting-load
kubectl --context docker-desktop -n voting delete hpa voting-app
kubectl --context docker-desktop -n voting scale deployment/voting-app --replicas=2
kubectl --context docker-desktop -n voting delete configmap voting-load-script
```

Use `podpoll` for AWS. Finished Jobs expire after an hour; HPA does not expire automatically.

References: [Kubernetes HPA](https://kubernetes.io/docs/concepts/workloads/autoscaling/horizontal-pod-autoscale/), [Metrics Server](https://kubernetes-sigs.github.io/metrics-server/), [EKS Metrics Server](https://docs.aws.amazon.com/eks/latest/userguide/metrics-server.html).
