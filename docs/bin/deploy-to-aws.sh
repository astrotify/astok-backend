#!/bin/bash
set -euo pipefail

# ============================================================================
# Script tổng hợp: Deploy API Gateway lên AWS từ đầu đến cuối
# ============================================================================
# Script này sẽ hướng dẫn và tự động hóa quá trình deploy API Gateway lên AWS
# Từ setup AWS credentials đến khi service chạy thành công
# ============================================================================

REGION="ap-southeast-1"
CLUSTER_NAME="astok-cluster"
SERVICE_NAME="api-gateway-service"
TASK_DEFINITION_FAMILY="astok-api-gateway"
ECR_REPOSITORY="astok-api"
LOG_GROUP="/ecs/astok-api-gateway"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
print_step() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

# ============================================================================
# PHẦN 1: KIỂM TRA VÀ SETUP AWS CLI
# ============================================================================
# TẠI SAO CẦN:
# - AWS CLI là công cụ command-line để tương tác với AWS services
# - Cần để chạy các lệnh tạo resources (VPC, ECS, ALB, etc.)
# - Credentials cần thiết để authenticate với AWS API
# - Kiểm tra trước để đảm bảo môi trường đã sẵn sàng
# ============================================================================

print_step "PHẦN 1: Kiểm tra và Setup AWS CLI"
print_info "Mục đích: Đảm bảo AWS CLI đã được cài đặt và credentials đã được cấu hình"
print_info "Tại sao cần: Tất cả các bước sau đều cần AWS CLI để tạo resources"

# Kiểm tra AWS CLI
if ! command -v aws &> /dev/null; then
    print_error "AWS CLI chưa được cài đặt"
    echo "Cài đặt AWS CLI:"
    echo "  macOS: brew install awscli"
    echo "  Linux: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    exit 1
fi

print_success "AWS CLI đã được cài đặt: $(aws --version)"

# Kiểm tra AWS credentials
if ! aws sts get-caller-identity &> /dev/null; then
    print_error "AWS credentials chưa được cấu hình"
    echo ""
    echo "Chạy lệnh sau để cấu hình:"
    echo "  aws configure"
    echo ""
    echo "Nhập:"
    echo "  - AWS Access Key ID"
    echo "  - AWS Secret Access Key"
    echo "  - Default region: $REGION"
    echo "  - Default output format: json"
    exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
print_success "AWS credentials đã được cấu hình"
print_info "Account ID: $ACCOUNT_ID"
print_info "Region: $REGION"

# ============================================================================
# PHẦN 2: TẠO IAM USER CHO GITHUB ACTIONS
# ============================================================================
# TẠI SAO CẦN:
# - GitHub Actions cần credentials để:
#   + Push Docker images lên ECR
#   + Deploy services lên ECS (DescribeTaskDefinition, RegisterTaskDefinition, UpdateService)
#   + Xem logs trên CloudWatch
#   + Run migration tasks
# - Không nên dùng root account credentials (bảo mật)
# - IAM User với least privilege an toàn hơn
# - Access keys từ user này sẽ được lưu trong GitHub Secrets
# ============================================================================

print_step "PHẦN 2: Tạo IAM User cho GitHub Actions"
print_info "Mục đích: Tạo user riêng với quyền push images và deploy services"
print_info "Tại sao cần: GitHub Actions workflow cần credentials để:"
print_info "  - Push Docker images lên ECR"
print_info "  - Deploy services lên ECS"
print_info "  - Xem logs và run migration tasks"
print_info "Bảo mật: User chỉ có quyền ECR + ECS + CloudWatch Logs"

IAM_USER_NAME="github-actions-astok"

# Kiểm tra user đã tồn tại chưa
if aws iam get-user --user-name "$IAM_USER_NAME" &> /dev/null; then
    print_warning "IAM User '$IAM_USER_NAME' đã tồn tại"
    read -p "Bạn có muốn tạo access key mới không? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_info "Tạo access key mới..."
        NEW_KEY=$(aws iam create-access-key --user-name "$IAM_USER_NAME" --output json)
        ACCESS_KEY_ID=$(echo "$NEW_KEY" | jq -r '.AccessKey.AccessKeyId')
        SECRET_ACCESS_KEY=$(echo "$NEW_KEY" | jq -r '.AccessKey.SecretAccessKey')
        print_success "Access Key đã được tạo"
        echo ""
        echo "Lưu lại các giá trị sau để thêm vào GitHub Secrets:"
        echo "  AWS_ACCESS_KEY_ID: $ACCESS_KEY_ID"
        echo "  AWS_SECRET_ACCESS_KEY: $SECRET_ACCESS_KEY"
        echo ""
    fi
else
    print_info "Tạo IAM User mới: $IAM_USER_NAME"
    aws iam create-user --user-name "$IAM_USER_NAME" > /dev/null
    
    # Tạo policy cho ECR + ECS Deploy
    POLICY_DOC=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ECRPermissions",
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:PutImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ECSPermissions",
      "Effect": "Allow",
      "Action": [
        "ecs:DescribeServices",
        "ecs:DescribeTaskDefinition",
        "ecs:DescribeTasks",
        "ecs:ListTasks",
        "ecs:RegisterTaskDefinition",
        "ecs:UpdateService",
        "ecs:RunTask"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CloudWatchLogsPermissions",
      "Effect": "Allow",
      "Action": [
        "logs:GetLogEvents",
        "logs:FilterLogEvents",
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams"
      ],
      "Resource": "*"
    },
    {
      "Sid": "IAMPassRole",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::*:role/ecsTaskExecutionRole"
    }
  ]
}
EOF
)
    
    # Tạo policy
    aws iam create-policy \
        --policy-name GitHubActionsECSDeployPolicy \
        --policy-document "$POLICY_DOC" \
        --description "Policy for GitHub Actions to build, push to ECR, and deploy to ECS" \
        2>/dev/null || print_warning "Policy có thể đã tồn tại"
    
    POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/GitHubActionsECSDeployPolicy"
    aws iam attach-user-policy \
        --user-name "$IAM_USER_NAME" \
        --policy-arn "$POLICY_ARN"
    
    # Tạo access key
    NEW_KEY=$(aws iam create-access-key --user-name "$IAM_USER_NAME" --output json)
    ACCESS_KEY_ID=$(echo "$NEW_KEY" | jq -r '.AccessKey.AccessKeyId')
    SECRET_ACCESS_KEY=$(echo "$NEW_KEY" | jq -r '.AccessKey.SecretAccessKey')
    
    print_success "IAM User và Access Key đã được tạo"
    echo ""
    echo "⚠️  QUAN TRỌNG: Lưu lại các giá trị sau để thêm vào GitHub Secrets:"
    echo ""
    echo "  Repository → Settings → Secrets and variables → Actions"
    echo ""
    echo "  Secret 1:"
    echo "    Name: AWS_ACCESS_KEY_ID"
    echo "    Value: $ACCESS_KEY_ID"
    echo ""
    echo "  Secret 2:"
    echo "    Name: AWS_SECRET_ACCESS_KEY"
    echo "    Value: $SECRET_ACCESS_KEY"
    echo ""
    read -p "Nhấn Enter sau khi đã lưu secrets vào GitHub..."
fi

# ============================================================================
# PHẦN 3: TẠO ECR REPOSITORY
# ============================================================================
# TẠI SAO CẦN:
# - ECR (Elastic Container Registry) là nơi lưu trữ Docker images
# - GitHub Actions sẽ build và push images lên đây
# - ECS sẽ pull images từ đây để chạy containers
# - Image scanning tự động để phát hiện vulnerabilities
# ============================================================================

print_step "PHẦN 3: Tạo ECR Repository"
print_info "Mục đích: Tạo repository để lưu trữ Docker images"
print_info "Tại sao cần: ECS cần pull images từ ECR để chạy containers"
print_info "Workflow: GitHub Actions → Build Image → Push to ECR → ECS Pull → Run"

if aws ecr describe-repositories --repository-names "$ECR_REPOSITORY" --region "$REGION" &> /dev/null; then
    print_warning "ECR Repository '$ECR_REPOSITORY' đã tồn tại"
else
    print_info "Tạo ECR Repository: $ECR_REPOSITORY"
    aws ecr create-repository \
        --repository-name "$ECR_REPOSITORY" \
        --region "$REGION" \
        --image-scanning-configuration scanOnPush=true \
        --image-tag-mutability MUTABLE > /dev/null
    print_success "ECR Repository đã được tạo"
fi

ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPOSITORY}"
print_info "ECR URI: $ECR_URI"

# ============================================================================
# PHẦN 4: TẠO VPC VÀ NETWORKING
# ============================================================================
# TẠI SAO CẦN:
# - VPC (Virtual Private Cloud) tạo mạng riêng ảo để cô lập resources
# - Public Subnets: Cho ALB, NAT Gateway (cần internet access)
# - Private Subnets: Cho ECS tasks, RDS (không cần internet trực tiếp, bảo mật hơn)
# - Internet Gateway: Cho phép public subnets kết nối internet
# - Route Tables: Định tuyến traffic giữa các subnets
# - Multi-AZ: High availability, nếu 1 AZ down, service vẫn chạy ở AZ khác
# ============================================================================

print_step "PHẦN 4: Tạo VPC và Networking"
print_info "Mục đích: Tạo mạng riêng ảo để cô lập và bảo mật resources"
print_info "Tại sao cần:"
print_info "  - Security: Cô lập mạng, kiểm soát traffic"
print_info "  - Compliance: Đáp ứng yêu cầu bảo mật"
print_info "  - Flexibility: Tự do cấu hình network"
print_info "Cấu trúc:"
print_info "  - Public Subnets: ALB, NAT Gateway (cần internet)"
print_info "  - Private Subnets: ECS tasks, RDS (không cần internet trực tiếp)"

# Kiểm tra VPC đã tồn tại chưa
EXISTING_VPC=$(aws ec2 describe-vpcs \
    --filters "Name=cidr-block,Values=10.0.0.0/16" "Name=state,Values=available" \
    --query 'Vpcs[0].VpcId' \
    --output text \
    --region "$REGION" 2>/dev/null || echo "None")

if [ "$EXISTING_VPC" != "None" ] && [ -n "$EXISTING_VPC" ]; then
    print_warning "VPC với CIDR 10.0.0.0/16 đã tồn tại: $EXISTING_VPC"
    read -p "Bạn có muốn sử dụng VPC này không? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        VPC_ID="$EXISTING_VPC"
        print_info "Sử dụng VPC hiện có: $VPC_ID"
    else
        print_info "Vui lòng tạo VPC mới qua AWS Console hoặc CLI"
        exit 1
    fi
else
    print_info "Tạo VPC mới..."
    VPC_ID=$(aws ec2 create-vpc \
        --cidr-block 10.0.0.0/16 \
        --region "$REGION" \
        --query 'Vpc.VpcId' \
        --output text)
    
    # Enable DNS
    aws ec2 modify-vpc-attribute \
        --vpc-id "$VPC_ID" \
        --enable-dns-support \
        --region "$REGION"
    
    aws ec2 modify-vpc-attribute \
        --vpc-id "$VPC_ID" \
        --enable-dns-hostnames \
        --region "$REGION"
    
    print_success "VPC đã được tạo: $VPC_ID"
fi

# Tạo Internet Gateway
IGW_ID=$(aws ec2 describe-internet-gateways \
    --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
    --query 'InternetGateways[0].InternetGatewayId' \
    --output text \
    --region "$REGION" 2>/dev/null || echo "None")

if [ "$IGW_ID" == "None" ] || [ -z "$IGW_ID" ]; then
    print_info "Tạo Internet Gateway..."
    IGW_ID=$(aws ec2 create-internet-gateway \
        --region "$REGION" \
        --query 'InternetGateway.InternetGatewayId' \
        --output text)
    
    aws ec2 attach-internet-gateway \
        --internet-gateway-id "$IGW_ID" \
        --vpc-id "$VPC_ID" \
        --region "$REGION"
    
    print_success "Internet Gateway đã được tạo: $IGW_ID"
fi

# Tạo Subnets
print_info "Tạo Subnets..."

# Lấy availability zones
AZ1=$(aws ec2 describe-availability-zones --region "$REGION" --query 'AvailabilityZones[0].ZoneName' --output text)
AZ2=$(aws ec2 describe-availability-zones --region "$REGION" --query 'AvailabilityZones[1].ZoneName' --output text)

# Public Subnet 1
PUBLIC_SUBNET_1=$(aws ec2 create-subnet \
    --vpc-id "$VPC_ID" \
    --cidr-block 10.0.1.0/24 \
    --availability-zone "$AZ1" \
    --region "$REGION" \
    --query 'Subnet.SubnetId' \
    --output text 2>/dev/null || \
    aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidr-block,Values=10.0.1.0/24" \
        --query 'Subnets[0].SubnetId' \
        --output text \
        --region "$REGION")

# Public Subnet 2
PUBLIC_SUBNET_2=$(aws ec2 create-subnet \
    --vpc-id "$VPC_ID" \
    --cidr-block 10.0.2.0/24 \
    --availability-zone "$AZ2" \
    --region "$REGION" \
    --query 'Subnet.SubnetId' \
    --output text 2>/dev/null || \
    aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidr-block,Values=10.0.2.0/24" \
        --query 'Subnets[0].SubnetId' \
        --output text \
        --region "$REGION")

# Private Subnet 1
PRIVATE_SUBNET_1=$(aws ec2 create-subnet \
    --vpc-id "$VPC_ID" \
    --cidr-block 10.0.3.0/24 \
    --availability-zone "$AZ1" \
    --region "$REGION" \
    --query 'Subnet.SubnetId' \
    --output text 2>/dev/null || \
    aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidr-block,Values=10.0.3.0/24" \
        --query 'Subnets[0].SubnetId' \
        --output text \
        --region "$REGION")

# Private Subnet 2
PRIVATE_SUBNET_2=$(aws ec2 create-subnet \
    --vpc-id "$VPC_ID" \
    --cidr-block 10.0.4.0/24 \
    --availability-zone "$AZ2" \
    --region "$REGION" \
    --query 'Subnet.SubnetId' \
    --output text 2>/dev/null || \
    aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=cidr-block,Values=10.0.4.0/24" \
        --query 'Subnets[0].SubnetId' \
        --output text \
        --region "$REGION")

print_success "Subnets đã được tạo"
print_info "Public Subnets: $PUBLIC_SUBNET_1, $PUBLIC_SUBNET_2"
print_info "Private Subnets: $PRIVATE_SUBNET_1, $PRIVATE_SUBNET_2"

# Tạo Route Table cho Public Subnets
PUBLIC_RT_ID=$(aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=association.subnet-id,Values=$PUBLIC_SUBNET_1" \
    --query 'RouteTables[0].RouteTableId' \
    --output text \
    --region "$REGION" 2>/dev/null || \
    aws ec2 create-route-table \
        --vpc-id "$VPC_ID" \
        --region "$REGION" \
        --query 'RouteTable.RouteTableId' \
        --output text)

# Thêm route đến Internet Gateway
aws ec2 create-route \
    --route-table-id "$PUBLIC_RT_ID" \
    --destination-cidr-block 0.0.0.0/0 \
    --gateway-id "$IGW_ID" \
    --region "$REGION" 2>/dev/null || true

# Associate public subnets với route table
aws ec2 associate-route-table \
    --subnet-id "$PUBLIC_SUBNET_1" \
    --route-table-id "$PUBLIC_RT_ID" \
    --region "$REGION" 2>/dev/null || true

aws ec2 associate-route-table \
    --subnet-id "$PUBLIC_SUBNET_2" \
    --route-table-id "$PUBLIC_RT_ID" \
    --region "$REGION" 2>/dev/null || true

# Đảm bảo route table có route đến Internet Gateway
EXISTING_IGW_ROUTE=$(aws ec2 describe-route-tables \
    --route-table-ids "$PUBLIC_RT_ID" \
    --region "$REGION" \
    --query "RouteTables[0].Routes[?GatewayId=='$IGW_ID' && DestinationCidrBlock=='0.0.0.0/0']" \
    --output json)

if [ "$(echo "$EXISTING_IGW_ROUTE" | jq 'length')" -eq 0 ]; then
    print_info "Thêm route đến Internet Gateway..."
    aws ec2 create-route \
        --route-table-id "$PUBLIC_RT_ID" \
        --destination-cidr-block 0.0.0.0/0 \
        --gateway-id "$IGW_ID" \
        --region "$REGION" 2>/dev/null || true
    print_success "Route đến Internet Gateway đã được thêm"
fi

# Đảm bảo main route table cũng có route đến IGW (cho ALB)
MAIN_RT_ID=$(aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=association.main,Values=true" \
    --query 'RouteTables[0].RouteTableId' \
    --output text \
    --region "$REGION")

if [ -n "$MAIN_RT_ID" ] && [ "$MAIN_RT_ID" != "None" ]; then
    MAIN_IGW_ROUTE=$(aws ec2 describe-route-tables \
        --route-table-ids "$MAIN_RT_ID" \
        --region "$REGION" \
        --query "RouteTables[0].Routes[?GatewayId=='$IGW_ID' && DestinationCidrBlock=='0.0.0.0/0']" \
        --output json)
    
    if [ "$(echo "$MAIN_IGW_ROUTE" | jq 'length')" -eq 0 ]; then
        print_info "Thêm route đến Internet Gateway cho main route table..."
        aws ec2 create-route \
            --route-table-id "$MAIN_RT_ID" \
            --destination-cidr-block 0.0.0.0/0 \
            --gateway-id "$IGW_ID" \
            --region "$REGION" 2>/dev/null || true
        print_success "Route đến Internet Gateway cho main route table đã được thêm"
    fi
fi

# ============================================================================
# PHẦN 5: TẠO SECURITY GROUPS
# ============================================================================
# TẠI SAO CẦN:
# - Security Groups là firewall rules cho AWS resources
# - Chỉ cho phép traffic cần thiết (least privilege)
# - ALB SG: Cho phép HTTP/HTTPS từ internet (port 80, 443)
# - API Gateway SG: Chỉ cho phép port 3000 từ ALB (không cho phép từ internet)
# - Defense in Depth: Nhiều lớp bảo mật
# ============================================================================

print_step "PHẦN 5: Tạo Security Groups"
print_info "Mục đích: Tạo firewall rules để kiểm soát traffic"
print_info "Tại sao cần:"
print_info "  - Security: Chỉ cho phép traffic cần thiết"
print_info "  - Least Privilege: Mỗi resource chỉ có quyền tối thiểu"
print_info "  - Network Segmentation: Tách biệt các components"
print_info "Rules:"
print_info "  - ALB: Cho phép HTTP/HTTPS từ internet (0.0.0.0/0)"
print_info "  - API Gateway: Chỉ cho phép port 3000 từ ALB"

# ALB Security Group
ALB_SG_ID=$(aws ec2 create-security-group \
    --group-name astok-alb-sg \
    --description "Security group for ALB" \
    --vpc-id "$VPC_ID" \
    --region "$REGION" \
    --query 'GroupId' \
    --output text 2>/dev/null || \
    aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=astok-alb-sg" "Name=vpc-id,Values=$VPC_ID" \
        --query 'SecurityGroups[0].GroupId' \
        --output text \
        --region "$REGION")

# Cho phép HTTP và HTTPS
aws ec2 authorize-security-group-ingress \
    --group-id "$ALB_SG_ID" \
    --protocol tcp \
    --port 80 \
    --cidr 0.0.0.0/0 \
    --region "$REGION" 2>/dev/null || true

aws ec2 authorize-security-group-ingress \
    --group-id "$ALB_SG_ID" \
    --protocol tcp \
    --port 443 \
    --cidr 0.0.0.0/0 \
    --region "$REGION" 2>/dev/null || true

# API Gateway Security Group
API_SG_ID=$(aws ec2 create-security-group \
    --group-name astok-api-gateway-sg \
    --description "Security group for API Gateway" \
    --vpc-id "$VPC_ID" \
    --region "$REGION" \
    --query 'GroupId' \
    --output text 2>/dev/null || \
    aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=astok-api-gateway-sg" "Name=vpc-id,Values=$VPC_ID" \
        --query 'SecurityGroups[0].GroupId' \
        --output text \
        --region "$REGION")

# Cho phép port 3000 từ ALB
aws ec2 authorize-security-group-ingress \
    --group-id "$API_SG_ID" \
    --protocol tcp \
    --port 3000 \
    --source-group "$ALB_SG_ID" \
    --region "$REGION" 2>/dev/null || true

# Cho phép outbound HTTPS (cho ECR, CloudWatch)
aws ec2 authorize-security-group-egress \
    --group-id "$API_SG_ID" \
    --ip-permissions IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}] \
    --region "$REGION" 2>/dev/null || true

print_success "Security Groups đã được tạo"
print_info "ALB SG: $ALB_SG_ID"
print_info "API Gateway SG: $API_SG_ID"

# ============================================================================
# PHẦN 6: TẠO VPC ENDPOINTS (CHO ECR VÀ CLOUDWATCH)
# ============================================================================
# TẠI SAO CẦN:
# - ECS tasks ở private subnet không có internet access
# - Cần kết nối đến ECR để pull images
# - Cần kết nối đến CloudWatch Logs để gửi logs
# - VPC Endpoints cho phép kết nối private đến AWS services
# - Không cần NAT Gateway (tiết kiệm ~$32/tháng)
# - Bảo mật hơn (traffic không đi qua internet)
# - Performance tốt hơn (kết nối nội bộ AWS)
# ============================================================================

print_step "PHẦN 6: Tạo VPC Endpoints cho ECR và CloudWatch"
print_info "Mục đích: Cho phép ECS tasks kết nối đến AWS services mà không cần internet"
print_info "Tại sao cần:"
print_info "  - Tasks ở private subnet không có public IP"
print_info "  - Cần pull images từ ECR"
print_info "  - Cần gửi logs lên CloudWatch"
print_info "Lợi ích:"
print_info "  - Security: Traffic không đi qua internet"
print_info "  - Cost: Không cần NAT Gateway (~$32/tháng)"
print_info "  - Performance: Kết nối nội bộ AWS nhanh hơn"

# Security Group cho VPC Endpoints
ENDPOINT_SG_ID=$(aws ec2 create-security-group \
    --group-name ecr-endpoint-sg \
    --description "Security group for VPC Endpoints" \
    --vpc-id "$VPC_ID" \
    --region "$REGION" \
    --query 'GroupId' \
    --output text 2>/dev/null || \
    aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=ecr-endpoint-sg" "Name=vpc-id,Values=$VPC_ID" \
        --query 'SecurityGroups[0].GroupId' \
        --output text \
        --region "$REGION")

# Cho phép HTTPS từ VPC
aws ec2 authorize-security-group-ingress \
    --group-id "$ENDPOINT_SG_ID" \
    --protocol tcp \
    --port 443 \
    --cidr 10.0.0.0/16 \
    --region "$REGION" 2>/dev/null || true

# ECR API Endpoint
print_info "Tạo VPC Endpoint cho ECR API..."
aws ec2 create-vpc-endpoint \
    --vpc-id "$VPC_ID" \
    --vpc-endpoint-type Interface \
    --service-name com.amazonaws.${REGION}.ecr.api \
    --subnet-ids "$PRIVATE_SUBNET_1" "$PRIVATE_SUBNET_2" \
    --security-group-ids "$ENDPOINT_SG_ID" \
    --private-dns-enabled \
    --region "$REGION" 2>/dev/null && print_success "ECR API Endpoint created" || print_warning "ECR API Endpoint may already exist"

# ECR DKR Endpoint
print_info "Tạo VPC Endpoint cho ECR DKR..."
aws ec2 create-vpc-endpoint \
    --vpc-id "$VPC_ID" \
    --vpc-endpoint-type Interface \
    --service-name com.amazonaws.${REGION}.ecr.dkr \
    --subnet-ids "$PRIVATE_SUBNET_1" "$PRIVATE_SUBNET_2" \
    --security-group-ids "$ENDPOINT_SG_ID" \
    --private-dns-enabled \
    --region "$REGION" 2>/dev/null && print_success "ECR DKR Endpoint created" || print_warning "ECR DKR Endpoint may already exist"

# CloudWatch Logs Endpoint
print_info "Tạo VPC Endpoint cho CloudWatch Logs..."
aws ec2 create-vpc-endpoint \
    --vpc-id "$VPC_ID" \
    --vpc-endpoint-type Interface \
    --service-name com.amazonaws.${REGION}.logs \
    --subnet-ids "$PRIVATE_SUBNET_1" "$PRIVATE_SUBNET_2" \
    --security-group-ids "$ENDPOINT_SG_ID" \
    --private-dns-enabled \
    --region "$REGION" 2>/dev/null && print_success "CloudWatch Logs Endpoint created" || print_warning "CloudWatch Logs Endpoint may already exist"

# S3 Gateway Endpoint (miễn phí)
print_info "Tạo VPC Endpoint cho S3 (Gateway)..."
RT_IDS=$(aws ec2 describe-route-tables \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'RouteTables[*].RouteTableId' \
    --output text \
    --region "$REGION")

for RT_ID in $RT_IDS; do
    aws ec2 create-vpc-endpoint \
        --vpc-id "$VPC_ID" \
        --vpc-endpoint-type Gateway \
        --service-name com.amazonaws.${REGION}.s3 \
        --route-table-ids "$RT_ID" \
        --region "$REGION" 2>/dev/null || true
done

print_info "Đợi 60 giây để VPC Endpoints sẵn sàng..."
sleep 60

# ============================================================================
# PHẦN 7: TẠO ECS CLUSTER
# ============================================================================
# TẠI SAO CẦN:
# - ECS Cluster là container orchestration platform
# - Quản lý và chạy Docker containers
# - Fargate: Không cần quản lý EC2 instances (serverless)
# - Auto scaling: Tự động scale dựa trên demand
# - Health checks: Tự động restart failed containers
# - Integration: Tích hợp với ALB, CloudWatch, IAM
# ============================================================================

print_step "PHẦN 7: Tạo ECS Cluster"
print_info "Mục đích: Tạo cluster để chạy và quản lý containers"
print_info "Tại sao dùng ECS Fargate:"
print_info "  - No Server Management: Không cần quản lý EC2"
print_info "  - Auto Scaling: Tự động scale"
print_info "  - Cost Effective: Chỉ trả tiền cho resources dùng"
print_info "  - Integration: Tích hợp tốt với ALB, CloudWatch"

if aws ecs describe-clusters --clusters "$CLUSTER_NAME" --region "$REGION" --query 'clusters[0].status' --output text 2>/dev/null | grep -q "ACTIVE"; then
    print_warning "ECS Cluster '$CLUSTER_NAME' đã tồn tại"
else
    print_info "Tạo ECS Cluster: $CLUSTER_NAME"
    aws ecs create-cluster \
        --cluster-name "$CLUSTER_NAME" \
        --capacity-providers FARGATE FARGATE_SPOT \
        --default-capacity-provider-strategy capacityProvider=FARGATE,weight=1 \
        --region "$REGION" > /dev/null
    print_success "ECS Cluster đã được tạo"
fi

# ============================================================================
# PHẦN 8: TẠO CLOUDWATCH LOG GROUP
# ============================================================================
# TẠI SAO CẦN:
# - CloudWatch Logs lưu trữ logs từ applications
# - Centralized logging: Tất cả logs ở một nơi
# - Debugging: Dễ debug khi có lỗi
# - Monitoring: Có thể tạo alarms dựa trên logs
# - Retention: Tự động xóa logs sau một thời gian (tiết kiệm)
# ============================================================================

print_step "PHẦN 8: Tạo CloudWatch Log Group"
print_info "Mục đích: Tạo log group để lưu trữ logs từ API Gateway"
print_info "Tại sao cần:"
print_info "  - Centralized Logging: Tất cả logs ở một nơi"
print_info "  - Debugging: Dễ debug khi có lỗi"
print_info "  - Monitoring: Có thể tạo alarms"
print_info "  - Retention: Tự động xóa logs cũ"

if aws logs describe-log-groups \
    --log-group-name-prefix "$LOG_GROUP" \
    --region "$REGION" \
    --query "logGroups[?logGroupName=='$LOG_GROUP'].logGroupName" \
    --output text 2>/dev/null | grep -q "$LOG_GROUP"; then
    print_warning "Log Group '$LOG_GROUP' đã tồn tại"
else
    print_info "Tạo Log Group: $LOG_GROUP"
    aws logs create-log-group \
        --log-group-name "$LOG_GROUP" \
        --region "$REGION" > /dev/null
    print_success "Log Group đã được tạo"
fi

# ============================================================================
# PHẦN 9: TẠO IAM ROLE CHO ECS TASKS
# ============================================================================
# TẠI SAO CẦN:
# - ECS tasks cần permissions để:
#   - Pull images từ ECR
#   - Gửi logs lên CloudWatch Logs
#   - Truy cập Secrets Manager (nếu dùng)
# - IAM Role gắn vào tasks, không phải hardcode credentials
# - Least privilege: Chỉ có quyền cần thiết
# - Security: Không lưu credentials trong code
# ============================================================================

print_step "PHẦN 9: Tạo IAM Role cho ECS Tasks"
print_info "Mục đích: Tạo role với permissions để tasks có thể hoạt động"
print_info "Tại sao cần:"
print_info "  - Tasks cần pull images từ ECR"
print_info "  - Tasks cần gửi logs lên CloudWatch"
print_info "  - Security: Không hardcode credentials"
print_info "Permissions:"
print_info "  - ECR: Pull images"
print_info "  - CloudWatch Logs: Write logs"

ROLE_NAME="ecsTaskExecutionRole"

if aws iam get-role --role-name "$ROLE_NAME" &> /dev/null; then
    print_warning "IAM Role '$ROLE_NAME' đã tồn tại"
else
    print_info "Tạo IAM Role: $ROLE_NAME"
    
    # Trust policy
    TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ecs-tasks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
)
    
    aws iam create-role \
        --role-name "$ROLE_NAME" \
        --assume-role-policy-document "$TRUST_POLICY" > /dev/null
    
    # Attach policy
    aws iam attach-role-policy \
        --role-name "$ROLE_NAME" \
        --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
    
    print_success "IAM Role đã được tạo"
fi

EXECUTION_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
print_info "Execution Role ARN: $EXECUTION_ROLE_ARN"

# ============================================================================
# PHẦN 10: TẠO TASK DEFINITION
# ============================================================================
# TẠI SAO CẦN:
# - Task Definition là template định nghĩa container
# - Chứa: image, CPU, memory, environment variables, ports, health checks
# - Tái sử dụng: Có thể dùng cho nhiều tasks
# - Versioning: Mỗi lần update tạo version mới
# - Health checks: Tự động restart nếu container unhealthy
# ============================================================================

print_step "PHẦN 10: Tạo Task Definition"
print_info "Mục đích: Định nghĩa cấu hình container (image, CPU, memory, env vars)"
print_info "Tại sao cần:"
print_info "  - Template: Định nghĩa cách chạy container"
print_info "  - Reusability: Dùng cho nhiều tasks"
print_info "  - Versioning: Mỗi update tạo version mới"
print_info "  - Health Checks: Tự động restart nếu unhealthy"
print_info "Cấu hình:"
print_info "  - CPU: 256 (0.25 vCPU)"
print_info "  - Memory: 512 MB"
print_info "  - Port: 3000"
print_info "  - Health Check: curl /api/health (Alpine có curl, không có wget)"
print_info "  - Health Check Timeout: 10s (tăng từ 5s)"
print_info "  - Health Check Start Period: 90s (tăng từ 60s)"

TASK_DEF_FILE="/tmp/task-definition-${TASK_DEFINITION_FAMILY}.json"

cat > "$TASK_DEF_FILE" <<EOF
{
  "family": "${TASK_DEFINITION_FAMILY}",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "${EXECUTION_ROLE_ARN}",
  "containerDefinitions": [
    {
      "name": "api-gateway",
      "image": "${ECR_URI}:latest",
      "portMappings": [
        {
          "containerPort": 3000,
          "protocol": "tcp"
        }
      ],
      "environment": [
        {
          "name": "PORT",
          "value": "3000"
        },
        {
          "name": "ORDER_SERVICE_GRPC_HOST",
          "value": "order-service.astok.local"
        },
        {
          "name": "ORDER_SERVICE_GRPC_PORT",
          "value": "5001"
        },
        {
          "name": "CORS_ORIGIN",
          "value": "*"
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "${LOG_GROUP}",
          "awslogs-region": "${REGION}",
          "awslogs-stream-prefix": "ecs",
          "awslogs-create-group": "true"
        }
      },
      "healthCheck": {
        "command": [
          "CMD-SHELL",
          "curl -f -s http://localhost:3000/api/health > /dev/null || exit 1"
        ],
        "interval": 30,
        "timeout": 10,
        "retries": 3,
        "startPeriod": 90
      }
    }
  ]
}
EOF

print_info "Đăng ký Task Definition..."
aws ecs register-task-definition \
    --cli-input-json "file://$TASK_DEF_FILE" \
    --region "$REGION" > /dev/null

print_success "Task Definition đã được đăng ký"

# ============================================================================
# PHẦN 11: TẠO APPLICATION LOAD BALANCER
# ============================================================================
# TẠI SAO CẦN:
# - ALB phân phối traffic đến các ECS tasks
# - High Availability: Nếu 1 task fail, traffic route đến task khác
# - Load Distribution: Phân phối đều traffic
# - Health Checks: Tự động loại bỏ unhealthy tasks
# - SSL Termination: Xử lý HTTPS certificates (khi có)
# - Single Entry Point: Expose service ra internet
# ============================================================================

print_step "PHẦN 11: Tạo Application Load Balancer"
print_info "Mục đích: Tạo load balancer để phân phối traffic và expose service ra internet"
print_info "Tại sao cần:"
print_info "  - High Availability: Nếu 1 task fail, traffic route đến task khác"
print_info "  - Load Distribution: Phân phối đều traffic"
print_info "  - Health Checks: Tự động loại bỏ unhealthy tasks"
print_info "  - SSL Termination: Xử lý HTTPS (khi có certificate)"
print_info "  - Single Entry Point: Expose service ra internet"
print_info "Cấu hình:"
print_info "  - Type: Application Load Balancer (Layer 7)"
print_info "  - Scheme: internet-facing (accessible từ internet)"
print_info "  - Subnets: Public subnets (cần route đến Internet Gateway)"
print_info "  - Listeners: HTTP (80), HTTPS (443 khi có certificate)"
print_info "  - Health Check Path: /api/health"
print_info "  - Health Check Timeout: 10s"

# Kiểm tra ALB đã tồn tại chưa
ALB_ARN=$(aws elbv2 describe-load-balancers \
    --region "$REGION" \
    --query "LoadBalancers[?LoadBalancerName=='astok-alb'].LoadBalancerArn" \
    --output text 2>/dev/null || echo "None")

if [ "$ALB_ARN" != "None" ] && [ -n "$ALB_ARN" ]; then
    print_warning "ALB 'astok-alb' đã tồn tại"
else
    print_info "Tạo ALB..."
    ALB_ARN=$(aws elbv2 create-load-balancer \
        --name astok-alb \
        --subnets "$PUBLIC_SUBNET_1" "$PUBLIC_SUBNET_2" \
        --security-groups "$ALB_SG_ID" \
        --scheme internet-facing \
        --type application \
        --region "$REGION" \
        --query 'LoadBalancers[0].LoadBalancerArn' \
        --output text)
    
    print_info "Đợi ALB sẵn sàng..."
    aws elbv2 wait load-balancer-available \
        --load-balancer-arns "$ALB_ARN" \
        --region "$REGION"
    
    print_success "ALB đã được tạo"
fi

ALB_DNS=$(aws elbv2 describe-load-balancers \
    --load-balancer-arns "$ALB_ARN" \
    --region "$REGION" \
    --query 'LoadBalancers[0].DNSName' \
    --output text)

print_info "ALB DNS: $ALB_DNS"

# Tạo Target Group
TG_ARN=$(aws elbv2 describe-target-groups \
    --names astok-api-gateway-tg \
    --region "$REGION" \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text 2>/dev/null || echo "None")

if [ "$TG_ARN" == "None" ] || [ -z "$TG_ARN" ]; then
    print_info "Tạo Target Group..."
    TG_ARN=$(aws elbv2 create-target-group \
        --name astok-api-gateway-tg \
        --protocol HTTP \
        --port 3000 \
        --vpc-id "$VPC_ID" \
        --target-type ip \
        --health-check-path /api/health \
        --health-check-interval-seconds 30 \
        --health-check-timeout-seconds 10 \
        --healthy-threshold-count 2 \
        --unhealthy-threshold-count 3 \
        --region "$REGION" \
        --query 'TargetGroups[0].TargetGroupArn' \
        --output text)
    
    print_success "Target Group đã được tạo"
fi

# Tạo Listener
LISTENER_EXISTS=$(aws elbv2 describe-listeners \
    --load-balancer-arn "$ALB_ARN" \
    --region "$REGION" \
    --query 'Listeners[?Port==`80`].ListenerArn' \
    --output text 2>/dev/null || echo "None")

if [ "$LISTENER_EXISTS" == "None" ] || [ -z "$LISTENER_EXISTS" ]; then
    print_info "Tạo HTTP Listener..."
    aws elbv2 create-listener \
        --load-balancer-arn "$ALB_ARN" \
        --protocol HTTP \
        --port 80 \
        --default-actions Type=forward,TargetGroupArn="$TG_ARN" \
        --region "$REGION" > /dev/null
    
    print_success "Listener đã được tạo"
fi

# ============================================================================
# PHẦN 12: TẠO ECS SERVICE
# ============================================================================
# TẠI SAO CẦN:
# - ECS Service quản lý số lượng tasks (desired count)
# - Tự động restart nếu task fail
# - Rolling updates: Update không downtime
# - Integration với ALB: Tự động register tasks vào target group
# - Health checks: Monitor và restart unhealthy tasks
# - Auto scaling: Có thể tự động scale dựa trên metrics
# ============================================================================

print_step "PHẦN 12: Tạo ECS Service"
print_info "Mục đích: Tạo service để quản lý và chạy containers"
print_info "Tại sao cần:"
print_info "  - Task Management: Quản lý số lượng tasks"
print_info "  - Auto Restart: Tự động restart failed tasks"
print_info "  - Rolling Updates: Update không downtime"
print_info "  - ALB Integration: Tự động register vào target group"
print_info "  - Health Checks: Monitor và restart unhealthy tasks"
print_info "Cấu hình:"
print_info "  - Desired Count: 1 (có thể tăng sau)"
print_info "  - Launch Type: FARGATE"
print_info "  - Network: Private subnets, no public IP"
print_info "  - Load Balancer: ALB target group"

if aws ecs describe-services \
    --cluster "$CLUSTER_NAME" \
    --services "$SERVICE_NAME" \
    --region "$REGION" \
    --query 'services[0].status' \
    --output text 2>/dev/null | grep -q "ACTIVE"; then
    print_warning "ECS Service '$SERVICE_NAME' đã tồn tại"
    read -p "Bạn có muốn update service không? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_info "Updating service..."
        aws ecs update-service \
            --cluster "$CLUSTER_NAME" \
            --service "$SERVICE_NAME" \
            --task-definition "$TASK_DEFINITION_FAMILY" \
            --network-configuration "awsvpcConfiguration={subnets=[\"$PRIVATE_SUBNET_1\",\"$PRIVATE_SUBNET_2\"],securityGroups=[\"$API_SG_ID\"],assignPublicIp=DISABLED}" \
            --load-balancers "targetGroupArn=$TG_ARN,containerName=api-gateway,containerPort=3000" \
            --force-new-deployment \
            --region "$REGION" > /dev/null
        print_success "Service đã được update"
    fi
else
    print_info "Tạo ECS Service: $SERVICE_NAME"
    aws ecs create-service \
        --cluster "$CLUSTER_NAME" \
        --service-name "$SERVICE_NAME" \
        --task-definition "$TASK_DEFINITION_FAMILY" \
        --desired-count 1 \
        --launch-type FARGATE \
        --network-configuration "awsvpcConfiguration={subnets=[\"$PRIVATE_SUBNET_1\",\"$PRIVATE_SUBNET_2\"],securityGroups=[\"$API_SG_ID\"],assignPublicIp=DISABLED}" \
        --load-balancers "targetGroupArn=$TG_ARN,containerName=api-gateway,containerPort=3000" \
        --region "$REGION" > /dev/null
    
    print_success "ECS Service đã được tạo"
fi

# ============================================================================
# PHẦN 13: KIỂM TRA DEPLOYMENT
# ============================================================================
# TẠI SAO CẦN:
# - Verify service đã chạy thành công
# - Kiểm tra tasks đã start chưa
# - Register tasks vào ALB target group
# - Test API endpoint
# - Xem logs nếu có lỗi
# ============================================================================

print_step "PHẦN 13: Kiểm tra Deployment"
print_info "Mục đích: Verify deployment thành công và service đang chạy"
print_info "Kiểm tra:"
print_info "  - Service status: ACTIVE, running count"
print_info "  - Task status: RUNNING"
print_info "  - Task health: HEALTHY (sau 2-3 phút)"
print_info "  - ALB target health: healthy"
print_info "  - API endpoint: accessible"
print_info "Lưu ý:"
print_info "  - Đợi 2-3 phút để tasks start và health checks pass"
print_info "  - Health check cần: startPeriod (90s) + 2 successful checks (60s) = ~2.5 phút"
print_info "  - Nếu image chưa có trong ECR, task sẽ fail"
print_info "  - Push code lên GitHub để trigger build"
print_info "  - Đảm bảo ALB ở public subnets và có route đến Internet Gateway"

print_info "Đợi 90 giây để service start..."
sleep 90

# Kiểm tra service status
SERVICE_STATUS=$(aws ecs describe-services \
    --cluster "$CLUSTER_NAME" \
    --services "$SERVICE_NAME" \
    --region "$REGION" \
    --query 'services[0].{status:status,runningCount:runningCount,desiredCount:desiredCount,pendingCount:pendingCount}' \
    --output json)

echo "$SERVICE_STATUS" | jq '.'

RUNNING_COUNT=$(echo "$SERVICE_STATUS" | jq -r '.runningCount // 0')
DESIRED_COUNT=$(echo "$SERVICE_STATUS" | jq -r '.desiredCount // 0')

if [ "$RUNNING_COUNT" -ge "$DESIRED_COUNT" ]; then
    print_success "Service đang chạy: $RUNNING_COUNT/$DESIRED_COUNT tasks"
    
    # Lấy task IP và register vào target group
    TASK_ARN=$(aws ecs list-tasks \
        --cluster "$CLUSTER_NAME" \
        --service-name "$SERVICE_NAME" \
        --region "$REGION" \
        --query 'taskArns[0]' \
        --output text)
    
    if [ -n "$TASK_ARN" ] && [ "$TASK_ARN" != "None" ]; then
        TASK_IP=$(aws ecs describe-tasks \
            --cluster "$CLUSTER_NAME" \
            --tasks "$TASK_ARN" \
            --region "$REGION" \
            --query 'tasks[0].attachments[0].details[?name==`privateIPv4Address`].value' \
            --output text)
        
        if [ -n "$TASK_IP" ] && [ "$TASK_IP" != "None" ]; then
            print_info "Registering task to target group..."
            aws elbv2 register-targets \
                --target-group-arn "$TG_ARN" \
                --targets Id="$TASK_IP",Port=3000 \
                --region "$REGION" 2>/dev/null || print_warning "Task may already be registered"
        fi
    fi
    
    print_success "Deployment thành công!"
    echo ""
    echo "🌐 API Gateway URL: http://$ALB_DNS"
    echo ""
    echo "Để test API:"
    echo "  # Health check"
    echo "  curl http://$ALB_DNS/api/health"
    echo ""
    echo "  # Orders endpoints"
    echo "  curl http://$ALB_DNS/api/orders/1"
    echo "  curl -X POST http://$ALB_DNS/api/orders/create -H 'Content-Type: application/json' -d '{\"userId\":1,\"totalAmount\":100.5,\"products\":[]}'"
    echo ""
    echo "⚠️  Lưu ý:"
    echo "  - Nếu target unhealthy, đợi thêm 1-2 phút cho health checks"
    echo "  - Kiểm tra target health: aws elbv2 describe-target-health --target-group-arn <TG_ARN> --region $REGION"
    echo "  - Kiểm tra logs: aws logs tail $LOG_GROUP --follow --region $REGION"
    echo ""
else
    print_warning "Service chưa sẵn sàng. Đang chạy: $RUNNING_COUNT/$DESIRED_COUNT"
    echo ""
    echo "Kiểm tra logs:"
    echo "  aws logs tail $LOG_GROUP --follow --region $REGION"
    echo ""
    echo "Kiểm tra task status:"
    echo "  aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME --region $REGION"
fi

# ============================================================================
# PHẦN 14: DEPLOY ORDER SERVICE
# ============================================================================
# TẠI SAO CẦN:
# - Order Service xử lý business logic cho orders
# - Kết nối với PostgreSQL RDS để lưu data
# - Expose gRPC endpoint cho API Gateway
# - Service Discovery để API Gateway tìm được Order Service
# ============================================================================

print_step "PHẦN 14: Deploy Order Service"
print_info "Mục đích: Deploy microservice xử lý orders"
print_info "Components:"
print_info "  - ECR Repository: astok-order-service"
print_info "  - RDS PostgreSQL: orderdb"
print_info "  - Service Discovery: order-service.astok.local"
print_info "  - ECS Service: astok-order-service"

read -p "Bạn có muốn deploy Order Service không? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then

# Order Service Configuration
ORDER_ECR_REPOSITORY="astok-order-service"
ORDER_SERVICE_NAME="astok-order-service"
ORDER_TASK_DEFINITION_FAMILY="astok-order-service"
ORDER_LOG_GROUP="/ecs/astok-order-service"

# Database Configuration
DB_INSTANCE_ID="astok-orderdb"
DB_NAME="orderdb"
DB_USER="postgres"
DB_PASSWORD="AstokDB2024SecurePass!"  # CHANGE IN PRODUCTION!

# ============================================================================
# PHẦN 14.1: Tạo ECR Repository cho Order Service
# ============================================================================

print_info "14.1: Tạo ECR Repository cho Order Service..."

if aws ecr describe-repositories --repository-names "$ORDER_ECR_REPOSITORY" --region "$REGION" &> /dev/null; then
    print_warning "ECR Repository '$ORDER_ECR_REPOSITORY' đã tồn tại"
else
    aws ecr create-repository \
        --repository-name "$ORDER_ECR_REPOSITORY" \
        --region "$REGION" \
        --image-scanning-configuration scanOnPush=true > /dev/null
    print_success "ECR Repository '$ORDER_ECR_REPOSITORY' đã được tạo"
fi

# Tạo thêm repo cho migration
if aws ecr describe-repositories --repository-names "astok-order-migrate" --region "$REGION" &> /dev/null; then
    print_warning "ECR Repository 'astok-order-migrate' đã tồn tại"
else
    aws ecr create-repository \
        --repository-name "astok-order-migrate" \
        --region "$REGION" > /dev/null
    print_success "ECR Repository 'astok-order-migrate' đã được tạo"
fi

ORDER_ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ORDER_ECR_REPOSITORY}"

# ============================================================================
# PHẦN 14.2: Tạo RDS PostgreSQL
# ============================================================================

print_info "14.2: Tạo RDS PostgreSQL..."

# Tạo DB Subnet Group
DB_SUBNET_GROUP_NAME="astok-db-subnet-group"
if aws rds describe-db-subnet-groups --db-subnet-group-name "$DB_SUBNET_GROUP_NAME" --region "$REGION" &> /dev/null; then
    print_warning "DB Subnet Group đã tồn tại"
else
    aws rds create-db-subnet-group \
        --db-subnet-group-name "$DB_SUBNET_GROUP_NAME" \
        --db-subnet-group-description "Subnet group for Astok RDS" \
        --subnet-ids "$PRIVATE_SUBNET_1" "$PRIVATE_SUBNET_2" \
        --region "$REGION" > /dev/null
    print_success "DB Subnet Group đã được tạo"
fi

# Tạo Security Group cho RDS
RDS_SG_ID=$(aws ec2 create-security-group \
    --group-name astok-rds-sg \
    --description "Security group for RDS" \
    --vpc-id "$VPC_ID" \
    --region "$REGION" \
    --query 'GroupId' \
    --output text 2>/dev/null || \
    aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=astok-rds-sg" "Name=vpc-id,Values=$VPC_ID" \
        --query 'SecurityGroups[0].GroupId' \
        --output text \
        --region "$REGION")

# Cho phép PostgreSQL từ VPC
aws ec2 authorize-security-group-ingress \
    --group-id "$RDS_SG_ID" \
    --protocol tcp \
    --port 5432 \
    --cidr 10.0.0.0/16 \
    --region "$REGION" 2>/dev/null || true

print_info "RDS Security Group: $RDS_SG_ID"

# Tạo RDS instance
if aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_ID" --region "$REGION" &> /dev/null; then
    print_warning "RDS instance '$DB_INSTANCE_ID' đã tồn tại"
    RDS_ENDPOINT=$(aws rds describe-db-instances \
        --db-instance-identifier "$DB_INSTANCE_ID" \
        --query 'DBInstances[0].Endpoint.Address' \
        --output text \
        --region "$REGION")
else
    print_info "Tạo RDS PostgreSQL instance (mất khoảng 5-10 phút)..."
    aws rds create-db-instance \
        --db-instance-identifier "$DB_INSTANCE_ID" \
        --db-instance-class db.t3.micro \
        --engine postgres \
        --engine-version "15" \
        --master-username "$DB_USER" \
        --master-user-password "$DB_PASSWORD" \
        --allocated-storage 20 \
        --db-name "$DB_NAME" \
        --vpc-security-group-ids "$RDS_SG_ID" \
        --db-subnet-group-name "$DB_SUBNET_GROUP_NAME" \
        --no-publicly-accessible \
        --backup-retention-period 7 \
        --region "$REGION" > /dev/null
    
    print_info "Đợi RDS instance sẵn sàng..."
    aws rds wait db-instance-available \
        --db-instance-identifier "$DB_INSTANCE_ID" \
        --region "$REGION"
    
    RDS_ENDPOINT=$(aws rds describe-db-instances \
        --db-instance-identifier "$DB_INSTANCE_ID" \
        --query 'DBInstances[0].Endpoint.Address' \
        --output text \
        --region "$REGION")
    
    print_success "RDS instance đã được tạo"
fi

print_info "RDS Endpoint: $RDS_ENDPOINT"

# ============================================================================
# PHẦN 14.3: Tạo Security Group cho Order Service
# ============================================================================

print_info "14.3: Tạo Security Group cho Order Service..."

ORDER_SG_ID=$(aws ec2 create-security-group \
    --group-name astok-order-service-sg \
    --description "Security group for Order Service" \
    --vpc-id "$VPC_ID" \
    --region "$REGION" \
    --query 'GroupId' \
    --output text 2>/dev/null || \
    aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=astok-order-service-sg" "Name=vpc-id,Values=$VPC_ID" \
        --query 'SecurityGroups[0].GroupId' \
        --output text \
        --region "$REGION")

# Cho phép gRPC từ API Gateway
aws ec2 authorize-security-group-ingress \
    --group-id "$ORDER_SG_ID" \
    --protocol tcp \
    --port 5001 \
    --source-group "$API_SG_ID" \
    --region "$REGION" 2>/dev/null || true

# Cho phép outbound HTTPS và PostgreSQL
aws ec2 authorize-security-group-egress \
    --group-id "$ORDER_SG_ID" \
    --ip-permissions 'IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0}]' \
    --region "$REGION" 2>/dev/null || true

aws ec2 authorize-security-group-egress \
    --group-id "$ORDER_SG_ID" \
    --ip-permissions 'IpProtocol=tcp,FromPort=5432,ToPort=5432,IpRanges=[{CidrIp=10.0.0.0/16}]' \
    --region "$REGION" 2>/dev/null || true

print_success "Order Service SG: $ORDER_SG_ID"

# ============================================================================
# PHẦN 14.4: Tạo Service Discovery (Cloud Map)
# ============================================================================

print_info "14.4: Tạo Service Discovery..."

# Tạo namespace
NAMESPACE_ID=$(aws servicediscovery list-namespaces \
    --filters Name=NAME,Values=astok.local \
    --query 'Namespaces[0].Id' \
    --output text \
    --region "$REGION" 2>/dev/null)

if [ "$NAMESPACE_ID" = "None" ] || [ -z "$NAMESPACE_ID" ]; then
    print_info "Tạo namespace 'astok.local'..."
    OPERATION_ID=$(aws servicediscovery create-private-dns-namespace \
        --name astok.local \
        --vpc "$VPC_ID" \
        --region "$REGION" \
        --query 'OperationId' \
        --output text)
    
    print_info "Đợi namespace được tạo..."
    sleep 30
    
    NAMESPACE_ID=$(aws servicediscovery list-namespaces \
        --filters Name=NAME,Values=astok.local \
        --query 'Namespaces[0].Id' \
        --output text \
        --region "$REGION")
else
    print_warning "Namespace 'astok.local' đã tồn tại"
fi

print_info "Namespace ID: $NAMESPACE_ID"

# Tạo Service Discovery Service
SD_SERVICE_ARN=$(aws servicediscovery list-services \
    --filters Name=NAMESPACE_ID,Values=$NAMESPACE_ID \
    --query "Services[?Name=='order-service'].Arn | [0]" \
    --output text \
    --region "$REGION" 2>/dev/null)

if [ "$SD_SERVICE_ARN" = "None" ] || [ -z "$SD_SERVICE_ARN" ]; then
    print_info "Tạo service discovery service 'order-service'..."
    SD_SERVICE_ARN=$(aws servicediscovery create-service \
        --name order-service \
        --namespace-id "$NAMESPACE_ID" \
        --dns-config "NamespaceId=$NAMESPACE_ID,DnsRecords=[{Type=A,TTL=60}]" \
        --health-check-custom-config FailureThreshold=1 \
        --region "$REGION" \
        --query 'Service.Arn' \
        --output text)
    print_success "Service Discovery service đã được tạo"
else
    print_warning "Service 'order-service' đã tồn tại trong namespace"
fi

print_info "Service Discovery: order-service.astok.local"

# ============================================================================
# PHẦN 14.5: Tạo CloudWatch Log Group cho Order Service
# ============================================================================

print_info "14.5: Tạo CloudWatch Log Groups..."

aws logs create-log-group \
    --log-group-name "$ORDER_LOG_GROUP" \
    --region "$REGION" 2>/dev/null || print_warning "Log group đã tồn tại"

aws logs create-log-group \
    --log-group-name /ecs/astok-migrations \
    --region "$REGION" 2>/dev/null || print_warning "Migration log group đã tồn tại"

aws logs put-retention-policy \
    --log-group-name "$ORDER_LOG_GROUP" \
    --retention-in-days 30 \
    --region "$REGION"

aws logs put-retention-policy \
    --log-group-name /ecs/astok-migrations \
    --retention-in-days 7 \
    --region "$REGION"

print_success "Log Groups đã được tạo"

# ============================================================================
# PHẦN 14.6: Tạo Task Definition cho Order Service
# ============================================================================

print_info "14.6: Tạo Task Definition cho Order Service..."

ORDER_TASK_DEF_FILE="/tmp/task-definition-${ORDER_TASK_DEFINITION_FAMILY}.json"

cat > "$ORDER_TASK_DEF_FILE" <<EOF
{
  "family": "${ORDER_TASK_DEFINITION_FAMILY}",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "${EXECUTION_ROLE_ARN}",
  "containerDefinitions": [
    {
      "name": "order-service",
      "image": "${ORDER_ECR_URI}:latest",
      "portMappings": [
        {
          "containerPort": 5001,
          "protocol": "tcp"
        }
      ],
      "environment": [
        { "name": "GRPC_PORT", "value": "5001" },
        { "name": "DB_HOST", "value": "${RDS_ENDPOINT}" },
        { "name": "DB_PORT", "value": "5432" },
        { "name": "DB_USER", "value": "${DB_USER}" },
        { "name": "DB_PASSWORD", "value": "${DB_PASSWORD}" },
        { "name": "DB_NAME", "value": "${DB_NAME}" },
        { "name": "DB_SSL_MODE", "value": "require" },
        { "name": "KAFKA_BROKERS", "value": "disabled" },
        { "name": "KAFKA_TOPIC_ORDER_CREATED", "value": "order.created" }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "${ORDER_LOG_GROUP}",
          "awslogs-region": "${REGION}",
          "awslogs-stream-prefix": "ecs"
        }
      },
      "healthCheck": {
        "command": ["CMD-SHELL", "nc -z localhost 5001 || exit 1"],
        "interval": 30,
        "timeout": 5,
        "retries": 3,
        "startPeriod": 60
      }
    }
  ]
}
EOF

aws ecs register-task-definition \
    --cli-input-json "file://$ORDER_TASK_DEF_FILE" \
    --region "$REGION" > /dev/null

print_success "Order Service Task Definition đã được đăng ký"

# ============================================================================
# PHẦN 14.7: Tạo ECS Service cho Order Service
# ============================================================================

print_info "14.7: Tạo ECS Service cho Order Service..."

if aws ecs describe-services \
    --cluster "$CLUSTER_NAME" \
    --services "$ORDER_SERVICE_NAME" \
    --region "$REGION" \
    --query 'services[0].status' \
    --output text 2>/dev/null | grep -q "ACTIVE"; then
    print_warning "ECS Service '$ORDER_SERVICE_NAME' đã tồn tại"
    print_info "Updating service..."
    aws ecs update-service \
        --cluster "$CLUSTER_NAME" \
        --service "$ORDER_SERVICE_NAME" \
        --task-definition "$ORDER_TASK_DEFINITION_FAMILY" \
        --force-new-deployment \
        --region "$REGION" > /dev/null
else
    print_info "Tạo ECS Service: $ORDER_SERVICE_NAME"
    aws ecs create-service \
        --cluster "$CLUSTER_NAME" \
        --service-name "$ORDER_SERVICE_NAME" \
        --task-definition "$ORDER_TASK_DEFINITION_FAMILY" \
        --desired-count 1 \
        --launch-type FARGATE \
        --network-configuration "awsvpcConfiguration={subnets=[\"$PRIVATE_SUBNET_1\",\"$PRIVATE_SUBNET_2\"],securityGroups=[\"$ORDER_SG_ID\"],assignPublicIp=DISABLED}" \
        --service-registries "registryArn=$SD_SERVICE_ARN" \
        --region "$REGION" > /dev/null
fi

print_success "Order Service ECS Service đã được tạo"

# ============================================================================
# PHẦN 14.8: Kiểm tra Order Service Deployment
# ============================================================================

print_info "14.8: Kiểm tra Order Service Deployment..."
print_info "Đợi 90 giây để service start..."
sleep 90

ORDER_SERVICE_STATUS=$(aws ecs describe-services \
    --cluster "$CLUSTER_NAME" \
    --services "$ORDER_SERVICE_NAME" \
    --region "$REGION" \
    --query 'services[0].{status:status,runningCount:runningCount,desiredCount:desiredCount}' \
    --output json)

echo "$ORDER_SERVICE_STATUS" | jq '.'

ORDER_RUNNING=$(echo "$ORDER_SERVICE_STATUS" | jq -r '.runningCount // 0')
ORDER_DESIRED=$(echo "$ORDER_SERVICE_STATUS" | jq -r '.desiredCount // 0')

if [ "$ORDER_RUNNING" -ge "$ORDER_DESIRED" ]; then
    print_success "Order Service đang chạy: $ORDER_RUNNING/$ORDER_DESIRED tasks"
else
    print_warning "Order Service chưa sẵn sàng: $ORDER_RUNNING/$ORDER_DESIRED"
    echo ""
    echo "Kiểm tra logs:"
    echo "  aws logs tail $ORDER_LOG_GROUP --follow --region $REGION"
fi

print_success "Order Service deployment hoàn tất!"
echo ""
echo "📋 Order Service Info:"
echo "  - ECR: $ORDER_ECR_URI"
echo "  - RDS: $RDS_ENDPOINT"
echo "  - Service Discovery: order-service.astok.local:5001"
echo "  - Security Group: $ORDER_SG_ID"
echo ""

fi  # End of Order Service deployment

# ============================================================================
# TÓM TẮT
# ============================================================================

print_step "TÓM TẮT"

echo "Các tài nguyên đã được tạo:"
echo ""
echo "🌐 Network & Security:"
echo "  ✅ VPC: $VPC_ID"
echo "  ✅ Subnets: Public ($PUBLIC_SUBNET_1, $PUBLIC_SUBNET_2), Private ($PRIVATE_SUBNET_1, $PRIVATE_SUBNET_2)"
echo "  ✅ Security Groups: ALB, API Gateway, Order Service, RDS"
echo "  ✅ VPC Endpoints: ECR API, ECR DKR, CloudWatch Logs, S3"
echo ""
echo "📦 ECR Repositories:"
echo "  ✅ $ECR_REPOSITORY (API Gateway)"
echo "  ✅ astok-order-service (Order Service)"
echo "  ✅ astok-order-migrate (Migrations)"
echo ""
echo "🖥️  ECS:"
echo "  ✅ Cluster: $CLUSTER_NAME"
echo "  ✅ Service: $SERVICE_NAME (API Gateway)"
echo "  ✅ Service: astok-order-service (Order Service)"
echo "  ✅ Task Definitions: $TASK_DEFINITION_FAMILY, astok-order-service"
echo ""
echo "🔗 Load Balancer & Service Discovery:"
echo "  ✅ ALB: $ALB_DNS"
echo "  ✅ Target Group: astok-api-gateway-tg"
echo "  ✅ Service Discovery: order-service.astok.local"
echo ""
echo "🗄️  Database:"
echo "  ✅ RDS PostgreSQL: astok-orderdb"
echo ""
echo "📊 Monitoring:"
echo "  ✅ Log Groups: $LOG_GROUP, /ecs/astok-order-service, /ecs/astok-migrations"
echo ""
echo "👤 IAM:"
echo "  ✅ User: $IAM_USER_NAME"
echo "  ✅ Role: $ROLE_NAME"
echo ""
echo "📝 Lưu ý:"
echo "  1. Đảm bảo đã thêm AWS_ACCESS_KEY_ID và AWS_SECRET_ACCESS_KEY vào GitHub Secrets"
echo "  2. Push code lên GitHub để trigger build và push Docker image"
echo "  3. Sau khi image được push, service sẽ tự động pull và chạy"
echo ""
echo "🔗 GitHub Secrets cần thêm:"
echo "  Required:"
echo "    - AWS_ACCESS_KEY_ID     : IAM User access key"
echo "    - AWS_SECRET_ACCESS_KEY : IAM User secret key"
echo "    - AWS_ACCOUNT_ID        : $ACCOUNT_ID"
echo ""
echo "  For Database Migrations (Order Service):"
echo "    - DB_HOST     : RDS endpoint"
echo "    - DB_USER     : Database username"
echo "    - DB_PASSWORD : Database password"
echo "    - DB_NAME     : Database name (e.g., orderdb)"
echo ""
echo "📋 IAM Policy đã tạo: GitHubActionsECSDeployPolicy"
echo "   Permissions: ECR, ECS, CloudWatch Logs, IAM PassRole"
echo ""
print_success "Deploy script hoàn tất!"

