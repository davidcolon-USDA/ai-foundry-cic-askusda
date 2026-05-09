# Installation Guide for AskUSDA on AWS EC2 (Amazon Linux)

This guide explains how to set up and deploy the AskUSDA application on an AWS EC2 instance running Amazon Linux.

---

## **1. Prerequisites**

### **EC2 Instance Setup**
- Launch an EC2 instance with Amazon Linux 2.
- Attach an IAM role with the necessary permissions for AWS services (e.g., Lambda, S3, DynamoDB, ECS, API Gateway, CloudFormation).
- Ensure the instance has internet access and security group rules allow SSH (port 22).

### **Install AWS CLI**
Amazon Linux comes with AWS CLI pre-installed. Verify the installation:
```bash
aws --version
```

### **Install Node.js and npm**
Install Node.js (LTS version):
```bash
curl -fsSL https://rpm.nodesource.com/setup_18.x | sudo bash -
sudo yum install -y nodejs
```
Verify installation:
```bash
node -v
npm -v
```

### **Install Python**
Install Python 3:
```bash
sudo yum install python3
```
Verify installation:
```bash
python3 --version
```

### **Install CDK**
Install AWS CDK globally:
```bash
npm install -g aws-cdk
```
Verify installation:
```bash
cdk --version
```

---

## **2. Clone the Repository**

Clone the AskUSDA repository to the EC2 instance:
```bash
git clone <repository-url>
cd CIC-AskUSDA-main
```

---

## **3. Install Dependencies**

### **Backend Dependencies**
Navigate to the `backend` directory and install dependencies:
```bash
cd backend
npm install
```

### **Frontend Dependencies**
Navigate to the `frontend` directory and install dependencies:
```bash
cd ../frontend
npm install
```

---

## **4. Bootstrap the AWS Environment**

Run the CDK bootstrap command to prepare the AWS account:
```bash
cd ../backend
cdk bootstrap aws://<account-id>/<region>
```

---

## **5. Deploy the Application**

Deploy all CDK stacks:
```bash
cdk deploy --all
```
Follow the prompts to confirm resource creation.

---

## **6. Configure the Crawler**

### **Edit `urls.yaml`**
Define crawl jobs in `backend/crawler/urls.yaml`:
```yaml
crawl_jobs:
  - name: "usda-main"
    source_url: "https://www.usda.gov"
    max_pages: 500
    max_depth: 3
    scope_type: "all"
```

### **Run the Crawler**
Start the crawler manually:
```bash
python3 -m worker.main --config urls.yaml
```

---

## **7. Verify Deployment**

- Check the deployed resources in the AWS Management Console.
- Test the application endpoints (e.g., chatbot, admin dashboard).

---

## **8. Maintenance**

### **Update the Application**
Pull the latest changes from the repository:
```bash
git pull
```
Redeploy the application:
```bash
cdk deploy --all
```

### **Monitor Logs**
View logs for Lambda functions:
```bash
aws logs tail /aws/lambda/<function-name>
```

---

This completes the installation and deployment of the AskUSDA application on an AWS EC2 instance running Amazon Linux.