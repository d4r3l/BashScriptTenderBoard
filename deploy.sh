#!/bin/bash
#===============================================================================
# Script: deploy.sh
# Author: Muhammad Reza
# Purpose: Zero-downtime deployment to AWS EC2 instances behind ALB
# Version: 2.1.0
# Last Updated: 2026-03-16
#===============================================================================

set -euo pipefail

#===============================================================================
# CONFIGURATION
#===============================================================================

# Script metadata
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly SCRIPT_VERSION="2.1.0"

# Default configuration (can be overridden by config file or environment)
readonly DEFAULT_CONFIG_FILE="${SCRIPT_DIR}/deploy.conf"
readonly DEFAULT_LOG_DIR="/var/log/deployments"
readonly DEFAULT_LOG_RETENTION_DAYS=30
readonly DEFAULT_MAX_RETRIES=3
readonly DEFAULT_RETRY_DELAY=10
readonly DEFAULT_HEALTH_CHECK_TIMEOUT=300
readonly DEFAULT_HEALTH_CHECK_INTERVAL=15

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Global variables
LOG_FILE=""
CONFIG_FILE=""
DEPLOYMENT_ID=""
START_TIME=""

#===============================================================================
# LOGGING FUNCTIONS
#===============================================================================

# Initialize logging system
init_logging() {
    local log_dir="${1:-$DEFAULT_LOG_DIR}"
    
    # Create log directory if it doesn't exist
    if [[ ! -d "$log_dir" ]]; then
        sudo mkdir -p "$log_dir"
        sudo chmod 755 "$log_dir"
    fi
    
    # Generate unique deployment ID
    DEPLOYMENT_ID="deploy-$(date +%Y%m%d-%H%M%S)-$$"
    LOG_FILE="${log_dir}/${DEPLOYMENT_ID}.log"
    
    # Create log file
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"
    
    # Log initialization
    log "INFO" "Logging initialized. Log file: $LOG_FILE"
    log "INFO" "Deployment ID: $DEPLOYMENT_ID"
}

# Unified logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    
    # Format log entry
    local log_entry="[$timestamp] [$level] [$DEPLOYMENT_ID] $message"
    
    # Write to log file
    echo "$log_entry" >> "$LOG_FILE"
    
    # Console output with colors
    case "$level" in
        ERROR|FATAL)
            echo -e "${RED}[$level]${NC} $message" >&2
            ;;
        WARN)
            echo -e "${YELLOW}[$level]${NC} $message"
            ;;
        INFO)
            echo -e "${GREEN}[$level]${NC} $message"
            ;;
        DEBUG)
            if [[ "${DEBUG:-false}" == "true" ]]; then
                echo -e "${BLUE}[$level]${NC} $message"
            fi
            ;;
        *)
            echo "[$level] $message"
            ;;
    esac
}

# Log rotation (cleanup old logs)
rotate_logs() {
    local log_dir="${1:-$DEFAULT_LOG_DIR}"
    local retention_days="${2:-$DEFAULT_LOG_RETENTION_DAYS}"
    
    log "INFO" "Rotating logs older than $retention_days days in $log_dir"
    
    if [[ -d "$log_dir" ]]; then
        find "$log_dir" -name "*.log" -type f -mtime +"$retention_days" -delete 2>/dev/null || true
        local deleted_count
        deleted_count=$(find "$log_dir" -name "*.log" -type f -mtime +"$retention_days" 2>/dev/null | wc -l)
        log "INFO" "Log rotation complete. Removed $deleted_count old log files."
    fi
}

#===============================================================================
# ERROR HANDLING
#===============================================================================

# Trap errors and cleanup
cleanup() {
    local exit_code=$?
    
    if [[ $exit_code -ne 0 ]]; then
        log "ERROR" "Script failed with exit code: $exit_code"
        log "ERROR" "Initiating rollback procedures..."
        
        # Attempt rollback if deployment was in progress
        if [[ -n "${DEPLOYMENT_STARTED:-}" ]]; then
            perform_rollback
        fi
    fi
    
    # Archive log file
    if [[ -n "$LOG_FILE" && -f "$LOG_FILE" ]]; then
        gzip -k "$LOG_FILE" 2>/dev/null || true
        log "INFO" "Log file archived: ${LOG_FILE}.gz"
    fi
    
    exit $exit_code
}

# Set up error traps
trap cleanup EXIT
trap 'log "ERROR" "Received interrupt signal"; exit 130' INT TERM

# Custom error handler
error_exit() {
    local message="$1"
    local code="${2:-1}"
    
    log "FATAL" "$message"
    exit "$code"
}

# Retry function with exponential backoff
retry() {
    local max_retries="${1:-$DEFAULT_MAX_RETRIES}"
    local delay="${2:-$DEFAULT_RETRY_DELAY}"
    local command="$3"
    
    local attempt=1
    while [[ $attempt -le $max_retries ]]; do
        log "INFO" "Attempt $attempt of $max_retries: $command"
        
        if eval "$command"; then
            return 0
        fi
        
        if [[ $attempt -lt $max_retries ]]; then
            local wait_time=$((delay * attempt))
            log "WARN" "Attempt $attempt failed. Retrying in ${wait_time}s..."
            sleep "$wait_time"
        fi
        
        ((attempt++))
    done
    
    log "ERROR" "Command failed after $max_retries attempts: $command"
    return 1
}

#===============================================================================
# CONFIGURATION MANAGEMENT
#===============================================================================

# Load configuration from file
load_config() {
    local config_file="${1:-$DEFAULT_CONFIG_FILE}"
    
    if [[ ! -f "$config_file" ]]; then
        log "WARN" "Configuration file not found: $config_file. Using defaults."
        return 0
    fi
    
    log "INFO" "Loading configuration from: $config_file"
    
    # Source config file (validates syntax)
    # shellcheck source=/dev/null
    source "$config_file"
    
    # Validate required configuration
    validate_config
}

# Validate configuration
validate_config() {
    local errors=0
    
    # Required variables
    local required_vars=(
        "AWS_REGION"
        "ALB_TARGET_GROUP_ARN"
        "DEPLOYMENT_BUCKET"
        "APPLICATION_NAME"
    )
    
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            log "ERROR" "Required configuration variable not set: $var"
            ((errors++))
        fi
    done
    
    # Validate AWS region format
    if [[ -n "${AWS_REGION:-}" && ! "$AWS_REGION" =~ ^[a-z]{2}-[a-z]+-[0-9]+$ ]]; then
        log "ERROR" "Invalid AWS region format: $AWS_REGION"
        ((errors++))
    fi
    
    # Validate ALB target group ARN
    if [[ -n "${ALB_TARGET_GROUP_ARN:-}" && ! "$ALB_TARGET_GROUP_ARN" =~ ^arn:aws:elasticloadbalancing ]]; then
        log "ERROR" "Invalid ALB Target Group ARN format"
        ((errors++))
    fi
    
    if [[ $errors -gt 0 ]]; then
        error_exit "Configuration validation failed with $errors error(s)"
    fi
    
    log "INFO" "Configuration validation passed"
}

# Export configuration as environment variables for child processes
export_config() {
    export AWS_REGION="${AWS_REGION:-us-east-1}"
    export DEPLOYMENT_BUCKET="${DEPLOYMENT_BUCKET:-}"
    export APPLICATION_NAME="${APPLICATION_NAME:-}"
    export ALB_TARGET_GROUP_ARN="${ALB_TARGET_GROUP_ARN:-}"
    
    # Optional configurations
    export HEALTH_CHECK_PATH="${HEALTH_CHECK_PATH:-/health}"
    export HEALTH_CHECK_TIMEOUT="${HEALTH_CHECK_TIMEOUT:-$DEFAULT_HEALTH_CHECK_TIMEOUT}"
    export HEALTH_CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL:-$DEFAULT_HEALTH_CHECK_INTERVAL}"
}

#===============================================================================
# AWS INTEGRATION FUNCTIONS
#===============================================================================

# Verify AWS credentials and connectivity
verify_aws_credentials() {
    log "INFO" "Verifying AWS credentials..."
    
    if ! command -v aws &> /dev/null; then
        error_exit "AWS CLI not installed. Please install AWS CLI first."
    fi
    
    if ! aws sts get-caller-identity &> /dev/null; then
        error_exit "AWS credentials not configured or invalid. Run 'aws configure' first."
    fi
    
    local account_id
    account_id=$(aws sts get-caller-identity --query Account --output text)
    log "INFO" "AWS credentials verified. Account ID: $account_id"
}

# Get EC2 instances in target group
get_target_instances() {
    local target_group_arn="$1"
    
    log "INFO" "Retrieving instances from target group: $target_group_arn"
    
    local instances
    instances=$(aws elbv2 describe-target-health \
        --target-group-arn "$target_group_arn" \
        --query 'TargetHealthDescriptions[?TargetHealth.State==`healthy`].Target.Id' \
        --output text)
    
    if [[ -z "$instances" ]]; then
        error_exit "No healthy instances found in target group"
    fi
    
    echo "$instances"
}

# Deregister instance from ALB (drain connections)
deregister_from_alb() {
    local instance_id="$1"
    local target_group_arn="$2"
    
    log "INFO" "Deregistering instance $instance_id from ALB..."
    
    aws elbv2 deregister-targets \
        --target-group-arn "$target_group_arn" \
        --targets "Id=$instance_id"
    
    # Wait for deregistration to complete
    local timeout="${HEALTH_CHECK_TIMEOUT:-300}"
    local start_time
    start_time=$(date +%s)
    
    while true; do
        local state
        state=$(aws elbv2 describe-target-health \
            --target-group-arn "$target_group_arn" \
            --targets "Id=$instance_id" \
            --query 'TargetHealthDescriptions[0].TargetHealth.State' \
            --output text 2>/dev/null || echo "unregistered")
        
        if [[ "$state" == "unregistered" || "$state" == "unused" ]]; then
            log "INFO" "Instance $instance_id successfully deregistered"
            return 0
        fi
        
        local current_time
        current_time=$(date +%s)
        if (( current_time - start_time > timeout )); then
            log "WARN" "Timeout waiting for deregistration of $instance_id"
            return 1
        fi
        
        sleep "${HEALTH_CHECK_INTERVAL:-15}"
    done
}

# Register instance with ALB
register_with_alb() {
    local instance_id="$1"
    local target_group_arn="$2"
    local port="${3:-80}"
    
    log "INFO" "Registering instance $instance_id with ALB on port $port..."
    
    aws elbv2 register-targets \
        --target-group-arn "$target_group_arn" \
        --targets "Id=$instance_id,Port=$port"
    
    # Wait for health checks to pass
    local timeout="${HEALTH_CHECK_TIMEOUT:-300}"
    local start_time
    start_time=$(date +%s)
    
    while true; do
        local state
        state=$(aws elbv2 describe-target-health \
            --target-group-arn "$target_group_arn" \
            --targets "Id=$instance_id" \
            --query 'TargetHealthDescriptions[0].TargetHealth.State' \
            --output text 2>/dev/null || echo "unregistered")
        
        if [[ "$state" == "healthy" ]]; then
            log "INFO" "Instance $instance_id is healthy and registered"
            return 0
        elif [[ "$state" == "unhealthy" ]]; then
            log "ERROR" "Instance $instance_id health check failed"
            return 1
        fi
        
        local current_time
        current_time=$(date +%s)
        if (( current_time - start_time > timeout )); then
            log "ERROR" "Timeout waiting for health check of $instance_id"
            return 1
        fi
        
        log "INFO" "Waiting for health check... (current state: $state)"
        sleep "${HEALTH_CHECK_INTERVAL:-15}"
    done
}

# Deploy application artifact to EC2 instance
deploy_to_instance() {
    local instance_id="$1"
    local artifact_url="$2"
    
    log "INFO" "Deploying to instance $instance_id..."
    
    # Get instance private IP
    local private_ip
    private_ip=$(aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].PrivateIpAddress' \
        --output text)
    
    log "INFO" "Instance private IP: $private_ip"
    
    # Use SSM Session Manager for secure deployment
    if ! aws ssm send-command \
        --instance-ids "$instance_id" \
        --document-name "AWS-RunShellScript" \
        --parameters "commands=[
            'mkdir -p /opt/${APPLICATION_NAME}',
            'cd /opt/${APPLICATION_NAME}',
            'aws s3 cp ${artifact_url} . --region ${AWS_REGION}',
            'tar -xzf *.tar.gz',
            'chmod +x start.sh',
            './start.sh'
        ]" \
        --comment "Deployment $DEPLOYMENT_ID" \
        --timeout 600 \
        --output text &> /dev/null; then
        log "ERROR" "SSM command failed for instance $instance_id"
        return 1
    fi
    
    log "INFO" "Deployment command sent to instance $instance_id"
    return 0
}

# Perform health check on deployed application
health_check() {
    local instance_id="$1"
    local health_path="${HEALTH_CHECK_PATH:-/health}"
    
    log "INFO" "Performing health check on instance $instance_id..."
    
    # Get instance private IP
    local private_ip
    private_ip=$(aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].PrivateIpAddress' \
        --output text)
    
    local max_attempts=20
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        local response
        response=$(aws ssm send-command \
            --instance-ids "$instance_id" \
            --document-name "AWS-RunShellScript" \
            --parameters "commands=['curl -sf http://localhost${health_path}']" \
            --timeout 30 \
            --output text 2>/dev/null) || true
        
        if [[ -n "$response" ]]; then
            log "INFO" "Health check passed for instance $instance_id"
            return 0
        fi
        
        log "INFO" "Health check attempt $attempt/$max_attempts failed for $instance_id"
        sleep 5
        ((attempt++))
    done
    
    log "ERROR" "Health check failed for instance $instance_id after $max_attempts attempts"
    return 1
}

#===============================================================================
# DEPLOYMENT FUNCTIONS
#===============================================================================

# Create deployment artifact
create_artifact() {
    local source_dir="${1:-.}"
    local artifact_name="${APPLICATION_NAME}-$(date +%Y%m%d-%H%M%S).tar.gz"
    local artifact_path="/tmp/$artifact_name"
    
    log "INFO" "Creating deployment artifact from: $source_dir"
    
    # Validate source directory
    if [[ ! -d "$source_dir" ]]; then
        error_exit "Source directory not found: $source_dir"
    fi
    
    # Create tarball
    tar -czf "$artifact_path" -C "$source_dir" .
    
    log "INFO" "Artifact created: $artifact_path"
    echo "$artifact_path"
}

# Upload artifact to S3
upload_artifact() {
    local artifact_path="$1"
    local bucket="${DEPLOYMENT_BUCKET}"
    local key="deployments/${APPLICATION_NAME}/$(basename "$artifact_path")"
    
    log "INFO" "Uploading artifact to S3: s3://${bucket}/${key}"
    
    aws s3 cp "$artifact_path" "s3://${bucket}/${key}" \
        --storage-class STANDARD \
        --metadata "deployment-id=${DEPLOYMENT_ID}"
    
    # Generate pre-signed URL (valid for 1 hour)
    local artifact_url
    artifact_url=$(aws s3 presign "s3://${bucket}/${key}" --expires-in 3600)
    
    log "INFO" "Artifact uploaded successfully. URL expires in 1 hour"
    echo "$artifact_url"
}

# Rolling deployment strategy
rolling_deploy() {
    local artifact_url="$1"
    
    log "INFO" "Starting rolling deployment..."
    DEPLOYMENT_STARTED="true"
    
    # Get all healthy instances
    local instances
    instances=$(get_target_instances "$ALB_TARGET_GROUP_ARN")
    
    if [[ -z "$instances" ]]; then
        error_exit "No healthy instances found for deployment"
    fi
    
    local total_instances
    total_instances=$(echo "$instances" | wc -w)
    local deployed_count=0
    local failed_count=0
    
    log "INFO" "Found $total_instances healthy instances"
    
    # Deploy to each instance one by one
    for instance_id in $instances; do
        log "INFO" "========================================="
        log "INFO" "Deploying to instance: $instance_id"
        log "INFO" "========================================="
        
        # Deregister from ALB
        if ! deregister_from_alb "$instance_id" "$ALB_TARGET_GROUP_ARN"; then
            log "ERROR" "Failed to dereg instance $instance_id"
            ((failed_count++))
            continue
        fi
        
        # Deploy application
        if ! deploy_to_instance "$instance_id" "$artifact_url"; then
            log "ERROR" "Failed to deploy to instance $instance_id"
            ((failed_count++))
            # Attempt to re-register failed instance
            register_with_alb "$instance_id" "$ALB_TARGET_GROUP_ARN" || true
            continue
        fi
        
        # Health check
        if ! health_check "$instance_id"; then
            log "ERROR" "Health check failed for instance $instance_id"
            ((failed_count++))
            continue
        fi
        
        # Register back with ALB
        if ! register_with_alb "$instance_id" "$ALB_TARGET_GROUP_ARN"; then
            log "ERROR" "Failed to register instance $instance_id with ALB"
            ((failed_count++))
            continue
        fi
        
        ((deployed_count++))
        log "INFO" "Successfully deployed to $instance_id ($deployed_count/$total_instances)"
    done
    
    log "INFO" "========================================="
    log "INFO" "Deployment Summary"
    log "INFO" "========================================="
    log "INFO" "Total instances: $total_instances"
    log "INFO" "Successfully deployed: $deployed_count"
    log "INFO" "Failed: $failed_count"
    
    if [[ $failed_count -gt 0 ]]; then
        log "WARN" "Deployment completed with $failed_count failure(s)"
        return 1
    fi
    
    log "INFO" "Rolling deployment completed successfully!"
    return 0
}

# Rollback to previous version
perform_rollback() {
    log "WARN" "Initiating rollback procedure..."
    
    # Get previous deployment artifact from S3
    local previous_artifact
    previous_artifact=$(aws s3 ls "s3://${DEPLOYMENT_BUCKET}/deployments/${APPLICATION_NAME}/" \
        --query 'sort_by(Contents, &LastModified)[-2].Key' \
        --output text 2>/dev/null | tail -1) || true
    
    if [[ -z "$previous_artifact" ]]; then
        log "ERROR" "No previous deployment found to rollback to"
        return 1
    fi
    
    log "INFO" "Rolling back to: $previous_artifact"
    
    # Generate pre-signed URL for previous artifact
    local rollback_url
    rollback_url=$(aws s3 presign "s3://${DEPLOYMENT_BUCKET}/${previous_artifact}" --expires-in 3600)
    
    # Re-deploy previous version
    if rolling_deploy "$rollback_url"; then
        log "INFO" "Rollback completed successfully"
        return 0
    else
        log "ERROR" "Rollback failed!"
        return 1
    fi
}

#===============================================================================
# UTILITY FUNCTIONS
#===============================================================================

# Display usage information
usage() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS] COMMAND

Zero-downtime deployment script for AWS EC2 instances behind ALB.

Commands:
    deploy      Deploy application to all instances (rolling deployment)
    rollback    Rollback to previous deployment version
    status      Show current deployment status
    health      Perform health check on all instances
    cleanup     Clean up old deployment artifacts and logs

Options:
    -c, --config FILE     Configuration file path (default: $DEFAULT_CONFIG_FILE)
    -s, --source DIR      Source directory for deployment artifact (default: current dir)
    -r, --region REGION   AWS region (overrides config file)
    -v, --version         Show script version
    -d, --debug           Enable debug output
    -h, --help            Show this help message

Examples:
    $SCRIPT_NAME deploy
    $SCRIPT_NAME deploy -s /path/to/app -c /etc/deploy/prod.conf
    $SCRIPT_NAME rollback
    $SCRIPT_NAME status --region us-west-2

Configuration File Format:
    AWS_REGION="us-east-1"
    ALB_TARGET_GROUP_ARN="arn:aws:elasticloadbalancing:..."
    DEPLOYMENT_BUCKET="my-deployment-bucket"
    APPLICATION_NAME="my-app"
    HEALTH_CHECK_PATH="/health"

EOF
}

# Show version
version() {
    echo "$SCRIPT_NAME version $SCRIPT_VERSION"
}

# Show deployment status
show_status() {
    log "INFO" "Retrieving deployment status..."
    
    # Get target group details
    local target_group
    target_group=$(aws elbv2 describe-target-groups \
        --query "TargetGroups[?TargetGroupArn=='$ALB_TARGET_GROUP_ARN'].[TargetGroupName,HealthyCount,UnhealthyCount]" \
        --output text)
    
    echo "========================================="
    echo "Deployment Status"
    echo "========================================="
    echo "Target Group: $target_group"
    echo ""
    echo "Healthy Instances:"
    
    aws elbv2 describe-target-health \
        --target-group-arn "$ALB_TARGET_GROUP_ARN" \
        --query 'TargetHealthDescriptions[?TargetHealth.State==`healthy`].[Target.Id,TargetHealth.State,TargetHealth.Description]' \
        --output table
    
    echo ""
    echo "Recent Deployments:"
    aws s3 ls "s3://${DEPLOYMENT_BUCKET}/deployments/${APPLICATION_NAME}/" \
        --recursive | tail -5
}

# Clean up old artifacts
cleanup_artifacts() {
    local retention_days="${1:-30}"
    
    log "INFO" "Cleaning up artifacts older than $retention_days days..."
    
    # Clean S3 artifacts
    aws s3 ls "s3://${DEPLOYMENT_BUCKET}/deployments/${APPLICATION_NAME}/" \
        --recursive | while read -r line; do
            local file_date
            file_date=$(echo "$line" | awk '{print $1}')
            local file_key
            file_key=$(echo "$line" | awk '{print $4}')
            
            if [[ -n "$file_key" ]]; then
                local file_timestamp
                file_timestamp=$(date -d "$file_date" +%s 2>/dev/null || echo 0)
                local current_timestamp
                current_timestamp=$(date +%s)
                local age_days=$(( (current_timestamp - file_timestamp) / 86400 ))
                
                if [[ $age_days -gt $retention_days ]]; then
                    log "INFO" "Deleting old artifact: $file_key (${age_days} days old)"
                    aws s3 rm "s3://${DEPLOYMENT_BUCKET}/${file_key}"
                fi
            fi
        done
    
    # Clean log files
    rotate_logs "$DEFAULT_LOG_DIR" "$retention_days"
    
    log "INFO" "Cleanup completed"
}

#===============================================================================
# MAIN FUNCTION
#===============================================================================

main() {
    START_TIME=$(date +%s)
    
    # Parse command line arguments
    local command=""
    local source_dir="."
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            -s|--source)
                source_dir="$2"
                shift 2
                ;;
            -r|--region)
                export AWS_REGION="$2"
                shift 2
                ;;
            -d|--debug)
                export DEBUG="true"
                shift
                ;;
            -v|--version)
                version
                exit 0
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            deploy|rollback|status|health|cleanup)
                command="$1"
                shift
                ;;
            *)
                log "ERROR" "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
    
    # Validate command
    if [[ -z "$command" ]]; then
        log "ERROR" "No command specified"
        usage
        exit 1
    fi
    
    # Initialize
    init_logging
    load_config "${CONFIG_FILE:-$DEFAULT_CONFIG_FILE}"
    export_config
    
    log "INFO" "Starting $SCRIPT_NAME v$SCRIPT_VERSION"
    log "INFO" "Command: $command"
    
    # Execute command
    case "$command" in
        deploy)
            verify_aws_credentials
            
            # Create and upload artifact
            local artifact_path
            artifact_path=$(create_artifact "$source_dir")
            
            local artifact_url
            artifact_url=$(upload_artifact "$artifact_path")
            
            # Clean up local artifact
            rm -f "$artifact_path"
            
            # Perform rolling deployment
            if rolling_deploy "$artifact_url"; then
                log "INFO" "Deployment successful!"
            else
                error_exit "Deployment failed!"
            fi
            ;;
        rollback)
            verify_aws_credentials
            if perform_rollback; then
                log "INFO" "Rollback successful!"
            else
                error_exit "Rollback failed!"
            fi
            ;;
        status)
            verify_aws_credentials
            show_status
            ;;
        health)
            verify_aws_credentials
            local instances
            instances=$(get_target_instances "$ALB_TARGET_GROUP_ARN")
            
            for instance_id in $instances; do
                health_check "$instance_id"
            done
            ;;
        cleanup)
            cleanup_artifacts 30
            ;;
        *)
            log "ERROR" "Unknown command: $command"
            usage
            exit 1
            ;;
    esac
    
    # Calculate and log execution time
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - START_TIME))
    log "INFO" "Script completed in ${duration}s"
}

# Run main function
main "$@"
