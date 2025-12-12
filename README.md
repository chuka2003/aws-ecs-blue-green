# aws-ecs-blue-green-deploy

![CI](https://github.com/chuka2003/aws-ecs-blue-green/actions/workflows/ci.yml/badge.svg)
![GitHub release](https://img.shields.io/github/v/release/chuka2003/aws-ecs-blue-green)
![License](https://img.shields.io/github/license/chuka2003/aws-ecs-blue-green)
![GitHub Marketplace](https://img.shields.io/badge/Marketplace-ecs--blue--green--deploy-blue?logo=github)
![Maintained](https://img.shields.io/badge/Maintained-Yes-success)
![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)

## Marketplace Description

Blue-Green Deployments for Amazon ECS — Without CodeDeploy.
This Action provides safe, progressive deployments to ECS behind an Application Load Balancer using weighted traffic shifting between BLUE and GREEN target groups.

* Zero-downtime releases
* Optional task definition image update
* Progressive traffic shifting (customizable steps + interval)
* Works with ECS Fargate and ECS EC2
* Uses native AWS APIs — no CodeDeploy needed

Ideal when you want predictable, production-grade ECS deployments with rollback‑friendly behavior.

A GitHub Action for performing zero-downtime blue-green deployments to Amazon ECS (Fargate or EC2) behind an Application Load Balancer (ALB).

It updates the ECS task definition (optionally injecting a new image), deploys it to the ECS service, waits for stabilization, then gradually shifts traffic from the BLUE target group to the GREEN target group with configurable steps and intervals.

Perfect for teams who want safe, progressive ECS deployments — without running CodeDeploy.

---

## Features

* Update ECS task definition with a new image
* Deploy new revision to ECS service
* Wait for service stabilization
* Perform weighted ALB traffic shifting (blue → green)
* Fully configurable shift speed (steps + interval)
* Safe validation and clear logging
* No CodeDeploy required

---

## Inputs

| Input                    | Required | Description                                          |
| ------------------------ | -------- | ---------------------------------------------------- |
| `aws-region`             | ✔️       | AWS region (e.g., `us-east-1`)                       |
| `aws-role-to-assume`     | ✔️       | IAM role ARN for deployment                          |
| `cluster`                | ✔️       | ECS cluster name                                     |
| `service`                | ✔️       | ECS service name                                     |
| `image`                  | ❌        | New container image URI to deploy                    |
| `container-name`         | ❌        | Container name inside task definition to update      |
| `listener-arn`           | ✔️       | ALB listener ARN                                     |
| `blue-target-group-arn`  | ✔️       | ARN of BLUE target group (active production traffic) |
| `green-target-group-arn` | ✔️       | ARN of GREEN target group (new revision)             |
| `shift-steps`            | ❌        | Number of traffic shift steps (default: `10`)        |
| `shift-interval-seconds` | ❌        | Seconds to wait per step (default: `15`)             |

---

## Example Workflow

```yaml
ame: Deploy to ECS (Blue-Green)

on:
  push:
    branches: [ main ]

jobs:
  deploy:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Blue-Green Deploy
        uses: chuka2003/aws-ecs-blue-green@v1
        with:
          aws-region: us-east-1
          aws-role-to-assume: arn:aws:iam::123456789012:role/github-actions-deploy-role

          cluster: my-ecs-cluster
          service: my-api-service

          image: 123456789012.dkr.ecr.us-east-1.amazonaws.com/my-api:latest
          container-name: my-api

          listener-arn: arn:aws:elasticloadbalancing:us-east-1:123456789012:listener/app/my-alb/...

          blue-target-group-arn: arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/my-blue-tg/abc123
          green-target-group-arn: arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/my-green-tg/xyz987

          shift-steps: 10
          shift-interval-seconds: 15
```

---

## How It Works

1. Fetch ECS service + task definition
2. If `image` + `container-name` are provided → generate a new task definition revision
3. Update ECS service to use the new task definition
4. Wait for the service to stabilize
5. Begin ALB traffic shift:

   * BLUE starts at 100%
   * GREEN starts at 0%
   * Each step increases GREEN weight until it reaches 100%

---

## Requirements

Your runner must have:

* AWS CLI
* `jq` installed
* Permission to modify ECS, ALB, IAM role assumption, etc.

The IAM role must include permissions for:

* `ecs:DescribeServices`, `ecs:UpdateService`, `ecs:RegisterTaskDefinition`
* `elasticloadbalancing:ModifyListener`, `DescribeListeners`
* `iam:PassRole` (if execution or task roles exist in task def)

---

## Architecture Diagram

```
                    ┌────────────────────────┐
                    │      GitHub Action     │
                    │  ecs-blue-green-deploy │
                    └─────────────┬──────────┘
                                  │
                                  ▼
                      ┌────────────────────┐
                      │   ECS Task Def     │
                      │  (Optionally updated│
                      │   with new image)   │
                      └──────────┬──────────┘
                                 │
                                 ▼
                  ┌────────────────────────────┐
                  │      ECS Service Update     │
                  │  Applies new task definition │
                  └─────────────┬───────────────┘
                                │
                                ▼
                     ┌───────────────────────┐
                     │       ALB Listener     │
                     │  Weighted TG Forwarding│
                     └──────────┬─────────────┘
                                │
              ┌─────────────────┼──────────────────┐
              ▼                 ▼                  ▼
     ┌────────────────┐   ┌────────────────┐   Traffic shifts
     │  BLUE Target   │   │ GREEN Target   │   from BLUE → GREEN
     │ Group (Live)   │   │ Group (New)    │   over N steps
     └────────────────┘   └────────────────┘
```

## Repository Structure

```
aws-ecs-blue-green/
├─ action.yml                # Composite GitHub Action
├─ README.md                 # Usage + roadmap stub
├─ scripts/
│  └─ deploy.sh              # Polished blue-green deploy script (MVP)
├─ examples/
│  └─ blue-green.yml         # Full CI example workflow
├─ LICENSE                   # MIT
└─ .github/
   └─ workflows/
      └─ ci.yml              # Simple CI to lint the script
```

---

## Changelog

### [1.0.0] - 2025-01-01

#### Added

* Initial release of `aws-ecs-blue-green`.
* ECS task definition update (with optional image override).
* ECS service deployment + stabilization wait.
* ALB weighted traffic shifting between BLUE and GREEN target groups.
* Full script-based implementation using AWS CLI + jq.
* Comprehensive README and examples.

### [1.1.0] - Unreleased

#### Added

* Planned: automatic detection of BLUE/GREEN target groups.
* Planned: configurable rollback triggers.
* Planned: dry-run validation mode.

### [1.0.1] - Unreleased

#### Fixed

* Planned: improved error handling around empty container definitions.
* Planned: additional validation for missing IAM permissions.

## Contributions

PRs, issues, and feature suggestions are welcome!

This action will evolve with improvements like automatic target group discovery, rollback logic, and better validation.
