# Podpoll — a Kubernetes voting playground

Vote for cats or dogs and watch the totals update every two seconds. A small Python server serves the page and API. Redis shares votes between app replicas. No frontend build is needed.

```text
Browser → voting-app Service → Python pods (2 replicas) → Redis → persistent volume
```

## 1. Start with the app

Requires Python 3.9+. From this directory:

```sh
python3 app.py
```

Open http://localhost:8080. Without `REDIS_HOST`, the app uses a local SQLite database (`votes.db`). Click either choice and watch the totals change. Repeat votes are intentional; this is a learning playground without authentication or vote deduplication.

```sh
python3 -m unittest -v
```

Tests cover HTTP responses, invalid input, concurrent voting, SQLite persistence, and unavailable storage. They use a temporary database. Redis and Kubernetes require separate integration verification.

## 2. Put it in containers

Requires a running Docker engine:

```sh
docker compose up --build
```

Open http://localhost:8080. This time votes are stored in Redis, backed by a Docker volume. Stop with `docker compose down`; the volume remains.

## 3. Deploy to Kubernetes

Enable Kubernetes in Docker Desktop first. These commands explicitly select the local Docker Desktop cluster:

```sh
docker build -t voting-app:v1 .
kubectl --context docker-desktop apply -f k8s/app.yaml
kubectl --context docker-desktop -n voting rollout status deployment/redis
kubectl --context docker-desktop -n voting rollout status deployment/voting-app
kubectl --context docker-desktop -n voting port-forward service/voting-app 8080:80
```

Stop the local app or Compose first to free port 8080. Open http://localhost:8080. The cluster needs a default StorageClass for the Redis volume. With kind instead, load the image using `kind load docker-image voting-app:v1` and use your kind context in place of `docker-desktop`.

What each resource does:

- **Namespace:** keeps this playground together in `voting`.
- **Deployment:** maintains the desired number of pods and replaces failed pods.
- **Service:** gives pods a stable address and routes traffic to ready pods.
- **Readiness probe:** checks that vote storage is reachable before routing traffic to an app pod.
- **Liveness probe:** checks the app itself; a Redis outage does not force app restarts.
- **PersistentVolumeClaim:** keeps Redis data when its pod is replaced. Redis uses AOF persistence; abrupt failure can lose recent writes before a disk flush.

## Local hostname: voting.app.local

Add a local hosts entry on your Mac (once):

```sh
if ! dscacheutil -q host -a name voting.app.local | grep -q '127.0.0.1'; then
  printf '\n127.0.0.1 voting.app.local\n' | sudo tee -a /etc/hosts
fi
sudo dscacheutil -flushcache
sudo killall -HUP mDNSResponder
```

Forward the Kubernetes Service in a terminal and leave it running:

```sh
kubectl --context docker-desktop -n voting port-forward service/voting-app 8081:80
```

Open http://voting.app.local:8081. The hosts entry maps the name to this Mac; it does not forward ports or expose the app to other devices. For the Python app running directly on port 8080, use http://voting.app.local:8080 instead. `.local` is reserved for multicast DNS; the explicit hosts entry is used here for the requested local name.

## 4. Try scaling

In another terminal:

```sh
kubectl --context docker-desktop -n voting scale deployment/voting-app --replicas=3
kubectl --context docker-desktop -n voting get pods -w
```

All app pods share Redis totals. `kubectl port-forward service/...` selects a single pod, so the displayed pod name normally stays fixed through that tunnel. A real ingress or load balancer distributes new connections across pods.

## 5. Watch self-healing

List the app pods, then replace `<pod-name>` with one of their names:

```sh
kubectl --context docker-desktop -n voting get pods -l app=voting-app
kubectl --context docker-desktop -n voting delete pod <pod-name>
kubectl --context docker-desktop -n voting get pods -w
```

The Deployment creates a replacement. If you deleted the pod used by port-forward, restart the port-forward command. Votes stay in Redis.

## 6. Ship a new version

Change the heading in `public/index.html`, then:

```sh
docker build -t voting-app:v2 .
kubectl --context docker-desktop -n voting set image deployment/voting-app app=voting-app:v2
kubectl --context docker-desktop -n voting rollout status deployment/voting-app
```

Roll back:

```sh
kubectl --context docker-desktop -n voting rollout undo deployment/voting-app
```

## Troubleshooting and cleanup

- `ImagePullBackOff`: ensure the app image exists in the cluster's container runtime.
- PVC `Pending`: check `kubectl --context docker-desktop get storageclass`.
- API returns 503: inspect Redis with `kubectl --context docker-desktop -n voting logs deployment/redis`.
- Inspect app logs: `kubectl --context docker-desktop -n voting logs deployment/voting-app`.

Delete the playground and its stored Kubernetes votes:

```sh
kubectl --context docker-desktop delete namespace voting
```

This is a local learning environment. Redis is a single instance, there is no TLS or authentication, and polling replaces WebSockets for simplicity. Keep it local. Next exercises: ingress, autoscaling, metrics, and network policies.

## Deploy to AWS with CDK

See [the AWS walkthrough](cdk/README.md) for the TypeScript CDK stack, AWS authentication, EKS costs, deployment, and cleanup. From this project root, after configuring credentials and bootstrapping CDK:

```sh
export AWS_REGION=eu-west-3
export ADMIN_PRINCIPAL_ARN='arn:aws:iam::123456789012:role/YourRole'
./scripts/deploy-aws.sh
```

## Stress test the deployment

Run `./scripts/stress-test.sh podpoll` for AWS or `./scripts/stress-test.sh docker-desktop` locally. This launches a three-minute in-cluster k6 test up to 50 concurrent users and adds real votes. See [the load testing guide](load-test/README.md) for thresholds, monitoring, increasing load, and pod recovery experiments.
