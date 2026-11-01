#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${AWS_REGION:=eu-west-3}"
: "${ADMIN_PRINCIPAL_ARN:?Set ADMIN_PRINCIPAL_ARN to your IAM role or user ARN (not an STS session ARN)}"
export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"
for tool in aws docker npm node kubectl python3 git; do
  command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done
aws sts get-caller-identity --query Arn --output text
docker info >/dev/null
(cd cdk && npm install && npm run build && npm run deploy -- --parameters "AdminPrincipalArn=$ADMIN_PRINCIPAL_ARN")
outputs=$(aws cloudformation describe-stacks --stack-name Podpoll --query 'Stacks[0].Outputs' --output json)
read_output() {
  printf '%s' "$outputs" | node -e 'let s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{const x=JSON.parse(s).find(v=>v.OutputKey===process.argv[1]);if(!x)process.exit(1);console.log(x.OutputValue)})' "$1"
}
cluster=$(read_output ClusterName)
repository=$(read_output RepositoryUri)
registry=${repository%%/*}
# Immutable unique tag; build for the x86 worker even when using an Apple Silicon Mac.
tag="$(git rev-parse --short HEAD)-$(date +%s)"
aws ecr get-login-password | docker login --username AWS --password-stdin "$registry"
docker buildx build --platform linux/amd64 -t "$repository:$tag" --push .
aws eks update-kubeconfig --region "$AWS_REGION" --name "$cluster" --alias podpoll
context=podpoll
# Render the overlay locally and change the image before applying, so the cluster
# never attempts to pull the local-only voting-app:v1 image.
kubectl kustomize k8s/aws --load-restrictor LoadRestrictionsNone |
  IMAGE="$repository:$tag" python3 -c 'import os,sys; print(sys.stdin.read().replace("image: voting-app:v1", "image: " + os.environ["IMAGE"]), end="")' |
  kubectl --context "$context" apply -f -
kubectl --context "$context" -n voting rollout status deployment/redis --timeout=300s
kubectl --context "$context" -n voting rollout status deployment/voting-app --timeout=300s
printf '\nReady. Run:\nkubectl --context %s -n voting port-forward service/voting-app 8081:80\n' "$context"
