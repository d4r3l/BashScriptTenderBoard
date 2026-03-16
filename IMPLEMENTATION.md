# Implementation Guide

**Author:** Muhammad Reza  
**Email:** darel.rv@gmail.com  
**GitHub:** https://github.com/d4r3l/

This guide walks you through setting up and deploying the zero-downtime deployment script in your AWS environment.

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [AWS Infrastructure Setup](#aws-infrastructure-setup)
3. [EC2 Instance Configuration](#ec2-instance-configuration)
4. [Script Configuration](#script-configuration)
5. [Testing the Deployment](#testing-the-deployment)
6. [Production Deployment](#production-deployment)
7. [Troubleshooting](#troubleshooting)

---

## Prerequisites

### Local Machine (Where you run the script)

- **OS:** Linux, macOS, or Windows with WSL
- **Bash:** Version 4.0 or higher
- **AWS CLI:** Version 2.x
- **Git:** For cloning the repository

### AWS Account Requirements

- Active AWS account with billing enabled
- IAM user with appropriate permissions
- VPC with public/private subnets
- Application Load Balancer (ALB)
- EC2 instances in an Auto Scaling Group (recommended)

---

## AWS Infrastructure Setup

### Step 1: Create IAM User for Deployment

```bash
# Create IAM user
aws iam create-user --user-name deploy-bot

# Attach the IAM policy (from iam-policy.json)
aws iam put-user-policy \
    --user-name deploy-bot \
    --policy-name DeploymentPolicy \
    --policy-document file://iam-policy.json

# Create access keys
aws iam create-access-key --user-name deploy-bot

# Configure AWS CLI
aws configure
# Enter the access key ID and secret access key
```

### Step 2: Create S3 Bucket for Artifacts

```bash
# Create bucket (replace with unique name)
aws s3 mb s3://my-company-deployments-$(aws sts get-caller-identity --query Account --output text)

# Enable versioning (recommended for rollback)
aws s3api put-bucket-versioning \
    --bucket my-company-deployments-$(aws sts get-caller-identity --query Account --output text) \
    --versioning-configuration Status=Enabled

# Enable encryption
aws s3api put-bucket-encryption \
    --bucket my-company-deployments-$(aws sts get-caller-identity --query Account --output text) \
    --server-side-encryption-configuration '{
        "Rules": [{
            "ApplyServerSideEncryptionByDefault": {
                "SSEAlgorithm": "AES256"
            }
        }]
    }'
```

### Step 3: Create Target Group for ALB

```bash
# Create target group
aws elbv2 create-target-group \
    --name my-app-tg \
    --protocol HTTP \
    --port 80 \
    --vpc-id vpc-xxxxxxxx \
    --health-check-path /health \
    --health-check-interval-seconds 15 \
    --health-check-timeout-seconds 5 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 3

# Note the TargetGroupArn from the output
```

### Step 4: Create/Configure Load Balancer

```bash
# Create ALB (if not exists)
aws elbv2 create-load-balancer \
    --name my-app-alb \
    --subnets subnet-xxxxxxxx subnet-yyyyyyyy \
    --security-groups sg-xxxxxxxx \
    --scheme internet-facing \
    --type application

# Create listener (port 80)
aws elbv2 create-listener \
    --load-balancer-arn arn:aws:elasticloadbalancing:... \
    --protocol HTTP \
    --port 80 \
    --default-actions Type=forward,TargetGroupArn=arn:aws:elasticloadbalancing:...
```

---

## EC2 Instance Configuration

### Step 1: Launch EC2 Instances with SSM

**AMI Requirements:**
- Amazon Linux 2/2023 OR Ubuntu 20.04+
- SSM Agent pre-installed (included in Amazon Linux)

**IAM Instance Profile:**

Create an IAM role for EC2 instances:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ssm:DescribeAssociation",
        "ssm:GetDeployablePatchSnapshotForInstance",
        "ssm:GetDocument",
        "ssm:DescribeDocument",
        "ssm:GetManifest",
        "ssm:GetParameter",
        "ssm:GetParameters",
        "ssm:ListAssociations",
        "ssm:ListInstanceAssociations",
        "ssm:PutInventory",
        "ssm:PutComplianceItems",
        "ssm:PutConfigurePackageResult",
        "ssm:UpdateAssociationStatus",
        "ssm:UpdateInstanceAssociationStatus",
        "ssm:UpdateInstanceInformation",
        "s3:GetObject",
        "s3:PutObject",
        "s3:ListBucket"
      ],
      "Resource": "*"
    }
  ]
}
```

**Security Group Rules:**

| Type | Protocol | Port Range | Source |
|------|----------|------------|--------|
| HTTP | TCP | 80 | ALB Security Group |
| HTTPS | TCP | 443 | 0.0.0.0/0 (optional) |
| SSH | TCP | 22 | Your IP (optional) |

### Step 2: Install Application Dependencies

SSH into your EC2 instance and install dependencies:

```bash
# For Node.js applications
sudo yum install -y nodejs npm git

# For Python applications
sudo yum install -y python3 python3-pip

# For Java applications
sudo yum install -y java-11-amazon-corretto

# Create application directory
sudo mkdir -p /opt/my-web-app
sudo chown ec2-user:ec2-user /opt/my-web-app
```

### Step 3: Create Application Startup Script

Copy `examples/start.sh` to your EC2 instance:

```bash
# On EC2 instance
sudo nano /opt/my-web-app/start.sh
# Paste the content from examples/start.sh
sudo chmod +x /opt/my-web-app/start.sh
```

### Step 4: Create Sample Application

Create a simple health check endpoint:

**Node.js Example:**

```javascript
// /opt/my-web-app/app/index.js
const http = require('http');

const server = http.createServer((req, res) => {
    if (req.url === '/health') {
        res.writeHead(200, {'Content-Type': 'application/json'});
        res.end(JSON.stringify({status: 'healthy', timestamp: new Date()}));
    } else if (req.url === '/') {
        res.writeHead(200, {'Content-Type': 'text/plain'});
        res.end('Hello from My Web App!');
    } else {
        res.writeHead(404);
        res.end('Not Found');
    }
});

server.listen(80, () => {
    console.log('Server running on port 80');
});
```

**Python Flask Example:**

```python
# /opt/my-web-app/app/app.py
from flask import Flask, jsonify
from datetime import datetime

app = Flask(__name__)

@app.route('/health')
def health():
    return jsonify({'status': 'healthy', 'timestamp': datetime.now().isoformat()})

@app.route('/')
def index():
    return 'Hello from My Web App!'

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=80)
```

### Step 5: Register Instances with Target Group

```bash
# Register EC2 instance with target group
aws elbv2 register-targets \
    --target-group-arn arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/my-app-tg/abc123 \
    --targets Id=i-0123456789abcdef0

# Verify registration
aws elbv2 describe-target-health \
    --target-group-arn arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/my-app-tg/abc123
```

---

## Script Configuration

### Step 1: Clone the Repository

```bash
git clone https://github.com/d4r3l/BashScriptTenderBoard.git
cd BashScriptTenderBoard
```

### Step 2: Create Configuration File

```bash
cp deploy.conf.example deploy.conf
nano deploy.conf
```

### Step 3: Edit Configuration

Update the following values in `deploy.conf`:

```bash
# AWS Region
AWS_REGION="us-east-1"

# ALB Target Group ARN (from Step 3 above)
ALB_TARGET_GROUP_ARN="arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/my-app-tg/abc123def456"

# S3 Bucket Name (from Step 2 above)
DEPLOYMENT_BUCKET="my-company-deployments-123456789012"

# Application Name (must match EC2 directory)
APPLICATION_NAME="my-web-app"

# Health Check Path (must match your app)
HEALTH_CHECK_PATH="/health"

# Timeouts (adjust based on your app startup time)
HEALTH_CHECK_TIMEOUT=300
HEALTH_CHECK_INTERVAL=15
```

### Step 4: Make Script Executable

```bash
chmod +x deploy.sh
```

---

## Testing the Deployment

### Step 1: Verify AWS Credentials

```bash
aws sts get-caller-identity
```

Expected output:
```json
{
    "UserId": "AIDAI...",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/deploy-bot"
}
```

### Step 2: Check Deployment Status

```bash
./deploy.sh status
```

Expected output:
```
[INFO] Retrieving deployment status...
=========================================
Deployment Status
=========================================
Target Group: my-app-tg    2    0

Healthy Instances:
------------------------------------------------------------------
|  Target Id           |  State  |  Description                 |
------------------------------------------------------------------
|  i-0123456789abcdef0 | healthy | Target is healthy           |
|  i-0123456789abcdef1 | healthy | Target is healthy           |
```

### Step 3: Run Health Checks

```bash
./deploy.sh health
```

### Step 4: Prepare Test Application

Create a test application directory:

```bash
mkdir -p /tmp/test-app
cd /tmp/test-app

# Create package.json (for Node.js)
cat > package.json << 'EOF'
{
  "name": "test-app",
  "version": "1.0.0",
  "main": "index.js",
  "scripts": {
    "start": "node index.js"
  }
}
EOF

# Create app directory and index.js
mkdir -p app
cat > app/index.js << 'EOF'
const http = require('http');
const server = http.createServer((req, res) => {
    if (req.url === '/health') {
        res.writeHead(200, {'Content-Type': 'application/json'});
        res.end(JSON.stringify({status: 'healthy', version: '1.0.0'}));
    } else {
        res.writeHead(200, {'Content-Type': 'text/plain'});
        res.end('Test App v1.0.0');
    }
});
server.listen(80, () => console.log('Server running'));
EOF

# Copy start.sh
cp /path/to/BashScriptTenderBoard/examples/start.sh .
chmod +x start.sh
```

### Step 5: Perform Test Deployment

```bash
cd /path/to/BashScriptTenderBoard
./deploy.sh deploy -s /tmp/test-app -d
```

The `-d` flag enables debug output for troubleshooting.

### Step 6: Verify Deployment

```bash
# Check status
./deploy.sh status

# Test via ALB DNS
curl http://my-app-alb-123456789.us-east-1.elb.amazonaws.com/health
```

---

## Production Deployment

### Step 1: Prepare Production Application

```bash
# Build your application
cd /path/to/your-app
npm run build
# or
npm run production

# Create deployment directory
mkdir -p /tmp/prod-deploy
cp -r dist/* /tmp/prod-deploy/
cp /path/to/BashScriptTenderBoard/examples/start.sh /tmp/prod-deploy/
```

### Step 2: Deploy to Production

```bash
cd /path/to/BashScriptTenderBoard
./deploy.sh deploy \
    -s /tmp/prod-deploy \
    -c deploy.conf
```

### Step 3: Monitor Deployment

Watch the deployment in real-time:

```bash
# In another terminal, watch logs
tail -f /var/log/deployments/*.log
```

### Step 4: Verify Application

```bash
# Test health endpoint
curl http://your-alb-dns.amazonaws.com/health

# Test main application
curl http://your-alb-dns.amazonaws.com/

# Check CloudWatch logs
aws logs tail /aws/ssm/my-instance --follow
```

### Step 5: Rollback (if needed)

```bash
# If deployment fails, automatic rollback triggers
# Or manually rollback:
./deploy.sh rollback
```

---

## CI/CD Integration

### GitHub Actions

Create `.github/workflows/deploy.yml`:

```yaml
name: Deploy to Production

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    
    steps:
      - uses: actions/checkout@v3
      
      - name: Configure AWS Credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: us-east-1
      
      - name: Build Application
        run: |
          npm ci
          npm run build
      
      - name: Deploy
        run: |
          chmod +x deploy.sh
          ./deploy.sh deploy -s ./dist
```

### Jenkins Pipeline

Create `Jenkinsfile`:

```groovy
pipeline {
    agent any
    
    environment {
        AWS_REGION = 'us-east-1'
    }
    
    stages {
        stage('Checkout') {
            steps {
                git branch: 'main', 
                    url: 'https://github.com/your-org/your-app.git'
            }
        }
        
        stage('Build') {
            steps {
                sh 'npm ci'
                sh 'npm run build'
            }
        }
        
        stage('Deploy') {
            steps {
                sh '''
                    chmod +x deploy.sh
                    ./deploy.sh deploy -s ./dist
                '''
            }
        }
    }
    
    post {
        failure {
            sh './deploy.sh rollback'
        }
        always {
            cleanWs()
        }
    }
}
```

---

## Troubleshooting

### Issue: "AWS credentials not configured"

**Solution:**
```bash
aws configure
# Or set environment variables
export AWS_ACCESS_KEY_ID=your-key
export AWS_SECRET_ACCESS_KEY=your-secret
export AWS_DEFAULT_REGION=us-east-1
```

### Issue: "No healthy instances found"

**Solution:**
1. Check EC2 instance status: `aws ec2 describe-instances`
2. Verify SSM Agent is running: `systemctl status amazon-ssm-agent`
3. Check target group health: `aws elbv2 describe-target-health`

### Issue: "SSM command failed"

**Solution:**
1. Verify IAM instance profile has SSM permissions
2. Check security group allows outbound HTTPS (443)
3. Verify SSM Agent is installed: `rpm -qa | grep ssm`
4. Check SSM logs: `/var/log/amazon/ssm/amazon-ssm-agent.log`

### Issue: "Health check failed"

**Solution:**
1. Verify application is running: `ps aux | grep node` (or your app)
2. Check application logs: `journalctl -u your-app`
3. Test health endpoint locally: `curl http://localhost/health`
4. Verify security group allows port 80 from ALB

### Issue: "Timeout waiting for deregistration"

**Solution:**
1. Increase `HEALTH_CHECK_TIMEOUT` in config
2. Check ALB connection draining settings
3. Verify no long-running requests are blocking

### Enable Debug Mode

```bash
export DEBUG=true
./deploy.sh deploy -d
```

### View Deployment Logs

```bash
# Linux
sudo tail -f /var/log/deployments/*.log

# Or view specific deployment
zcat /var/log/deployments/deploy-*.log.gz | tail -100
```

---

## Cost Estimation

| Resource | Monthly Cost (approx.) |
|----------|----------------------|
| 2x t3.medium EC2 | $60 |
| ALB | $22 |
| S3 Storage (5GB) | $0.12 |
| Data Transfer | Variable |
| **Total** | **~$85/month** |

---

## Security Checklist

- [ ] IAM user has minimal required permissions
- [ ] S3 bucket has encryption enabled
- [ ] EC2 instances use IAM roles (not access keys)
- [ ] Security groups restrict access appropriately
- [ ] SSM Session Manager enabled (no SSH keys)
- [ ] CloudTrail logging enabled
- [ ] VPC Flow Logs enabled
- [ ] Regular security updates applied

---

## Support

For issues or questions:
- **Email:** darel.rv@gmail.com
- **GitHub:** https://github.com/d4r3l/BashScriptTenderBoard/issues
