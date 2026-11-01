# AWS deployment, step by step

This CDK application is independent of the other infrastructure projects in the parent workspace. It creates resources only when you run `cdk deploy` or the deployment script.

## What gets created

1. A VPC with two public subnets and no NAT gateway.
2. An EKS 1.35 cluster with IAM API authentication.
3. One on-demand `t3.medium` Amazon Linux 2023 worker (scaling range 1–2).
4. An ECR repository for Docker images.
5. The EKS Pod Identity agent and EBS CSI storage driver, with its own IAM role.
6. Metrics Server, providing CPU metrics for the optional HPA scaling test.

The deployment script builds and pushes the image, then applies the Kubernetes manifests: two app pods, Redis, and an encrypted gp3 volume. It builds `linux/amd64` even on Apple Silicon. Local manifests remain unchanged; the AWS overlay selects the EBS StorageClass. No managed Redis service, NAT gateway, or public app load balancer is created.

## 1. Authenticate

Install Node.js 22+, AWS CLI v2, Docker with buildx, kubectl compatible with Kubernetes 1.35, and Python 3. Start Docker Desktop. Configure AWS credentials, for example using IAM Identity Center:

```sh
aws configure sso
export AWS_PROFILE=your-profile
export AWS_REGION=eu-west-3
aws sso login --profile "$AWS_PROFILE"
aws sts get-caller-identity
```

Use a dedicated learning account. The deployment identity needs permissions to create the infrastructure and pass its IAM roles. Set the permanent IAM role/user ARN that should receive Kubernetes administrator access:

```sh
export ADMIN_PRINCIPAL_ARN='arn:aws:iam::123456789012:role/YourRole'
```

For an IAM user, use its IAM ARN. For an SSO or assumed-role session, use the backing IAM role ARN, including its full path; do not use the `arn:aws:sts::...:assumed-role/...` value from STS. The current credentials used by the script must correspond to the principal receiving cluster access (or already have cluster access).

## 2. Build and inspect CDK

From the project root:

```sh
cd cdk
npm install
npm run build
npm run synth
```

Bootstrap once per AWS account/region:

```sh
npx cdk bootstrap "aws://$(aws sts get-caller-identity --query Account --output text)/$AWS_REGION"
cd ..
```

## 3. Deploy

From the project root:

```sh
./scripts/deploy-aws.sh
```

Review CDK's IAM changes when prompted. Cluster provisioning can take tens of minutes. The script prints the exact context-specific port-forward command when ready. Every image gets a unique immutable tag, so rerunning the script ships changes without reusing cached images.

If you only want infrastructure:

```sh
cd cdk
npm run deploy -- --parameters "AdminPrincipalArn=$ADMIN_PRINCIPAL_ARN"
```

The app is not installed by that infrastructure-only command.

## 4. Open the app

Use the printed port-forward command, or, after the script has created the kubeconfig alias:

```sh
kubectl --context podpoll -n voting port-forward service/voting-app 8081:80
```

Open http://localhost:8081 or http://voting.app.local:8081 if you configured the local hosts entry. The hostname points to the local tunnel, not directly to AWS. This keeps the learning app accessible only through your authenticated connection. Both app replicas share Redis, but port-forward connects to one pod.

## Costs and limitations

This is **not an always-free EKS deployment**. Standard-support EKS charges $0.10 per cluster-hour (about $73 per 730-hour month), plus EC2, public IPv4, EBS, ECR, and transfer charges. Check your AWS account's credit eligibility and service restrictions; do not assume credits make EKS available on every Free Tier account plan. Budgets notify you; they do not cap spending.

The worker nodes use public subnets for outbound access without a NAT gateway. The Kubernetes API is publicly reachable but requires IAM authorization; the app and Redis Services are private. This is a single-node learning cluster, not high availability. Redis's EBS volume is tied to one availability zone; replacement workers must have capacity in that zone. AOF can lose the most recent writes on abrupt failure. There is no public HTTPS endpoint or global DNS record.

Pricing: https://aws.amazon.com/eks/pricing/
EBS setup: https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html

## 5. Delete the playground

These commands permanently delete votes and images. Delete the Kubernetes workload while the storage driver and nodes still exist, and wait for the EBS volume to be deleted before destroying the stack:

```sh
kubectl --context podpoll delete namespace voting --wait=true
kubectl --context podpoll get pv
```

Check that the `podpoll-gp3` volume is gone. Then:

```sh
cd cdk
npm run destroy
```

The ECR repository and its images are deleted with the stack. The CDK bootstrap stack and its staging assets remain; they are shared account infrastructure and are not deleted by this command. Check CloudFormation and EBS for leftovers after any failed deletion.

## Bundled minimatch security fix

GHSA-g3hv-75wg-m249 affects minimatch versions below 11.0.1. CDK 2.275.0 still bundles 10.2.6. A normal consumer `overrides` entry does not replace CDK's bundled files, and `npm audit fix --force` cannot produce an upstream CDK release with a patched bundle.

Until AWS publishes a fixed release, run from this directory:

```sh
npm run security:fix-cdk
```

This command downloads exactly CDK 2.275.0, replaces its bundled minimatch with exactly 11.0.1, and creates a local CDK tarball in `cdk/vendor/`. It installs that tarball, regenerates the lockfile, verifies the version CDK actually resolves, then runs audit, build and synth. It does not deploy AWS resources. Package lifecycle scripts are disabled during repackaging and installation. The existing CDK runtime code, license, exports and JSII assemblies are preserved; this is a temporary local repack, not an official AWS release. The minimatch major-version change requires the build and synth checks to pass before deployment.

Commit **the tarball, package.json and package-lock.json together** so fresh `npm ci` installations use the same patched bundle. Do not merely edit a version in the lockfile or delete the nested package. If registry access fails, the fix has not been installed; rerun when networking works. Audit output may still show other independent advisories, which need separate review.

Once an official CDK release bundles a patched minimatch, replace the local tarball dependency with that release, confirm `npm ci`, `npm audit`, build and synth, then remove the workaround and vendor tarball.

Advisory: https://github.com/advisories/GHSA-g3hv-75wg-m249
