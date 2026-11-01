#!/usr/bin/env node
import { App, Tags } from 'aws-cdk-lib';
import { VotingStack } from '../lib/voting-stack';
const app = new App();
new VotingStack(app, 'Podpoll', {
  env: { account: process.env.CDK_DEFAULT_ACCOUNT, region: process.env.CDK_DEFAULT_REGION ?? 'eu-west-3' },
});
Tags.of(app).add('Project', 'kubernetes-voting');
