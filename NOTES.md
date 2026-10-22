# Week 8: Containers at Scale with ECS on Fargate

**Goal:** go from "one container on one box" (Weeks 5–7: a single EC2 instance running `docker compose up -d`) to a load-balanced, self-healing, auto-scaling service with zero-downtime deployments.

This is a **concept-first README**. It explains everything before you build it. The issues-faced and screenshot sections get added once implementation starts.

---

## Table of contents

1. [Starting point: what you already have](#1-starting-point-what-you-already-have)
2. [The big picture](#2-the-big-picture)
3. [ECS: a manager for your containers](#3-ecs-a-manager-for-your-containers)
4. [Fargate: where the containers physically run](#4-fargate-where-the-containers-physically-run)
5. [Networking: VPC, subnets and security groups for Fargate](#5-networking-vpc-subnets-and-security-groups-for-fargate)
6. [The load balancer (ALB)](#6-the-load-balancer-alb)
7. [The two IAM roles](#7-the-two-iam-roles)
8. [Logs](#8-logs)
9. [Autoscaling](#9-autoscaling)
10. [Deployments: rolling vs blue/green](#10-deployments-rolling-vs-bluegreen)
11. [How the GitHub Actions pipeline changes](#11-how-the-github-actions-pipeline-changes)
12. [Terraform resources in build order](#12-terraform-resources-in-build-order)
13. [Pitfalls](#13-pitfalls)
14. [Hands-on learning order](#14-hands-on-learning-order)
15. [Glossary](#15-glossary)
16. [Sources](#16-sources)

---

## 1. Starting point: what you already have

```
Internet → EC2 instance (public IP) → docker compose → your containers
```

You SSH in, run `docker compose up -d`, and the app runs. This works, but it has four problems:

| #   | Problem                    | What happens                                                                                                          |
| --- | -------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| 1   | **One machine**            | If the EC2 instance crashes, the site is down until you fix it by hand.                                               |
| 2   | **Nobody is watching**     | If a container dies at 3am, only Docker's `restart:` policy helps, and that still depends on the one box being alive. |
| 3   | **Fixed capacity**         | If traffic triples, the same instance has to absorb all of it.                                                        |
| 4   | **Deploys cause downtime** | The pipeline SSHes in, pulls, and restarts. For a few seconds nothing is serving.                                     |

Week 8 solves these four problems. **Every new term below is one piece of that solution.** If a term is confusing, ask: _which of the four problems does this solve?_

| Problem               | Solved by                                                               |
| --------------------- | ----------------------------------------------------------------------- |
| 1. One machine        | ALB + multiple tasks spread across 2 Availability Zones (sections 5, 6) |
| 2. Nobody watching    | ECS **service** + health checks (sections 3, 6)                         |
| 3. Fixed capacity     | Service **autoscaling** (section 9)                                     |
| 4. Downtime on deploy | **Blue/green** deployments with CodeDeploy (section 10)                 |

---

## 2. The big picture

```
GitHub push
   → Actions: lint/test → build image → push to ECR          (same as Week 7)
   → register new task definition revision                   (new)
   → CodeDeploy: start GREEN tasks → health check → flip ALB  (new)
                                                    ↓
Users → ALB (public subnets) → Target group (blue or green)
                                    ↓
                     Fargate tasks in private subnets, across 2 AZs
                                    ↑
           ECS service keeps N tasks alive · autoscaling adjusts N
```

Compared with Week 7, only the **last step** of the pipeline really changes. Instead of `ssh` + `docker compose up`, it becomes "register a new revision and let CodeDeploy roll it out."

---

## 3. ECS: a manager for your containers

**ECS (Elastic Container Service)** is AWS software that runs and supervises containers for you. You stop SSHing in to run `docker compose`. You **describe what you want**, and ECS makes it happen and keeps it that way.

ECS has four core pieces. Each maps to something you already know:

| ECS term            | What it is                                         | Your Week 5–7 equivalent            |
| ------------------- | -------------------------------------------------- | ----------------------------------- |
| **Task definition** | A recipe: image, CPU/RAM, ports, env vars, logging | Your `docker-compose.yml`           |
| **Task**            | One running copy of the recipe                     | One `docker compose up`             |
| **Service**         | A supervisor: "always keep N tasks running"        | Nothing. _You_ were the supervisor. |
| **Cluster**         | A named group that services and tasks live in      | Roughly the EC2 instance itself     |

### 3.1 Cluster

A logical container for your services. On Fargate, a cluster costs nothing and has no machines in it that you can see. It's just a namespace, for example `ebotprog-cluster`.

### 3.2 Task definition (the recipe)

A JSON document (Terraform writes it for you) that says:

- **Which image:** for example `110xxxx.dkr.ecr.eu-north-1.amazonaws.com/app:abc123`
- **How much CPU and memory** the task gets. Fargate only accepts certain pairs, for example `256 CPU / 512 MB`, `512 / 1024`, `1024 / 2048`. (1024 CPU units = 1 vCPU.)
- **Port mappings:** for example container port `3000`
- **Environment variables and secrets:** secrets come from Secrets Manager or SSM Parameter Store, not a `.env` file on a server
- **Log configuration:** where stdout/stderr goes (CloudWatch, see section 8)
- **Health check:** an optional command run _inside_ the container
- **Network mode:** always `awsvpc` on Fargate (section 5)
- **Two IAM roles:** execution role and task role (section 7)

**Versioning matters.** You never edit a task definition in place. Every change (new image tag, new env var) creates a new **revision**: `app:1`, `app:2`, `app:3`… A service always points at one specific revision. **Rolling back = pointing the service at the previous revision.**

### 3.3 Task (one running copy)

A task is the live set of containers created from a task definition.

**Tasks are disposable.** If one gets sick, ECS doesn't repair it. It kills it and starts a fresh one from the same recipe. This is the biggest mindset shift this week:

> Weeks 5–7: _"The server is broken, SSH in and fix it."_
> Week 8: _"The task is broken, throw it away; a new one is already starting."_

This is also why **nothing important should be stored inside a task**. Its disk disappears when it's replaced. Databases live elsewhere (see pitfalls, section 13).

### 3.4 Service (the supervisor)

You tell the service: _"Keep 2 tasks of revision 14 running."_ The ECS scheduler then:

1. Launches 2 tasks.
2. Watches their health (ALB health checks and container health checks, section 6.4).
3. Replaces any task that stops or fails health checks.
4. **Registers each new task's IP with the ALB target group**, and removes it when the task stops.

The service doesn't start 2 tasks once and walk away. It **continuously enforces** "2 healthy tasks exist." This is what makes the setup self-healing.

Key service settings:

| Setting                             | Meaning                                                                       |
| ----------------------------------- | ----------------------------------------------------------------------------- |
| `desired_count`                     | How many tasks to keep running (autoscaling changes this later)               |
| `launch_type = "FARGATE"`           | Run on Fargate                                                                |
| `network_configuration`             | Which subnets and security groups the tasks get                               |
| `load_balancer`                     | Which target group, container name, and port to register                      |
| `health_check_grace_period_seconds` | How long a new task gets to boot before failed health checks count against it |
| `deployment_controller`             | `ECS` (rolling, the default) or `CODE_DEPLOY` (blue/green)                    |

---

## 4. Fargate: where the containers physically run

Containers still need a computer. ECS offers two **launch types**:

|                                                    | EC2 launch type                        | Fargate                               |
| -------------------------------------------------- | -------------------------------------- | ------------------------------------- |
| Who manages the machines                           | You (create, patch, size disks)        | AWS, invisibly                        |
| Can you SSH into the host                          | Yes                                    | No, there is no host for you          |
| Billing                                            | Per EC2 instance, whether busy or idle | Per task, by vCPU + memory per second |
| Week 5-style problems (disk full, kernel versions) | Still yours                            | Gone                                  |

**Fargate is "serverless containers."** You say _"this task needs 0.5 vCPU and 1 GB RAM"_ and it runs. Each task is isolated and gets exactly the CPU/memory you asked for. That's what Week 8 uses.

---

## 5. Networking: VPC, subnets and security groups for Fargate

### 5.1 `awsvpc`: every task gets its own IP

On your EC2 box, all containers shared the instance's single IP, and you mapped ports like `3000:3000`.

On Fargate (`awsvpc` network mode), **every task gets its own network card (ENI) and its own private IP inside your VPC**, as if each task were a tiny server:

```
Task A → 10.0.11.15  (port 3000)
Task B → 10.0.12.27  (port 3000)
```

There's no port mapping trickery. Container port 3000 is reachable at the task's IP on port 3000. This is **why the ALB can send traffic straight to task IPs** (section 6).

### 5.2 Where things go: public vs private subnets

This builds directly on the dual-AZ VPC you diagrammed:

```
VPC 10.0.0.0/16
├── Public subnet  AZ-a  ── ALB node, NAT Gateway        (route → Internet Gateway)
├── Public subnet  AZ-b  ── ALB node                      (route → Internet Gateway)
├── Private subnet AZ-a  ── Fargate tasks                 (route → NAT Gateway)
└── Private subnet AZ-b  ── Fargate tasks                 (route → NAT Gateway)
```

- The **ALB lives in public subnets**, since it has to be reachable from the internet. It needs at least 2 AZs.
- **Tasks live in private subnets**, so nobody on the internet can reach them directly. Only the ALB can.
- **Private tasks still need outbound internet** to pull images from ECR and send logs. They get it through a **NAT Gateway** or **VPC endpoints** (see pitfalls).

> **Simpler start option:** put tasks in public subnets with `assign_public_ip = true`. Less secure, but no NAT needed. It's fine for step 1 of the learning order and should be replaced later.

### 5.3 Security groups: chain them

Two security groups, with one referencing the other:

| Security group | Inbound rule                                            |
| -------------- | ------------------------------------------------------- |
| `alb-sg`       | Port 80/443 from `0.0.0.0/0` (the whole internet)       |
| `tasks-sg`     | Port 3000 **from `alb-sg` only** (not from an IP range) |

Referencing a security group instead of an IP means _"allow whatever is attached to the ALB."_ There's no IP to keep updating, which is a nice change from your Week 5–7 dynamic-IP problems.

---

## 6. The load balancer (ALB)

Now you have several tasks, each with its own private IP. Users only know one name: `ebotprog.ink`. The **ALB (Application Load Balancer)** sits in front and spreads requests across tasks:

```
Users → ALB (one public DNS name) ─┬→ Task A (10.0.11.15:3000)
                                   └→ Task B (10.0.12.27:3000)
```

Route 53 points `ebotprog.ink` at the ALB with an **alias record**, the same way you pointed it at the EC2 instance before.

### 6.1 Listener (the front door)

_"I listen on port 80 (or 443), and when a request arrives I forward it to target group X."_

- Port 443 needs a certificate from **ACM (AWS Certificate Manager)**.
- A common pattern: a port 80 listener that just redirects to 443.

### 6.2 Target group (the list of backends)

The list of places the listener forwards traffic to. For Fargate:

- `target_type = "ip"`, because tasks are registered by IP, not by instance ID.
- `port = 3000`, the container port.
- **You never add IPs yourself.** The ECS service registers and deregisters tasks automatically.

### 6.3 Health check (ALB side)

The ALB keeps calling something like `GET /health` on every target:

| Setting               | Example   | Meaning                                           |
| --------------------- | --------- | ------------------------------------------------- |
| `path`                | `/health` | Endpoint to call; it should return HTTP 200       |
| `interval`            | 30s       | How often to check                                |
| `healthy_threshold`   | 2         | Passes in a row before a target counts as healthy |
| `unhealthy_threshold` | 3         | Failures in a row before it counts as unhealthy   |
| `matcher`             | `200`     | Which status codes count as healthy               |

An unhealthy target stops receiving traffic, and the ECS service replaces that task.

### 6.4 Two health checks, two different questions

| Check                                               | Asked from                | Question                           |
| --------------------------------------------------- | ------------------------- | ---------------------------------- |
| **ALB health check**                                | Outside, over the network | "Can I get a 200 over HTTP?"       |
| **Container health check** (in the task definition) | Inside the container      | "Is the process actually healthy?" |

Either one failing causes the task to be replaced. Many setups use only the ALB check, and that's fine to start.

### 6.5 Why this gives high availability

Tasks are spread across **2 Availability Zones** (separate data centres). If one AZ goes down entirely, the ALB sends everything to the tasks in the other AZ, and the service starts replacements. That solves problem #1.

---

## 7. The two IAM roles

On EC2 in Week 7 there was basically one identity. ECS uses **two roles at two different moments**. Mixing them up causes most beginner errors.

|                     | **Execution role**                                                                   | **Task role**                                 |
| ------------------- | ------------------------------------------------------------------------------------ | --------------------------------------------- |
| Used by             | ECS itself (the agent starting your task)                                            | **Your application code**                     |
| When                | _Before_ your container starts                                                       | _While_ your app is running                   |
| Typical permissions | Pull image from ECR, read secrets from Secrets Manager/SSM, write logs to CloudWatch | Whatever your app calls: S3, DynamoDB, SES, … |
| AWS managed policy  | `AmazonECSTaskExecutionRolePolicy` (plus secrets access)                             | None; you write a least-privilege policy      |
| Error if wrong      | `CannotPullContainerError`, `ResourceInitializationError`, the task never starts     | App starts but throws `AccessDenied`          |

**Debugging question:** _"Is it failing before my code runs, or during?"_

- Before → fix the **execution role**.
- During → fix the **task role**.

> This is separate from your **GitHub OIDC role** from Week 7, which the _pipeline_ uses. That one will need extra permissions such as `ecs:RegisterTaskDefinition`, `ecs:UpdateService`, `codedeploy:*` on your app, and `iam:PassRole` for the two roles above.

---

## 8. Logs

There's no server to SSH into, so `docker logs` is gone. Instead, the task definition uses the **`awslogs` log driver**, which ships stdout/stderr to **CloudWatch Logs**:

```json
"logConfiguration": {
  "logDriver": "awslogs",
  "options": {
    "awslogs-group": "/ecs/ebotprog-app",
    "awslogs-region": "eu-north-1",
    "awslogs-stream-prefix": "app"
  }
}
```

Create the log group in Terraform (`aws_cloudwatch_log_group`). Read logs in the console, or with:

```bash
aws logs tail /ecs/ebotprog-app --follow --region eu-north-1
```

When a task keeps dying, **check the logs and the service's Events tab first**. The reason is almost always there.

---

## 9. Autoscaling

Instead of a fixed number of tasks, you give a rule:

> _"Keep average CPU around 60%. Never fewer than 2 tasks, never more than 6."_

This is done by **Application Auto Scaling** (a separate AWS service that can scale ECS services). It has two parts:

1. **Scalable target:** _what_ can scale and its limits. Here, the service's `DesiredCount`, with `min_capacity = 2` and `max_capacity = 6`.
2. **Scaling policy:** _how_ it scales. Use **target tracking**:
   - Metric: `ECSServiceAverageCPUUtilization` (or memory, or ALB requests per target)
   - Target value: `60`

How target tracking works:

```
CPU 85% > 60% target  →  CloudWatch alarm fires  →  add tasks   →  load spreads, CPU drops
CPU 20% ≪ 60% for a while  →  alarm fires          →  remove tasks →  save money
```

- **Scale-out cooldown:** wait time after adding tasks before adding more, so new tasks get a chance to take load. Short, around 60s.
- **Scale-in cooldown:** wait time before removing again. Longer, around 300s, to avoid flapping up and down.
- New tasks are registered with the ALB automatically by the service. Nothing else to wire.

That solves problem #3.

---

## 10. Deployments: rolling vs blue/green

### 10.1 Rolling update (the ECS default)

ECS replaces old tasks with new ones a few at a time, controlled by:

- `minimum_healthy_percent` (for example 100%: never drop below the desired count)
- `maximum_percent` (for example 200%: allowed to temporarily run double)

It's decent, but **during the rollout, old and new versions serve users at the same time**, and a rollback means doing another full rollout.

### 10.2 Blue/green

Keep **two complete copies side by side** and switch traffic between them in one move:

```
Before:   Listener → Target group BLUE   (v1 tasks)  ← all users

Deploy:   CodeDeploy starts v2 tasks in Target group GREEN
          Health checks run on GREEN (no real users yet)
          Optional: test traffic via a second "test listener" (e.g. port 8080)

Switch:   Listener → Target group GREEN  (v2 tasks)  ← users moved over
          BLUE (v1) stays running for a wait period

Problem?  Flip the listener back to BLUE. Rollback takes seconds.
Fine?     After the wait period, BLUE tasks are terminated.
```

- **Blue** = the version currently live. **Green** = the new version.
- Rollback is instant because **the old tasks never died**. You're just pointing the listener back at them.
- That solves problem #4.

### 10.3 The CodeDeploy pieces

**CodeDeploy** is the AWS service that runs the blue/green choreography. It needs:

| Piece                        | What it is                                                                                                         |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| **Two target groups**        | `tg-blue` and `tg-green`, one per colour                                                                           |
| **Production listener**      | Port 80/443, where real users arrive                                                                               |
| **Test listener** (optional) | For example port 8080, which hits green before the switch                                                          |
| **CodeDeploy application**   | A container with `compute_platform = "ECS"`                                                                        |
| **Deployment group**         | Ties together: cluster + service + both target groups + listeners + rollback rules + a service role for CodeDeploy |
| **Deployment config**        | How traffic shifts (see below)                                                                                     |
| **AppSpec file**             | Per-deployment instructions: which task definition, container, port                                                |
| **ECS service setting**      | `deployment_controller { type = "CODE_DEPLOY" }`                                                                   |

Traffic-shifting options (deployment configs):

| Config                                              | Behaviour                                    |
| --------------------------------------------------- | -------------------------------------------- |
| `CodeDeployDefault.ECSAllAtOnce`                    | 100% to green at once. Simplest; start here. |
| `CodeDeployDefault.ECSCanary10Percent5Minutes`      | 10% to green, wait 5 min, then the rest      |
| `CodeDeployDefault.ECSLinear10PercentEvery1Minutes` | +10% every minute                            |

Minimal ECS `appspec.yaml`:

```yaml
version: 0.0
Resources:
  - TargetService:
      Type: AWS::ECS::Service
      Properties:
        TaskDefinition: <TASK_DEFINITION> # filled in by the pipeline
        LoadBalancerInfo:
          ContainerName: "app"
          ContainerPort: 3000
```

**Automatic rollback:** in the deployment group, enable rollback on `DEPLOYMENT_FAILURE` (and optionally on CloudWatch alarms). If green never passes health checks, users never see it.

> **Note:** ECS also has its own built-in blue/green option now (no CodeDeploy needed). Your course uses CodeDeploy, so follow that. It's still worth knowing the newer option exists.

---

## 11. How the GitHub Actions pipeline changes

| Step                          | Week 7 (EC2)                                  | Week 8 (ECS blue/green)                                                                     |
| ----------------------------- | --------------------------------------------- | ------------------------------------------------------------------------------------------- |
| Lint / test                   | Same                                          | Same                                                                                        |
| Build + push to ECR           | Same                                          | Same                                                                                        |
| Deploy                        | SSH into EC2 → `docker compose pull && up -d` | Render new task definition with the new image → register it → start a CodeDeploy deployment |
| Security group for runner SSH | Needed (and painful)                          | **Gone.** No SSH at all                                                                     |

AWS publishes official actions for this:

- `aws-actions/amazon-ecs-render-task-definition`: puts the new image tag into the task definition JSON
- `aws-actions/amazon-ecs-deploy-task-definition`: registers it and deploys; pass `codedeploy-appspec`, `codedeploy-application`, `codedeploy-deployment-group` for blue/green

The OIDC setup (including your ID-suffixed `sub` claim) stays the same. Only the role's **permissions** grow (section 7).

---

## 12. Terraform resources in build order

Build bottom-up. Each layer depends on the one above it.

| #   | Layer         | Resources                                                                                                                               |
| --- | ------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Network       | `aws_vpc`, `aws_subnet` (2 public + 2 private), `aws_internet_gateway`, `aws_nat_gateway` + `aws_eip`, `aws_route_table` + associations |
| 2   | Security      | `aws_security_group` × 2 (`alb-sg`, `tasks-sg`)                                                                                         |
| 3   | Registry      | `aws_ecr_repository` (or reuse the Week 7 one via `data`)                                                                               |
| 4   | Logs          | `aws_cloudwatch_log_group`                                                                                                              |
| 5   | IAM           | Execution role + policy attachment, task role, CodeDeploy service role (`AWSCodeDeployRoleForECS`)                                      |
| 6   | Load balancer | `aws_lb`, `aws_lb_target_group` × 2 (blue, green; `target_type = "ip"`), `aws_lb_listener` (prod, optional test)                        |
| 7   | ECS           | `aws_ecs_cluster`, `aws_ecs_task_definition`, `aws_ecs_service`                                                                         |
| 8   | Autoscaling   | `aws_appautoscaling_target`, `aws_appautoscaling_policy`                                                                                |
| 9   | Deployments   | `aws_codedeploy_app`, `aws_codedeploy_deployment_group`                                                                                 |
| 10  | DNS           | `aws_route53_record` (alias → ALB), optionally `aws_acm_certificate` + validation                                                       |

---

## 13. Pitfalls

| Pitfall                                       | Symptom                                                                                     | Fix                                                                                                                              |
| --------------------------------------------- | ------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| Private subnet with no NAT or VPC endpoints   | `CannotPullContainerError` / `ResourceInitializationError`                                  | Add a NAT Gateway, or VPC endpoints for `ecr.api`, `ecr.dkr`, `logs`, plus an S3 gateway endpoint                                |
| Public subnet without a public IP             | Same as above                                                                               | `assign_public_ip = true` in `network_configuration`                                                                             |
| Target group `target_type = "instance"`       | Service fails to register targets                                                           | Must be `"ip"` for Fargate                                                                                                       |
| App listens on `localhost` / `127.0.0.1`      | Health checks always fail                                                                   | App must listen on `0.0.0.0`                                                                                                     |
| Health check path returns 301/404             | Tasks are killed in a loop                                                                  | Add a real `/health` route returning 200, or adjust `matcher`                                                                    |
| No grace period, slow app startup             | New tasks killed before they finish booting                                                 | Set `health_check_grace_period_seconds` (e.g. 60–120)                                                                            |
| `CODE_DEPLOY` controller vs `terraform apply` | Terraform tries to "fix" the task definition or target group CodeDeploy switched, or errors | `lifecycle { ignore_changes = [task_definition, load_balancer] }` on the service                                                 |
| Autoscaling vs Terraform                      | Every apply resets the task count                                                           | `ignore_changes = [desired_count]` too                                                                                           |
| Execution role vs task role confusion         | See section 7                                                                               | Before code runs → execution role; during → task role                                                                            |
| Invalid CPU/memory pair                       | Task definition rejected                                                                    | Use a valid Fargate combination (e.g. 256/512, 512/1024)                                                                         |
| Image built for ARM (e.g. Apple Silicon)      | `exec format error`                                                                         | Build `linux/amd64`, or set `runtime_platform` to ARM64                                                                          |
| MongoDB running as a Fargate task             | Data lost whenever the task is replaced; scaling creates multiple separate DBs              | Keep the database outside the service: MongoDB Atlas, DocumentDB, or (for learning only) a separate single task with EFS storage |
| Forgetting running costs                      | Bill grows while idle                                                                       | ALB and NAT Gateway bill hourly. Run `terraform destroy` when done for the day                                                   |

---

## 14. Hands-on learning order

Don't build everything at once. Each step adds one idea and proves it works.

- [ ] **Step 1: one Fargate task, no ALB.** Cluster + task definition + service with `desired_count = 1`, public subnet, `assign_public_ip = true`. Hit `http://<task-public-ip>:3000`. _Proves: task definitions, Fargate, logs._
- [ ] **Step 2: ALB + 2 tasks across 2 AZs.** Tasks move to private subnets behind the ALB. Stop a task in the console and watch the service replace it. _Proves: self-healing and load balancing (problems 1 and 2)._
- [ ] **Step 3: autoscaling.** Add the scaling target and policy, load-test (e.g. `hey` or `ab`), and watch tasks appear and disappear. _Proves: problem 3._
- [ ] **Step 4: blue/green with CodeDeploy.** Second target group, switch the service to `CODE_DEPLOY`, and run one deployment by hand. Then deploy a deliberately broken image and watch the automatic rollback. _Proves: problem 4._
- [ ] **Step 5: GitHub Actions.** Replace the SSH deploy job with the ECS/CodeDeploy actions.
- [ ] **Step 6: DNS + HTTPS.** Point `ebotprog.ink` at the ALB, add an ACM certificate and a 443 listener.

---

## 15. Glossary

| Term                         | Plain meaning                                                               |
| ---------------------------- | --------------------------------------------------------------------------- |
| **ECS**                      | AWS service that runs and supervises containers                             |
| **Fargate**                  | Run containers without managing any servers                                 |
| **Cluster**                  | Named group that holds services and tasks                                   |
| **Task definition**          | Versioned recipe for a task (like `docker-compose.yml`)                     |
| **Revision**                 | One version of a task definition (`app:14`)                                 |
| **Task**                     | One running copy of a task definition                                       |
| **Service**                  | Keeps N healthy tasks running and registers them with the ALB               |
| **awsvpc**                   | Network mode where each task gets its own IP                                |
| **ENI**                      | Elastic Network Interface, a virtual network card with an IP                |
| **ALB**                      | Application Load Balancer, which spreads HTTP traffic across targets        |
| **Listener**                 | ALB "front door" on a port (80/443)                                         |
| **Target group**             | List of backends a listener forwards to                                     |
| **Health check**             | Repeated test that decides if a target gets traffic                         |
| **NAT Gateway**              | Lets private-subnet resources reach the internet outbound only              |
| **VPC endpoint**             | Private path from your VPC to an AWS service, without the internet          |
| **Execution role**           | IAM role ECS uses to start your task                                        |
| **Task role**                | IAM role your app code uses while running                                   |
| **Application Auto Scaling** | AWS service that adjusts the task count                                     |
| **Target tracking**          | "Keep metric X near value Y" scaling                                        |
| **Cooldown**                 | Waiting period between scaling actions                                      |
| **Rolling update**           | Replace tasks gradually; old and new mix during the rollout                 |
| **Blue/green**               | Run new version alongside old, then switch traffic all at once              |
| **CodeDeploy**               | AWS service that runs blue/green deployments                                |
| **AppSpec**                  | File telling CodeDeploy which task definition, container and port to deploy |
| **ACM**                      | AWS Certificate Manager, free TLS certificates for the ALB                  |

---

## 16. Sources

- [Amazon ECS Developer Guide](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/Welcome.html)
- [ECS blue/green deployments with CodeDeploy](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/deployment-type-bluegreen.html)
- [Tutorial: Creating a service using a blue/green deployment](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/create-blue-green.html)
- [ECS service auto scaling](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/service-auto-scaling.html)
- [Blue/Green deployments to Amazon ECS — AWS DevOps Blog](https://aws.amazon.com/blogs/devops/blue-green-deployments-to-amazon-ecs-using-aws-cloudformation-and-aws-codedeploy/)
