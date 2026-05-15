#!/bin/bash

# install.sh - A script to manage the installation, update, and destruction of the AskUSDA application.
# Usage:
#   ./install.sh --install   # To install the application
#   ./install.sh --update    # To update the application
#   ./install.sh --destroy   # To destroy the application

# Variables
APP_NAME="AskUSDA"
INSTALL_DIR="/opt/$APP_NAME"
LOG_FILE="/var/log/${APP_NAME}_install.log"
REPO_URL="<repository-url>"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text 2>/dev/null)
AWS_REGION="us-east-1"

# Helper Functions
log_and_exit_on_error() {
    local message="$1"
    local exit_code="$2"
    echo "$message" | tee -a "$LOG_FILE"
    exit "$exit_code"
}

install_prerequisites() {
    echo "Installing prerequisites..." | tee -a "$LOG_FILE"
    sudo yum update -y || log_and_exit_on_error "Failed to update packages." 1
    sudo yum install -y git python3 || log_and_exit_on_error "Failed to install Git and Python3." 1
    curl -fsSL https://rpm.nodesource.com/setup_18.x | sudo bash - || log_and_exit_on_error "Failed to set up Node.js repository." 1
    sudo yum install -y nodejs || log_and_exit_on_error "Failed to install Node.js." 1
    npm install -g aws-cdk || log_and_exit_on_error "Failed to install AWS CDK." 1
    echo "Prerequisites installed successfully." | tee -a "$LOG_FILE"
}

# Functions
install_app() {
    echo "Installing $APP_NAME..." | tee -a "$LOG_FILE"

    # Install prerequisites
    install_prerequisites

    # Clone repository
    echo "Cloning repository..." | tee -a "$LOG_FILE"
    git clone "$REPO_URL" "$INSTALL_DIR" || log_and_exit_on_error "Failed to clone repository." 1
    cd "$INSTALL_DIR" || log_and_exit_on_error "Failed to change directory to $INSTALL_DIR." 1

    # Install dependencies
    echo "Installing backend dependencies..." | tee -a "$LOG_FILE"
    cd backend || log_and_exit_on_error "Failed to change directory to backend." 1
    npm install || log_and_exit_on_error "Failed to install backend dependencies." 1

    echo "Installing frontend dependencies..." | tee -a "$LOG_FILE"
    cd ../frontend || log_and_exit_on_error "Failed to change directory to frontend." 1
    npm install || log_and_exit_on_error "Failed to install frontend dependencies." 1

    # Bootstrap and deploy
    echo "Bootstrapping AWS environment..." | tee -a "$LOG_FILE"
    cd ../backend || log_and_exit_on_error "Failed to change directory to backend." 1
    cdk bootstrap aws://$AWS_ACCOUNT_ID/$AWS_REGION || log_and_exit_on_error "Failed to bootstrap AWS environment." 1

    echo "Deploying application..." | tee -a "$LOG_FILE"
    cdk deploy --all || log_and_exit_on_error "Failed to deploy application." 1

    echo "Installation complete." | tee -a "$LOG_FILE"
}

update_app() {
    echo "Updating $APP_NAME..." | tee -a "$LOG_FILE"

    # Pull latest changes
    cd "$INSTALL_DIR" || log_and_exit_on_error "Failed to change directory to $INSTALL_DIR." 1
    git pull || log_and_exit_on_error "Failed to pull latest changes." 1

    # Redeploy application
    echo "Redeploying application..." | tee -a "$LOG_FILE"
    cd backend || log_and_exit_on_error "Failed to change directory to backend." 1
    cdk deploy --all || log_and_exit_on_error "Failed to redeploy application." 1

    echo "Update complete." | tee -a "$LOG_FILE"
}

destroy_app() {
    echo "Destroying $APP_NAME..." | tee -a "$LOG_FILE"

    # Destroy CDK stacks
    cd "$INSTALL_DIR/backend" || log_and_exit_on_error "Failed to change directory to backend." 1
    cdk destroy --all || log_and_exit_on_error "Failed to destroy CDK stacks." 1

    # Remove application files
    echo "Removing application files..." | tee -a "$LOG_FILE"
    rm -rf "$INSTALL_DIR" || log_and_exit_on_error "Failed to remove application files." 1

    echo "Destruction complete." | tee -a "$LOG_FILE"
}

# Main script
case "$1" in
    --install)
        install_app
        ;;
    --update)
        update_app
        ;;
    --destroy)
        destroy_app
        ;;
    *)
        echo "Usage: $0 --install | --update | --destroy"
        exit 1
        ;;
esac