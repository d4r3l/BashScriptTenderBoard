# AWS Zero-Downtime Deployment Script

**Author:** Muhammad Reza  
**Version:** 2.1.0  
**Last Updated:** 2026-03-16

## Overview

This Bash script automates **zero-downtime deployments** of web applications to AWS EC2 instances behind an Application Load Balancer (ALB). It implements a rolling deployment strategy with automatic health checks, rollback capabilities, and comprehensive logging.

## Features

- ✅ **Zero-Downtime Deployments** - Rolling updates keep your application available
- ✅ **Automatic Rollback** - Failed deployments trigger automatic rollback
- ✅ **Health Checks** - Validates each instance before routing traffic
- ✅ **Secure Deployment** - Uses AWS SSM Session Manager (no SSH keys required)
- ✅ **Comprehensive Logging** - All actions logged with automatic rotation
- ✅ **Retry Logic** - Exponential backoff for transient failures
- ✅ **Configuration Management** - External config file with environment overrides
- ✅ **ALB Integration** - Automatic register/deregister from load balancer

## Prerequisites

### Required Tools

```bash
# AWS CLI (v2 recommended)
aws --version

# Bash (v4.0+)
bash --version
```

### AWS IAM Permissions

The script requires the following IAM permissions:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances",
        "elasticloadbalancing:DescribeTargetGroups",
        "elasticloadbalancing:DescribeTargetHealth",
        "elasticloadbalancing:RegisterTargets",
        "elasticloadbalancing:DeregisterTargets",
        "s3:GetObject",
        "s3:PutObject",
        "s3:ListBucket",
        "ssm:SendCommand",
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    }
  ]
}
```

### EC2 Instance Requirements

- SSM Agent installed and running
- IAM instance profile with SSM access
- Application directory structure ready (e.g., `/opt/my-app/`)
- `start.sh` script in the application directory

## Installation

1. **Clone the repository:**

```bash
git clone https://github.com/d4r3l/BashScriptTenderBoard.git
cd BashScriptTenderBoard
```

2. **Make the script executable:**

```bash
chmod +x deploy.sh
```

3. **Configure the deployment:**

Copy the example config and edit with your values:

```bash
cp deploy.conf.example deploy.conf
# Edit deploy.conf with your values
```

## Configuration

Edit `deploy.conf` with your environment settings:

```bash
# AWS Region
AWS_REGION="us-east-1"

# ALB Target Group ARN
ALB_TARGET_GROUP_ARN="arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/my-app-tg/abc123def456"

# S3 Deployment Bucket
DEPLOYMENT_BUCKET="my-company-deployments"

# Application Name
APPLICATION_NAME="my-web-app"

# Health Check Endpoint
HEALTH_CHECK_PATH="/api/health"
```

## Usage

### Commands

| Command | Description |
|---------|-------------|
| `deploy` | Deploy application (rolling deployment) |
| `rollback` | Rollback to previous version |
| `status` | Show current deployment status |
| `health` | Run health checks on all instances |
| `cleanup` | Clean old artifacts and logs |

### Options

| Option | Description |
|--------|-------------|
| `-c, --config FILE` | Configuration file path |
| `-s, --source DIR` | Source directory for artifact |
| `-r, --region REGION` | AWS region (overrides config) |
| `-d, --debug` | Enable debug output |
| `-h, --help` | Show help message |
| `-v, --version` | Show version |

### Examples

```bash
# Basic deployment
./deploy.sh deploy

# Deploy from specific directory
./deploy.sh deploy -s /path/to/app

# Use custom config file
./deploy.sh deploy -c /etc/deploy/prod.conf

# Deploy with debug output
./deploy.sh deploy -d

# Rollback to previous version
./deploy.sh rollback

# Check deployment status
./deploy.sh status

# Run health checks
./deploy.sh health

# Clean old artifacts (30+ days)
./deploy.sh cleanup
```

## How It Works

### Deployment Flow

```
┌─────────────────────────────────────────────────────────────┐
│                      START DEPLOYMENT                        │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│              Verify AWS Credentials & Config                 │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│              Create Deployment Artifact (tar.gz)             │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│              Upload Artifact to S3 Bucket                    │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│           FOR EACH INSTANCE (Rolling Deployment)             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │ 1. Deregister from ALB (drain connections)           │   │
│  │ 2. Deploy new artifact via SSM                       │   │
│  │ 3. Run health checks                                 │   │
│  │ 4. Register with ALB (if healthy)                    │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│              DEPLOYMENT COMPLETE (or Rollback)               │
└─────────────────────────────────────────────────────────────┘
```

### Rolling Deployment Strategy

1. **Instance 1**: Deregister → Deploy → Health Check → Register
2. **Instance 2**: Deregister → Deploy → Health Check → Register
3. **Instance N**: ... (repeat for all instances)

This ensures at least one instance is always serving traffic.

## Directory Structure on EC2

```
/opt/my-web-app/
├── start.sh          # Application startup script
├── app/              # Application code (extracted from artifact)
├── config/           # Configuration files
└── logs/             # Application logs
```

## Log Files

Deployment logs are stored in:

- **Linux:** `/var/log/deployments/`
- **Windows:** Configure in `deploy.conf` (e.g., `C:/Logs/Deployments/`)

Log file naming: `deploy-YYYYMMDD-HHMMSS-PID.log`

## Troubleshooting

### Common Issues

**1. AWS Credentials Error**
```bash
# Run aws configure
aws configure
```

**2. SSM Command Failed**
- Ensure SSM Agent is running on EC2 instances
- Verify IAM instance profile has SSM permissions
- Check security groups allow outbound HTTPS

**3. Health Check Failed**
- Verify application is running on the expected port
- Check health endpoint returns HTTP 200
- Review application logs on the instance

**4. ALB Registration Timeout**
- Check target group health check settings
- Verify security groups allow ALB traffic
- Review ALB access logs

### Debug Mode

Enable debug output for detailed logging:

```bash
./deploy.sh deploy -d
```

Or set environment variable:

```bash
export DEBUG=true
./deploy.sh deploy
```

## Security Best Practices

1. **Never commit `deploy.conf`** with real credentials to version control
2. **Use IAM roles** instead of access keys when possible
3. **Restrict S3 bucket access** to specific IAM principals
4. **Enable S3 bucket encryption** for deployment artifacts
5. **Use VPC endpoints** for S3 and SSM to avoid public internet
6. **Rotate credentials** regularly
7. **Audit CloudTrail** for deployment activities

## CI/CD Integration

### GitHub Actions Example

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
        uses: aws-actions/configure-aws-credentials@v2
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: us-east-1
      
      - name: Deploy Application
        run: |
          chmod +x deploy.sh
          ./deploy.sh deploy -s ./dist -c deploy.conf
```

### Jenkins Pipeline Example

```groovy
pipeline {
    agent any
    
    environment {
        AWS_REGION = 'us-east-1'
    }
    
    stages {
        stage('Deploy') {
            steps {
                sh '''
                    chmod +x deploy.sh
                    ./deploy.sh deploy -s ./build
                '''
            }
        }
    }
    
    post {
        failure {
            sh './deploy.sh rollback'
        }
    }
}
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly
5. Submit a pull request

## License

This script is provided as-is for educational and production use.

## Support

For issues or questions, please contact the author or open an issue in the repository.

---

**Author:** Muhammad Reza  
**Email:** darel.rv@gmail.com  
**GitHub:** https://github.com/d4r3l/
