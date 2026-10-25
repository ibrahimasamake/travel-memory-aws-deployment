# Travel Memory – MERN Application Deployment on AWS

**Graded Assignment – Travel Memory Application Deployment**
Student: **Ibrahima Samake** · Programme: PPMCAD – Multi Cloud Architecture & DevOps (Hero Vired)

| | |
|---|---|
| **Live application** | https://travelmemory.samibrahima.tech |
| **AWS region** | ap-south-1 (Asia Pacific – Mumbai) |
| **Stack** | MongoDB Atlas · Express / Node.js · React · Nginx · pm2 |
| **AWS services** | EC2, AMI, Launch Templates, Auto Scaling, Application Load Balancer (public + internal), VPC, NAT Gateway, ACM |
| **IaC** | Terraform ([`infra/terraform`](infra/terraform)) |
| **DNS** | Cloudflare (`samibrahima.tech`) |
| **Full report** | [PDF](docs/TravelMemory-Deployment-Documentation.pdf) · [Word](docs/TravelMemory-Deployment-Documentation.docx) |

The application code comes from [UnpredictablePrashant/TravelMemory](https://github.com/UnpredictablePrashant/TravelMemory). This repository contains that code with the deployment changes applied, the Terraform code, the Nginx configuration, the architecture diagram, and a step-by-step explanation with screenshots.

---

## Table of contents

1. [Repository structure](#1-repository-structure)
2. [Architecture](#2-architecture)
3. [Requirement checklist](#3-requirement-checklist)
4. [Task 1 – Backend configuration and Nginx reverse proxy](#4-task-1--backend-configuration-and-nginx-reverse-proxy)
5. [Task 2 – Frontend and backend connection](#5-task-2--frontend-and-backend-connection)
6. [Task 3 – Scaling the application](#6-task-3--scaling-the-application)
7. [Task 4 – Custom domain with Cloudflare](#7-task-4--custom-domain-with-cloudflare)
8. [Security, scalability and resilience](#8-security-scalability-and-resilience)
9. [Issues met and fixes](#9-issues-met-and-fixes)
10. [How to reproduce](#10-how-to-reproduce)

---

## 1. Repository structure

```
.
├── backend/                 # Node.js / Express API (port 3001)
│   └── .env.example         # MONGO_URI + PORT template (real .env is git-ignored)
├── frontend/                # React app
│   └── src/url.js           # baseUrl -> https://travelmemory.samibrahima.tech
├── infra/
│   ├── terraform/           # VPC, subnets, IGW, NAT, SGs, ALBs, launch templates, ASGs
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── terraform.tfvars.example
│   └── nginx/
│       └── travelmemory.conf   # reverse proxy used on every frontend instance
└── docs/
    ├── TravelMemory-Architecture.drawio   # draw.io source of the diagram
    ├── TravelMemory-Architecture.png
    ├── TravelMemory-Deployment-Documentation.pdf
    ├── TravelMemory-Deployment-Documentation.docx
    └── screenshots/                       # 30 screenshots referenced below
```

---

## 2. Architecture

![Deployment architecture](docs/TravelMemory-Architecture.png)

*The editable diagram is [`docs/TravelMemory-Architecture.drawio`](docs/TravelMemory-Architecture.drawio). Open it at [app.diagrams.net](https://app.diagrams.net).*

**Request flow**

1. The browser resolves `travelmemory.samibrahima.tech` through **Cloudflare DNS** (CNAME → public ALB).
2. The **internet-facing ALB `my-app-alb`** terminates HTTPS on 443 with an **ACM** certificate and forwards to `app-target-group`, which holds the frontend instances.
3. On each **frontend EC2** instance, **Nginx :80** serves the React app (proxy to `localhost:3000`) and forwards every `/trip` API call to the internal backend ALB.
4. The **internal ALB `my-app-backend-alb` :3001** spreads API calls over the **backend EC2** instances in **private subnets** (Express on port 3001).
5. The backend reads and writes **MongoDB Atlas**. Outbound traffic from the private subnets leaves through the **NAT Gateway**.

| Component | Details |
|---|---|
| VPC | `10.0.0.0/16`, DNS hostnames enabled |
| Public subnets | `10.0.1.0/24` (ap-south-1a), `10.0.3.0/24` (ap-south-1c): ALB, frontend instances, NAT Gateway |
| Private subnets | `10.0.2.0/24` (ap-south-1a), `10.0.6.0/24` (ap-south-1c): backend instances, no public IP |
| `my-app-alb` | Internet-facing, HTTP:80 → HTTPS redirect, HTTPS:443 (TLS 1.3/1.2 policy) → frontend target group |
| `my-app-backend-alb` | Internal, HTTP:3001 → backend target group (health check `/hello`) |
| Auto Scaling groups | `my-app-asg` (frontend) and `my-app-backend-asg` (backend): min 2 / desired 2 / max 4, CPU target tracking at 50% |
| Instance type | t3.micro, Ubuntu, IMDSv2 required |

---

## 3. Requirement checklist

| Assignment requirement | Where |
|---|---|
| Clone the repo and go to the backend | [§4.2](#42-install-packages-and-clone-the-repository) |
| Backend port + Nginx reverse proxy on EC2 | [§4.4](#44-run-the-backend-with-pm2), [§4.5](#45-nginx-reverse-proxy), [`infra/nginx/travelmemory.conf`](infra/nginx/travelmemory.conf) |
| Update `.env` with DB connection and port | [§4.3](#43-configure-the-env-file), [`backend/.env.example`](backend/.env.example) |
| Update `urls.js` so the frontend talks to the backend | [§5.1](#51-update-urljs), [`frontend/src/url.js`](frontend/src/url.js) |
| Multiple frontend and backend instances | [§6](#6-task-3--scaling-the-application) |
| Instances behind a load balancer | [§6.5](#65-load-balancers) |
| Cloudflare CNAME → load balancer | [§7.3](#73-cname-record--load-balancer) |
| Cloudflare A record → frontend EC2 IP | [§7.4](#74-a-record--frontend-ec2-instance) |
| Documentation with screenshots + draw.io diagram | this README, [`docs/`](docs) |

---

## 4. Task 1 – Backend configuration and Nginx reverse proxy

### 4.1 Launch the EC2 instances

Two Ubuntu instances were launched: **Travel-Agency-Frontend** in a public subnet (public IP `13.201.121.187`) and **Travel-Agence-Backend** in a private subnet (private IP `10.0.1.9`, no public IP). Because the backend is private, the API is never directly reachable from the internet.

![Frontend instance](docs/screenshots/01-frontend-instance-public-subnet.png)
*Frontend instance – public subnet with a public IPv4 address*

![Backend instance](docs/screenshots/02-backend-instance-private-subnet.png)
*Backend instance – private subnet, private IP only*

### 4.2 Install packages and clone the repository

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y nodejs npm git nginx
git clone https://github.com/UnpredictablePrashant/TravelMemory.git
cd TravelMemory/backend
npm install
```

![git clone](docs/screenshots/03-git-clone-backend.png)
*Repository cloned; the backend folder contains `index.js`, `conn.js`, `controllers/`, `models/` and `routes/`*

### 4.3 Configure the `.env` file

The backend reads its settings from `backend/.env` (see [`backend/.env.example`](backend/.env.example)). The React development server already uses port 3000 on the frontend instance, so the API runs on **3001**:

```env
MONGO_URI=mongodb+srv://<db_user>:<db_password>@<cluster-host>/travelmemory?retryWrites=true&w=majority
PORT=3001
```

> The real `.env` is git-ignored and exists only on the server.

### 4.4 Run the backend with pm2

pm2 keeps the API running, restarts it if it crashes, and starts it again after a reboot.

```bash
sudo npm install -g pm2
pm2 start index.js --name my-backend
pm2 logs my-backend          # Server started at http://localhost:3001
pm2 save && pm2 startup
```

![pm2 start](docs/screenshots/04-pm2-start-backend.png)
*Backend started with pm2 – status `online`*

![backend running](docs/screenshots/05-backend-running-port-3001.png)
*pm2 logs: `Server started at http://localhost:3001`*

### 4.5 Nginx reverse proxy

Nginx on the frontend instance is the single entry point on port 80. `/trip` (the API path) goes to the backend on 3001, and everything else goes to the React app on 3000. In Phase 1 the backend was a single private instance:

```nginx
server {
    listen 80 default_server;
    server_name _;

    location /trip {
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_pass http://10.0.1.9:3001;      # backend private IP (Phase 1)
    }

    location / {
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_pass http://localhost:3000;     # React app
    }
}
```

```bash
sudo nginx -t && sudo systemctl restart nginx && sudo systemctl enable nginx
```

![nginx phase 1](docs/screenshots/06-nginx-reverse-proxy-phase1.png)
*Editing the Nginx default site: `/trip` → backend:3001, `/` → React:3000*

After scaling (§6), `proxy_pass` points to the **internal ALB** instead of one IP. The final file is [`infra/nginx/travelmemory.conf`](infra/nginx/travelmemory.conf).

---

## 5. Task 2 – Frontend and backend connection

### 5.1 Update `url.js`

Every API call in the React app uses `baseUrl` from `frontend/src/url.js`. Because Nginx proxies `/trip`, `baseUrl` only needs to point at the public entry point. It changed with each phase:

| Phase | `baseUrl` |
|---|---|
| Single instance | `http://13.201.121.187` (frontend public IP) |
| Load balanced | `http://my-app-alb-…ap-south-1.elb.amazonaws.com` |
| **Final** | **`https://travelmemory.samibrahima.tech`** |

```js
// frontend/src/url.js
export const baseUrl = process.env.REACT_APP_BACKEND_URL || "https://travelmemory.samibrahima.tech";
```

### 5.2 Start the frontend

```bash
cd ~/TravelMemory/frontend
npm install
pm2 start npm --name frontend -- start     # React on :3000
pm2 save && pm2 startup
```

![frontend pm2](docs/screenshots/07-frontend-pm2-running.png)
*React app compiled and running under pm2*

### 5.3 Verification

The `trip/` XHR request returns **200**. The response headers show `Server: nginx` and `X-Powered-By: Express`, so the request went through Nginx to the Express API.

![app on public IP](docs/screenshots/08-app-on-public-ip-trip-api-200.png)
*App on the frontend public IP – `trip/` returns 200*

![headers](docs/screenshots/09-response-headers-nginx-express.png)
*Response headers: Nginx (proxy) + Express (backend)*

![details](docs/screenshots/10-experience-details-page.png)
*Experience details page loaded from MongoDB*

---

## 6. Task 3 – Scaling the application

### 6.1 AMIs

Once both instances worked, an AMI was created from each one. New instances start from these images with Node.js, the code, pm2 and Nginx already set up.

![AMIs](docs/screenshots/11-amis.png)

### 6.2 Launch templates

![Launch templates](docs/screenshots/12-launch-templates.png)
*`Travel-Agency-*` templates were built in the console; `app-template-my-*` templates are created by Terraform*

### 6.3 First Auto Scaling groups (console)

![console ASGs](docs/screenshots/13-console-auto-scaling-groups.png)
*Console ASGs – 2/2 healthy each*

![multiple instances](docs/screenshots/14-multiple-instances-running.png)
*Several frontend and backend instances running*

### 6.4 Infrastructure as Code with Terraform

The whole stack was then rewritten in Terraform ([`infra/terraform`](infra/terraform)) so it can be recreated with one command:

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars   # fill in your values
terraform init
terraform plan -out tfplan
terraform apply tfplan
terraform output        # alb_dns_name, backend_alb_dns_name, subnet IDs ...
```

![main.tf](docs/screenshots/15-terraform-main-vpc.png)
*`main.tf` – provider and VPC*

![variables.tf](docs/screenshots/16-terraform-variables.png)
*`variables.tf` – region and CIDR blocks*

![private subnets](docs/screenshots/17-terraform-private-subnets-nat.png)
*Private subnets in two AZs and the NAT Gateway Elastic IP*

![outputs.tf](docs/screenshots/18-terraform-outputs-file.png)

![terraform output](docs/screenshots/19-terraform-output-and-ssh.png)
*`terraform output` and SSH into a frontend instance launched by the ASG*

### 6.5 Load balancers

| Load balancer | Scheme | Listener | Target |
|---|---|---|---|
| `my-app-alb` | internet-facing | 80 (→ 443), 443 HTTPS | frontend instances :80 |
| `my-app-backend-alb` | **internal** | 3001 | backend instances :3001 |

![load balancers](docs/screenshots/20-load-balancers.png)

### 6.6 Auto Scaling groups and instances

![ASGs](docs/screenshots/21-terraform-auto-scaling-groups.png)
*`my-app-asg` and `my-app-backend-asg` – desired 2, min 2, max 4*

![instances](docs/screenshots/22-asg-instances.png)
*Instances launched by the ASGs. Frontend instances have public IPs; backend instances are private. Terminated rows were replaced by the ASG.*

### 6.7 Connecting the tiers through the load balancers

Instances come and go, so no file contains an instance IP:

- `url.js` → public ALB (later the custom domain)
- Nginx `/trip` → DNS name of the **internal** backend ALB

![url.js ALB](docs/screenshots/23-url-js-alb.png)

![nginx internal ALB](docs/screenshots/24-nginx-proxy-internal-alb.png)
*`proxy_pass http://internal-my-app-backend-alb-….elb.amazonaws.com:3001`*

### 6.8 Verification through the ALB

![app via ALB](docs/screenshots/25-app-via-alb.png)

---

## 7. Task 4 – Custom domain with Cloudflare

### 7.1 ACM certificate

A public certificate for `travelmemory.samibrahima.tech` was requested in ACM with DNS validation. The validation CNAME was added in Cloudflare (set to DNS only), and the certificate changed to **Issued**.

![ACM](docs/screenshots/26-acm-certificates.png)

### 7.2 HTTPS listener on the ALB

![listeners](docs/screenshots/27-alb-https-listener.png)
*HTTP:80 and HTTPS:443 with the ACM certificate*

### 7.3 CNAME record → load balancer

| Type | Name | Target | Proxy |
|---|---|---|---|
| CNAME | `travelmemory` | `my-app-alb-792164788.ap-south-1.elb.amazonaws.com` | DNS only |

A CNAME is required because an ALB has no fixed IP address; only its DNS name is stable.

![cloudflare](docs/screenshots/28-cloudflare-dns-cname.png)

### 7.4 A record → frontend EC2 instance

| Type | Name | IPv4 address | Proxy |
|---|---|---|---|
| A | `frontend` | public IP of a frontend instance (e.g. `13.235.31.171`) | DNS only |

> Instances in an ASG get a new IP when they are replaced. For a stable A record, attach an **Elastic IP** to the target instance. User traffic should always go through the CNAME and the load balancer.

### 7.5 Frontend points to the domain

![url.js domain](docs/screenshots/29-url-js-custom-domain.png)
*`baseUrl = "https://travelmemory.samibrahima.tech"` – the ALB can now be recreated without touching the code*

### 7.6 Final result

![custom domain](docs/screenshots/30-app-on-custom-domain.png)
*Travel Memory served at **https://travelmemory.samibrahima.tech***

---

## 8. Security, scalability and resilience

| Area | What is done |
|---|---|
| Network isolation | Backend instances are in private subnets with no public IP; egress goes only through the NAT Gateway |
| Security-group chain | Internet → `alb-sg` (80/443) → `frontend-sg` (80 from ALB only, SSH from one admin IP) → `alb-backend-sg` (3001 from frontend only) → `backend-sg` (3001 from internal ALB only, SSH from frontend as jump host) |
| Encryption | HTTPS with an ACM certificate and the `ELBSecurityPolicy-TLS13-1-2-2021-06` policy; HTTP is redirected to HTTPS; MongoDB Atlas uses TLS |
| Secrets | `.env`, `*.pem`, `terraform.tfvars` and `*.tfstate` are git-ignored |
| Instance hardening | IMDSv2 required on both launch templates |
| Scalability | Two ASGs (2–4 instances) with CPU target-tracking policies at 50% |
| Resilience | ALBs and ASGs span two Availability Zones; ELB health checks replace unhealthy instances; pm2 restarts crashed processes |
| Reproducibility | All infrastructure is defined in Terraform |
| Loose coupling | Code contains no instance IPs: the frontend calls the domain, and Nginx calls the internal ALB DNS name |

**Possible next steps:** serve `npm run build` output from Nginx instead of the React dev server; keep `MONGO_URI` in SSM Parameter Store; use a remote S3 backend for Terraform state; enable Cloudflare proxying with Full (strict) SSL.

---

## 9. Issues met and fixes

The last six rows were found while reviewing the Terraform code for this submission. They are fixed in [`infra/terraform`](infra/terraform) (`terraform validate` passes) and take effect on the next `terraform apply`.

| Problem | Cause | Fix |
|---|---|---|
| `pm2: Script not found …/server.js` | The entry point is `index.js` | `pm2 start index.js --name my-backend` |
| `my-backend` errored with `MODULE_NOT_FOUND` | Dependencies were not installed | `npm install` in `backend/` |
| Port clash with React | React and the API both default to 3000 | `PORT=3001` in `.env` |
| Frontend broke after the ALB was recreated | `url.js` held the old ALB DNS name | `url.js` points to the custom domain; only the CNAME changes |
| Backend target always **unhealthy** | Health check on `/`, but the API has no `/` route (404) | Health check on `/hello` |
| Backend ASG registered in the frontend target group | `target_group_arns` referenced `app_tg` | Points to `app_backend_tg` |
| ALB "reachability may be impacted" | Second public subnet had no route to the IGW | Added `aws_route_table_association.public_2` (and `private_2` → NAT) |
| HTTPS listener/SG on port 403, no certificate | Typo, missing `certificate_arn` | Port 443 + `ssl_policy` + `acm_certificate_arn` variable |
| ASGs used one subnet only | `vpc_zone_identifier` had one subnet | Both AZ subnets for each tier |
| Backend SG open to 0.0.0.0/0 on 3001 | Instances reused the ALB security group | Dedicated `backend_sg` that only accepts traffic from the internal ALB |

---

## 10. How to reproduce

1. Build the two instances as in §4–5 and create an AMI from each.
2. Request an ACM certificate for your domain and validate it in Cloudflare.
3. `cd infra/terraform && cp terraform.tfvars.example terraform.tfvars`, set the AMI IDs, key pair, your IP and the certificate ARN.
4. Run `terraform init && terraform apply`.
5. Update `proxy_pass` in Nginx with `terraform output backend_alb_dns_name` and bake it into the frontend AMI.
6. In Cloudflare, create the CNAME to `terraform output alb_dns_name` and the A record to a frontend instance's public IP.
7. Open `https://<your-domain>`.
8. When finished, run `terraform destroy` to avoid charges.

---

*Application source: [UnpredictablePrashant/TravelMemory](https://github.com/UnpredictablePrashant/TravelMemory) (see [LICENSE](LICENSE)). Deployment, infrastructure and documentation: Ibrahima Samake.*
