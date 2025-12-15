import json
import boto3
import subprocess
import os
import shutil
import urllib.request
import zipfile

secrets_client = boto3.client('secretsmanager')

def get_github_token(secret_name):
    try:
        response = secrets_client.get_secret_value(SecretId=secret_name)
        if 'SecretString' in response:
            secret = json.loads(response['SecretString'])
            return secret['GITHUB_TOKEN']
    except Exception as e:
        print(f"Error retrieving secret: {e}")
        raise e

def lambda_handler(event, context):
    os.environ['PATH'] = os.environ['PATH'] + ':/opt/bin'
    os.environ['HOME'] = '/tmp'
    
    work_dir = '/tmp/terraform_run'
    if os.path.exists(work_dir):
        shutil.rmtree(work_dir)
    os.makedirs(work_dir)
    
    GITHUB_OWNER = "playdelaybluelay-stack"
    GITHUB_REPO = "dr-lab"
    SECRET_NAME = "dr/github-token"
    BRANCH = "main"
    
    print("Retrieving GitHub Token...")
    token = get_github_token(SECRET_NAME)
    
    url = f"https://api.github.com/repos/{GITHUB_OWNER}/{GITHUB_REPO}/zipball/{BRANCH}"
    zip_path = os.path.join(work_dir, "repo.zip")
    
    print(f"Downloading code from {url}...")
    headers = {
        "Authorization": f"token {token}",
        "Accept": "application/vnd.github.v3+json"
    }
    
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req) as response, open(zip_path, 'wb') as out_file:
            shutil.copyfileobj(response, out_file)
    except Exception as e:
        print(f"Failed to download from GitHub: {e}")
        raise e
        
    print("Unzipping code...")
    with zipfile.ZipFile(zip_path, 'r') as zip_ref:
        zip_ref.extractall(work_dir)
    
    extracted_folders = [name for name in os.listdir(work_dir) if os.path.isdir(os.path.join(work_dir, name))]
    repo_dir = os.path.join(work_dir, extracted_folders[0]) 
    print(f"Terraform working directory: {repo_dir}")

    print("Starting Terraform Init...")
    init_cmd = ["terraform", "init", "-input=false", "-reconfigure"]
    run_command(init_cmd, repo_dir)

    print("Tainting the instance...")
    taint_cmd = ["terraform", "taint", "aws_instance.app_server"]
    try:
        run_command(taint_cmd, repo_dir)
    except Exception:
        print("Taint failed, proceeding...")

    print("Starting Terraform Apply...")
    apply_cmd = ["terraform", "apply", "-auto-approve", "-input=false"]
    run_command(apply_cmd, repo_dir)

    return {
        'statusCode': 200,
        'body': json.dumps('GitHub-based DR Recovery Completed')
    }

def run_command(command, cwd):
    try:
        result = subprocess.run(
            command, cwd=cwd, 
            check=True,
            stdout=subprocess.PIPE, 
            stderr=subprocess.PIPE, 
            encoding='utf-8'
        )
        print(f"Command success: {' '.join(command)}")
        print(result.stdout)
    except subprocess.CalledProcessError as e:
        print(f"Error: {' '.join(command)}")
        print(e.stderr)
        raise e