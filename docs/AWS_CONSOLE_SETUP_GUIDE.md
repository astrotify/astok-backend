# 🖥️ Hướng Dẫn Setup AWS Trực Tiếp Trên Console

Hướng dẫn từng bước setup infrastructure cho Astok Backend trên AWS Console (Web UI).

## 📋 Mục Lục

1. [IAM User cho CI/CD](#1-iam-user-cho-cicd)
2. [ECR Repositories](#2-ecr-repositories)
3. [VPC và Networking](#3-vpc-và-networking)
4. [Security Groups](#4-security-groups)
5. [RDS PostgreSQL](#5-rds-postgresql)
6. [ECS Cluster](#6-ecs-cluster)
7. [Application Load Balancer](#7-application-load-balancer)
8. [Service Discovery](#8-service-discovery)
9. [ECS Task Definitions](#9-ecs-task-definitions)
10. [ECS Services](#10-ecs-services)
11. [Kiểm Tra và Test](#11-kiểm-tra-và-test)

---

## 1. IAM User cho CI/CD

### 1.1 Tạo IAM User

1. Truy cập **IAM Console**: https://console.aws.amazon.com/iam/
2. Click **Users** → **Create user**
3. Điền thông tin:
   - **User name**: `github-astro`
   - ✅ Check **Provide user access to the AWS Management Console** (optional)
4. Click **Next**

### 1.2 Tạo Policy

1. Trong bước **Set permissions**, chọn **Attach policies directly**
2. Click **Create policy** (mở tab mới)
3. Chọn tab **JSON** và paste:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:PutImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecs:DescribeServices",
        "ecs:DescribeTaskDefinition",
        "ecs:RegisterTaskDefinition",
        "ecs:UpdateService",
        "ecs:RunTask",
        "ecs:DescribeTasks",
        "ecs:StopTask",
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:GetLogEvents",
        "iam:PassRole"
      ],
      "Resource": "*"
    }
  ]
}
```

4. Click **Next**
5. **Policy name**: `GitHubActionsECSDeployPolicy`
6. Click **Create policy**

### 1.3 Attach Policy và Tạo Access Key

1. Quay lại tab tạo user
2. Refresh và tìm `GitHubActionsECSDeployPolicy`, check vào
3. Click **Next** → **Create user**
4. Click vào user vừa tạo → **Security credentials**
5. Scroll xuống **Access keys** → **Create access key**
6. Chọn **Command Line Interface (CLI)**
7. ✅ Check confirmation → **Next** → **Create access key**
8. **⚠️ LƯU LẠI Access key và Secret access key** (chỉ hiển thị 1 lần!)

---

## 2. ECR Repositories

### 2.1 Tạo Repository cho API Gateway

1. Truy cập **ECR Console**: https://console.aws.amazon.com/ecr/
2. Click **Create repository**
3. Điền:
   - **Visibility**: Private
   - **Repository name**: `astok-api`
   - **Image tag mutability**: Mutable
   - ✅ **Scan on push**: Enabled
4. Click **Create repository**

### 2.2 Tạo Repository cho Order Service

Lặp lại bước trên với:

- **Repository name**: `astok-order-service`

### 2.3 Tạo Repository cho Migrations

Lặp lại bước trên với:

- **Repository name**: `astok-order-migrate`

---

## 3. VPC và Networking

### 3.1 Tạo VPC

1. Truy cập **VPC Console**: https://console.aws.amazon.com/vpc/
2. Click **Create VPC**
3. Chọn **VPC and more** (tạo wizard)
4. Điền:
   - **Name tag auto-generation**: `astok`
   - **IPv4 CIDR block**: `10.0.0.0/16`
   - **Number of Availability Zones**: `2`
   - **Number of public subnets**: `2`
   - **Number of private subnets**: `2`
   - **NAT gateways**: `None` (tiết kiệm chi phí, dùng VPC Endpoints)
   - **VPC endpoints**: `None` (sẽ tạo riêng)
5. Click **Create VPC**

### 3.2 Ghi Lại Thông Tin

Sau khi tạo xong, ghi lại:

- **VPC ID**: `vpc-xxxxxxxxx`
- **Public Subnet 1**: `subnet-xxxxxxxxx` (AZ: ap-southeast-1a)
- **Public Subnet 2**: `subnet-xxxxxxxxx` (AZ: ap-southeast-1b)
- **Private Subnet 1**: `subnet-xxxxxxxxx` (AZ: ap-southeast-1a)
- **Private Subnet 2**: `subnet-xxxxxxxxx` (AZ: ap-southeast-1b)

### 3.3 Tạo VPC Endpoints

> ⚠️ **QUAN TRỌNG**: VPC Endpoints cho phép ECS tasks trong private subnets kết nối ECR và CloudWatch mà không cần NAT Gateway.

#### ECR API Endpoint:

1. **VPC Console** → **Endpoints** → **Create endpoint**
2. Điền:
   - **Name tag**: `astok-ecr-api`
   - **Service category**: AWS services
   - **Services**: Tìm và chọn `com.amazonaws.ap-southeast-1.ecr.api`
   - **VPC**: Chọn VPC vừa tạo
   - **Subnets**: Chọn **Private subnets** ở cả 2 AZs
   - **Security groups**: Chọn default hoặc tạo mới (cho phép HTTPS 443)
3. Click **Create endpoint**

#### ECR DKR Endpoint:

Lặp lại với service: `com.amazonaws.ap-southeast-1.ecr.dkr`

#### CloudWatch Logs Endpoint:

Lặp lại với service: `com.amazonaws.ap-southeast-1.logs`

#### S3 Gateway Endpoint:

1. **Create endpoint**
2. Chọn service: `com.amazonaws.ap-southeast-1.s3` (Type: Gateway)
3. **VPC**: Chọn VPC
4. **Route tables**: Chọn route table của **Private subnets**
5. Click **Create endpoint**

---

## 4. Security Groups

### 4.1 Security Group cho ALB

1. **VPC Console** → **Security Groups** → **Create security group**
2. Điền:
   - **Name**: `astok-alb-sg`
   - **Description**: Security group for ALB
   - **VPC**: Chọn VPC đã tạo
3. **Inbound rules** → **Add rule**:
   | Type | Protocol | Port | Source | Description |
   |------|----------|------|--------|-------------|
   | HTTP | TCP | 80 | 0.0.0.0/0 | Public HTTP |
   | HTTPS | TCP | 443 | 0.0.0.0/0 | Public HTTPS |
4. **Outbound rules**: Giữ mặc định (All traffic)
5. Click **Create security group**

### 4.2 Security Group cho API Gateway

1. **Create security group**
2. Điền:
   - **Name**: `astok-api-gateway-sg`
   - **Description**: Security group for API Gateway
   - **VPC**: Chọn VPC
3. **Inbound rules**:
   | Type | Protocol | Port | Source | Description |
   |------|----------|------|--------|-------------|
   | Custom TCP | TCP | 3000 | astok-alb-sg | From ALB |
4. **Outbound rules**:
   | Type | Protocol | Port | Destination | Description |
   |------|----------|------|-------------|-------------|
   | HTTPS | TCP | 443 | 0.0.0.0/0 | ECR, CloudWatch |
   | Custom TCP | TCP | 5001 | astok-order-service-sg | To Order Service |
5. Click **Create security group**

### 4.3 Security Group cho Order Service

1. **Create security group**
2. Điền:
   - **Name**: `astok-order-service-sg`
   - **Description**: Security group for Order Service
   - **VPC**: Chọn VPC
3. **Inbound rules**:
   | Type | Protocol | Port | Source | Description |
   |------|----------|------|--------|-------------|
   | Custom TCP | TCP | 5001 | astok-api-gateway-sg | gRPC from API Gateway |
4. **Outbound rules**:
   | Type | Protocol | Port | Destination | Description |
   |------|----------|------|-------------|-------------|
   | HTTPS | TCP | 443 | 0.0.0.0/0 | ECR, CloudWatch |
   | PostgreSQL | TCP | 5432 | 10.0.0.0/16 | To RDS |
5. Click **Create security group**

### 4.4 Security Group cho RDS

1. **Create security group**
2. Điền:
   - **Name**: `astok-rds-sg`
   - **Description**: Security group for RDS
   - **VPC**: Chọn VPC
3. **Inbound rules**:
   | Type | Protocol | Port | Source | Description |
   |------|----------|------|--------|-------------|
   | PostgreSQL | TCP | 5432 | 10.0.0.0/16 | From VPC |
4. Click **Create security group**

### 4.5 Security Group cho VPC Endpoints

1. **Create security group**
2. Điền:
   - **Name**: `astok-vpce-sg`
   - **Description**: Security group for VPC Endpoints
   - **VPC**: Chọn VPC
3. **Inbound rules**:
   | Type | Protocol | Port | Source | Description |
   |------|----------|------|--------|-------------|
   | HTTPS | TCP | 443 | 10.0.0.0/16 | From VPC |
4. Click **Create security group**
5. **Cập nhật VPC Endpoints**: Quay lại VPC Endpoints, chỉnh sửa từng endpoint và thay security group thành `astok-vpce-sg`

---

## 5. RDS PostgreSQL

### 5.1 Tạo DB Subnet Group

1. Truy cập **RDS Console**: https://console.aws.amazon.com/rds/
2. **Subnet groups** → **Create DB subnet group**
3. Điền:
   - **Name**: `astok-db-subnet-group`
   - **Description**: Subnet group for Astok RDS
   - **VPC**: Chọn VPC
   - **Availability Zones**: Chọn cả 2 AZs
   - **Subnets**: Chọn **Private subnets** (2 subnets)
4. Click **Create**

### 5.2 Tạo RDS Instance

1. **Databases** → **Create database**
2. Chọn:
   - **Database creation method**: Standard create
   - **Engine type**: PostgreSQL
   - **Engine version**: PostgreSQL 15.x
   - **Templates**: Free tier (hoặc Dev/Test)
3. **Settings**:
   - **DB instance identifier**: `astok-orderdb`
   - **Master username**: `postgres`
   - **Master password**: `YourSecurePassword123!` (ghi lại!)
4. **Instance configuration**:
   - **DB instance class**: db.t3.micro
5. **Storage**:
   - **Allocated storage**: 20 GB
   - ❌ **Storage autoscaling**: Disable (tiết kiệm)
6. **Connectivity**:
   - **VPC**: Chọn VPC đã tạo
   - **DB subnet group**: `astok-db-subnet-group`
   - **Public access**: **No**
   - **VPC security group**: Chọn `astok-rds-sg`
7. **Additional configuration**:
   - **Initial database name**: `orderdb`
   - **Backup retention period**: 7 days
8. Click **Create database**

> ⏳ RDS mất khoảng 5-10 phút để tạo. Sau khi tạo xong, ghi lại **Endpoint** (vd: `astok-orderdb.xxxx.ap-southeast-1.rds.amazonaws.com`)

---

## 6. ECS Cluster

### 6.1 Tạo Cluster

1. Truy cập **ECS Console**: https://console.aws.amazon.com/ecs/
2. Click **Create cluster**
3. Điền:
   - **Cluster name**: `astok-cluster`
   - **Infrastructure**: ✅ **AWS Fargate (serverless)**
4. Click **Create**

---

## 7. Application Load Balancer

### 7.1 Tạo Target Group

1. Truy cập **EC2 Console** → **Target Groups**: https://console.aws.amazon.com/ec2/v2/home#TargetGroups
2. Click **Create target group**
3. **Basic configuration**:
   - **Target type**: IP addresses
   - **Target group name**: `astok-api-gateway-tg`
   - **Protocol**: HTTP, **Port**: 3000
   - **VPC**: Chọn VPC
4. **Health checks**:
   - **Health check protocol**: HTTP
   - **Health check path**: `/api/health`
   - Click **Advanced health check settings**:
     - **Healthy threshold**: 2
     - **Unhealthy threshold**: 3
     - **Timeout**: 10 seconds
     - **Interval**: 30 seconds
     - **Success codes**: 200
5. Click **Next** → **Create target group** (không cần register targets)

### 7.2 Tạo ALB

1. **EC2 Console** → **Load Balancers** → **Create load balancer**
2. Chọn **Application Load Balancer** → **Create**
3. **Basic configuration**:
   - **Load balancer name**: `astok-alb`
   - **Scheme**: Internet-facing
   - **IP address type**: IPv4
4. **Network mapping**:
   - **VPC**: Chọn VPC
   - **Mappings**: Chọn cả 2 AZs và **Public subnets**
5. **Security groups**:
   - Remove default
   - Add `astok-alb-sg`
6. **Listeners and routing**:
   - **Protocol**: HTTP, **Port**: 80
   - **Default action**: Forward to `astok-api-gateway-tg`
7. Click **Create load balancer**

> Ghi lại **DNS name** của ALB (vd: `astok-alb-xxxx.ap-southeast-1.elb.amazonaws.com`)

---

## 8. Service Discovery

### 8.1 Tạo Namespace

1. Truy cập **Cloud Map Console**: https://console.aws.amazon.com/cloudmap/
2. Click **Create namespace**
3. Điền:
   - **Namespace name**: `astok.local`
   - **Namespace description**: Private namespace for Astok services
   - **Instance discovery**: API calls and DNS queries in VPCs
   - **VPC**: Chọn VPC đã tạo
4. Click **Create namespace**

### 8.2 Tạo Service

1. Click vào namespace `astok.local`
2. Click **Create service**
3. Điền:
   - **Service name**: `order-service`
   - **Service description**: Order Service discovery
   - **DNS configuration**:
     - **Routing policy**: Weighted routing
     - **DNS records**: A record, TTL: 60
   - **Health check options**: No health check
4. Click **Create service**

> Sau khi tạo, Order Service sẽ được truy cập qua: `order-service.astok.local`

---

## 9. ECS Task Definitions

### 9.1 Task Definition cho API Gateway

1. **ECS Console** → **Task definitions** → **Create new task definition**
2. **Task definition configuration**:
   - **Task definition family**: `astok-api-gateway`
   - **Launch type**: AWS Fargate
   - **Operating system/Architecture**: Linux/X86_64
   - **CPU**: 0.25 vCPU
   - **Memory**: 0.5 GB
   - **Task role**: None
   - **Task execution role**: Create new role hoặc chọn `ecsTaskExecutionRole`
3. **Container - 1**:
   - **Name**: `api-gateway`
   - **Image URI**: `<account-id>.dkr.ecr.ap-southeast-1.amazonaws.com/astok-api:latest`
   - **Port mappings**: Container port `3000`, Protocol `TCP`
   - **Environment variables**:
     | Key | Value |
     |-----|-------|
     | PORT | 3000 |
     | ORDER_SERVICE_GRPC_HOST | order-service.astok.local |
     | ORDER_SERVICE_GRPC_PORT | 5001 |
     | CORS_ORIGIN | \* |
   - **HealthCheck** (expand):
     - Command: `CMD-SHELL, curl -f -s http://localhost:3000/api/health > /dev/null || exit 1`
     - Interval: 30
     - Timeout: 10
     - Start period: 90
     - Retries: 3
   - **Logging**:
     - ✅ Use log collection
     - **awslogs-group**: `/ecs/astok-api-gateway`
     - **awslogs-region**: `ap-southeast-1`
     - **awslogs-stream-prefix**: `ecs`
4. Click **Create**

### 9.2 Task Definition cho Order Service

1. **Create new task definition**
2. **Task definition configuration**:
   - **Task definition family**: `astok-order-service`
   - **Launch type**: AWS Fargate
   - **CPU**: 0.25 vCPU
   - **Memory**: 0.5 GB
   - **Task execution role**: `ecsTaskExecutionRole`
3. **Container - 1**:
   - **Name**: `order-service`
   - **Image URI**: `<account-id>.dkr.ecr.ap-southeast-1.amazonaws.com/astok-order-service:latest`
   - **Port mappings**: Container port `5001`, Protocol `TCP`
   - **Environment variables**:
     | Key | Value |
     |-----|-------|
     | GRPC_PORT | 5001 |
     | DB_HOST | astok-orderdb.xxxx.ap-southeast-1.rds.amazonaws.com |
     | DB_PORT | 5432 |
     | DB_USER | postgres |
     | DB_PASSWORD | YourSecurePassword123! |
     | DB_NAME | orderdb |
     | DB_SSL_MODE | require |
     | KAFKA_BROKERS | disabled |
   - **HealthCheck**:
     - Command: `CMD-SHELL, nc -z localhost 5001 || exit 1`
     - Interval: 30
     - Timeout: 5
     - Start period: 60
     - Retries: 3
   - **Logging**:
     - **awslogs-group**: `/ecs/astok-order-service`
     - **awslogs-region**: `ap-southeast-1`
     - **awslogs-stream-prefix**: `ecs`
4. Click **Create**

---

## 10. ECS Services

### 10.1 Service cho Order Service (Tạo trước)

> ⚠️ **Tạo Order Service TRƯỚC** để Service Discovery hoạt động khi API Gateway start.

1. **ECS Console** → **Clusters** → `astok-cluster`
2. Tab **Services** → **Create**
3. **Environment**:
   - **Compute options**: Launch type
   - **Launch type**: FARGATE
4. **Deployment configuration**:
   - **Application type**: Service
   - **Family**: `astok-order-service`
   - **Revision**: LATEST
   - **Service name**: `astok-order-service`
   - **Desired tasks**: 1
5. **Networking**:
   - **VPC**: Chọn VPC
   - **Subnets**: Chọn **Private subnets** (cả 2)
   - **Security group**: Use existing → `astok-order-service-sg`
   - **Public IP**: ❌ Turned off
6. **Service discovery** (expand):
   - ✅ **Use service discovery**
   - **Namespace**: `astok.local`
   - **Service**: `order-service`
7. Click **Create**

### 10.2 Service cho API Gateway

1. Tab **Services** → **Create**
2. **Environment**:
   - **Launch type**: FARGATE
3. **Deployment configuration**:
   - **Family**: `astok-api-gateway`
   - **Service name**: `astok-api-gateway`
   - **Desired tasks**: 1
4. **Networking**:
   - **VPC**: Chọn VPC
   - **Subnets**: Chọn **Private subnets**
   - **Security group**: `astok-api-gateway-sg`
   - **Public IP**: ❌ Turned off
5. **Load balancing** (expand):
   - **Load balancer type**: Application Load Balancer
   - **Container**: `api-gateway 3000:3000`
   - ✅ **Use an existing load balancer**
   - **Load balancer**: `astok-alb`
   - ✅ **Use an existing target group**
   - **Target group**: `astok-api-gateway-tg`
   - **Health check grace period**: 120 seconds
6. Click **Create**

---

## 11. Kiểm Tra và Test

### 11.1 Kiểm Tra Services

1. **ECS Console** → **Clusters** → `astok-cluster` → **Services**
2. Đợi cả 2 services có **Running tasks** = 1

### 11.2 Kiểm Tra Target Group Health

1. **EC2 Console** → **Target Groups** → `astok-api-gateway-tg`
2. Tab **Targets** → Kiểm tra status **healthy**

> ⏳ Có thể mất 2-5 phút để targets healthy.

### 11.3 Test API

```bash
# Health check
curl http://<ALB-DNS>/api/health

# Get order
curl http://<ALB-DNS>/api/orders/1

# Create order
curl -X POST http://<ALB-DNS>/api/orders/create \
  -H "Content-Type: application/json" \
  -d '{"userId": 1, "totalAmount": 100.50, "products": []}'
```

### 11.4 Kiểm Tra Logs

1. **CloudWatch Console**: https://console.aws.amazon.com/cloudwatch/
2. **Log groups** → `/ecs/astok-api-gateway` hoặc `/ecs/astok-order-service`
3. Click vào log stream mới nhất để xem logs

---

## 📊 Tóm Tắt Resources

| Resource         | Name                           | Mục đích                |
| ---------------- | ------------------------------ | ----------------------- |
| IAM User         | github-astro                   | CI/CD deployment        |
| ECR              | astok-api, astok-order-service | Docker images           |
| VPC              | astok-vpc                      | Network isolation       |
| Subnets          | 2 public, 2 private            | Network separation      |
| Security Groups  | 5 groups                       | Network security        |
| VPC Endpoints    | ECR, Logs, S3                  | Private connectivity    |
| RDS              | astok-orderdb                  | PostgreSQL database     |
| ECS Cluster      | astok-cluster                  | Container orchestration |
| Task Definitions | 2 definitions                  | Container configs       |
| ECS Services     | 2 services                     | Running containers      |
| ALB              | astok-alb                      | Load balancing          |
| Target Group     | astok-api-gateway-tg           | Health checks           |
| Cloud Map        | astok.local                    | Service discovery       |

---

## 🔧 Troubleshooting

### Target Group Unhealthy

1. Kiểm tra Security Groups:

   - ALB SG → API Gateway SG (port 3000)
   - API Gateway SG → Order Service SG (port 5001)

2. Kiểm tra VPC Endpoints:

   - ECR API, ECR DKR, CloudWatch Logs phải có Security Group cho phép HTTPS từ VPC

3. Kiểm tra ECS Task logs trong CloudWatch

### Order Service Connection Refused

1. Kiểm tra Service Discovery:

   - Cloud Map → astok.local → order-service
   - Phải có registered instance

2. Kiểm tra Order Service running:
   - ECS → Services → astok-order-service → Tasks

### Database Connection Failed

1. Kiểm tra RDS Security Group:

   - Cho phép port 5432 từ 10.0.0.0/16

2. Kiểm tra environment variables trong Task Definition

---

## 💰 Chi Phí Ước Tính (ap-southeast-1)

| Service       | Specification               | Monthly Cost (USD) |
| ------------- | --------------------------- | ------------------ |
| ECS Fargate   | 2 tasks x 0.25 vCPU, 0.5 GB | ~$15               |
| ALB           | 1 ALB                       | ~$20               |
| RDS           | db.t3.micro, 20GB           | ~$15               |
| VPC Endpoints | 3 interface endpoints       | ~$22               |
| Data Transfer | ~10 GB/month                | ~$1                |
| CloudWatch    | Logs                        | ~$2                |
| **Total**     |                             | **~$75/month**     |

> 💡 Để tiết kiệm trong development:
>
> - Dừng RDS khi không dùng
> - Scale ECS services xuống 0
> - Xóa VPC Endpoints và dùng NAT Gateway theo giờ

---

## 🔐 GitHub Secrets Cần Thêm

Trong repository GitHub, thêm các secrets sau:

| Secret Name           | Value               |
| --------------------- | ------------------- |
| AWS_ACCESS_KEY_ID     | IAM User access key |
| AWS_SECRET_ACCESS_KEY | IAM User secret key |
| AWS_ACCOUNT_ID        | 976709231597        |
| DB_HOST               | RDS endpoint        |
| DB_USER               | postgres            |
| DB_PASSWORD           | Database password   |
| DB_NAME               | orderdb             |

---

## ✅ Checklist Hoàn Thành

- [ ] IAM User created with policy
- [ ] ECR repositories created (3)
- [ ] VPC created with 4 subnets
- [ ] VPC Endpoints created (4)
- [ ] Security Groups created (5)
- [ ] RDS PostgreSQL created
- [ ] ECS Cluster created
- [ ] ALB and Target Group created
- [ ] Service Discovery namespace and service created
- [ ] Task Definitions created (2)
- [ ] ECS Services created (2)
- [ ] Docker images pushed to ECR
- [ ] Database migrations run
- [ ] API tested successfully
- [ ] GitHub Secrets configured

---

**Happy Deploying! 🚀**
