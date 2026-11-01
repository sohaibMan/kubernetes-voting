import { CfnOutput, CfnParameter, RemovalPolicy, Stack, StackProps } from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as ecr from 'aws-cdk-lib/aws-ecr';
import * as eks from 'aws-cdk-lib/aws-eks';
import * as iam from 'aws-cdk-lib/aws-iam';

export class VotingStack extends Stack {
  constructor(scope: Construct, id: string, props?: StackProps) {
    super(scope, id, props);
    const adminArn = new CfnParameter(this, 'AdminPrincipalArn', {
      type: 'String', description: 'IAM role or user ARN for kubectl access. Do not use an STS assumed-role ARN.',
      allowedPattern: 'arn:[^:]+:iam::[0-9]{12}:(role|user)/.+',
    });
    const vpc = new ec2.Vpc(this, 'Vpc', {
      maxAzs: 2, natGateways: 0,
      subnetConfiguration: [{ name: 'public', subnetType: ec2.SubnetType.PUBLIC, cidrMask: 24 }],
    });
    const controlPlaneRole = new iam.Role(this, 'ControlPlaneRole', {
      assumedBy: new iam.ServicePrincipal('eks.amazonaws.com'),
      managedPolicies: [iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonEKSClusterPolicy')],
    });
    const cluster = new eks.CfnCluster(this, 'Cluster', {
      version: '1.35', roleArn: controlPlaneRole.roleArn,
      accessConfig: { authenticationMode: 'API', bootstrapClusterCreatorAdminPermissions: false },
      resourcesVpcConfig: {
        subnetIds: vpc.publicSubnets.map(s => s.subnetId),
        endpointPrivateAccess: true, endpointPublicAccess: true,
      },
    });
    const access = new eks.CfnAccessEntry(this, 'AdminAccess', {
      clusterName: cluster.ref, principalArn: adminArn.valueAsString, type: 'STANDARD',
      accessPolicies: [{ policyArn: `arn:${this.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy`, accessScope: { type: 'cluster' } }],
    });
    const nodeRole = new iam.Role(this, 'NodeRole', {
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
      managedPolicies: ['AmazonEKSWorkerNodePolicy', 'AmazonEC2ContainerRegistryPullOnly', 'AmazonEKS_CNI_Policy']
        .map(name => iam.ManagedPolicy.fromAwsManagedPolicyName(name)),
    });
    const nodes = new eks.CfnNodegroup(this, 'Workers', {
      clusterName: cluster.ref, nodeRole: nodeRole.roleArn,
      subnets: vpc.publicSubnets.map(s => s.subnetId),
      instanceTypes: ['t3.medium'], amiType: 'AL2023_x86_64_STANDARD', capacityType: 'ON_DEMAND',
      diskSize: 20, scalingConfig: { minSize: 1, desiredSize: 1, maxSize: 2 },
    });
    nodes.node.addDependency(vpc.internetConnectivityEstablished);
    const agent = new eks.CfnAddon(this, 'PodIdentityAgent', {
      clusterName: cluster.ref, addonName: 'eks-pod-identity-agent',
    });
    agent.addDependency(nodes);
    const storageRole = new iam.Role(this, 'StorageRole', {
      assumedBy: new iam.ServicePrincipal('pods.eks.amazonaws.com').withSessionTags(),
      managedPolicies: [iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonEBSCSIDriverPolicyV2')],
    });
    const ebs = new eks.CfnAddon(this, 'EbsCsi', {
      clusterName: cluster.ref, addonName: 'aws-ebs-csi-driver',
      podIdentityAssociations: [{ roleArn: storageRole.roleArn, serviceAccount: 'ebs-csi-controller-sa' }],
    });
    ebs.addDependency(agent);
    const repository = new ecr.Repository(this, 'Images', {
      imageScanOnPush: true, imageTagMutability: ecr.TagMutability.IMMUTABLE,
      removalPolicy: RemovalPolicy.DESTROY, emptyOnDelete: true,
    });
    new CfnOutput(this, 'ClusterName', { value: cluster.ref });
    new CfnOutput(this, 'RepositoryUri', { value: repository.repositoryUri });
    new CfnOutput(this, 'Region', { value: this.region });
    new CfnOutput(this, 'ConfigureKubectl', {
      value: `aws eks update-kubeconfig --region ${this.region} --name ${cluster.ref} --alias podpoll`,
    });
    // AccessEntry is explicit: CloudFormation's execution role gets no implicit kubectl admin access.
    access.addDependency(cluster);
  }
}
